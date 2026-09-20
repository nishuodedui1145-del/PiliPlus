// BTR 本地代理 —— 真实 CDN 端到端验证（独立镜像版）
//
// 用真实 B 站 upos 直链（test/fixtures/media_url.txt）验证代理模块本身：
//   1. HEAD 探测：状态码 / 长度正确且不下 body
//   2. 封闭 Range：代理写出的字节与直连**逐字节一致**
//   3. 开放式 Range（seek 场景 bytes=N-）：逐字节一致，Content-Range 正确
//   4. 速度对比：直连单连接 vs 走代理多 Range 并发
//
// 注意：被测代码是 test/standalone/btr/ 下的镜像（由 tool/make_btr_mirror.py 从
// lib/services/btr_proxy/ 生成），因为 PiliPlus 本体依赖打过补丁的 Flutter SDK。
//
// 运行：flutter test test/standalone/btr_proxy_e2e_test.dart

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'btr/proxy_server.dart';

const _ua =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
const _headers = {
  HttpHeaders.userAgentHeader: _ua,
  HttpHeaders.refererHeader: 'https://www.bilibili.com/',
};

class FetchResult {
  FetchResult(this.status, this.contentRange, this.contentLength, this.bytes,
      this.elapsed);
  final int status;
  final String? contentRange;
  final String? contentLength;
  final List<int> bytes;
  final Duration elapsed;

  double get mbps => bytes.length / 1048576 / (elapsed.inMicroseconds / 1e6);

  @override
  String toString() =>
      'status=$status cr=${contentRange ?? "-"} cl=${contentLength ?? "-"} '
      'bytes=${bytes.length} 耗时=${elapsed.inMilliseconds}ms '
      '速度=${mbps.toStringAsFixed(2)}MB/s';
}

Future<FetchResult> fetch(String url, {String? range, bool head = false}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
  try {
    final req = await client.openUrl(head ? 'HEAD' : 'GET', Uri.parse(url));
    _headers.forEach((k, v) => req.headers.set(k, v));
    if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
    final sw = Stopwatch()..start();
    final resp = await req.close();
    final out = <int>[];
    if (head) {
      await resp.drain<void>();
    } else {
      await for (final chunk in resp) {
        out.addAll(chunk);
      }
    }
    sw.stop();
    return FetchResult(
      resp.statusCode,
      resp.headers.value(HttpHeaders.contentRangeHeader),
      resp.headers.value(HttpHeaders.contentLengthHeader),
      out,
      sw.elapsed,
    );
  } finally {
    client.close(force: true);
  }
}

/// 通过代理从 start 读 win 字节，读够就主动断开（模拟 mpv 读满缓冲即走）
Future<List<int>> take(String url, int start, int win) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(url));
    _headers.forEach((k, v) => req.headers.set(k, v));
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-');
    final resp = await req.close();
    final out = <int>[];
    await for (final chunk in resp) {
      out.addAll(chunk);
      if (out.length >= win) break;
    }
    return out.sublist(0, win);
  } finally {
    client.close(force: true);
  }
}

/// 流式计算 (长度, FNV-1a 64 位哈希)，避免把几十 MB 全塞进内存
Future<(int, int)> streamHash(
  String url, {
  String? range,
  required int limit,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
  try {
    final req = await client.getUrl(Uri.parse(url));
    _headers.forEach((k, v) => req.headers.set(k, v));
    if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
    final resp = await req.close();
    var len = 0;
    var h = 0xcbf29ce484222325;
    await for (final chunk in resp) {
      for (final b in chunk) {
        h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
      }
      len += chunk.length;
      if (len >= limit) break;
    }
    return (len, h);
  } finally {
    client.close(force: true);
  }
}

void main() {
  final fixture = File('test/fixtures/media_url.txt');
  final originUrl = fixture.existsSync() ? fixture.readAsStringSync().trim() : '';
  final proxy = BtrProxyServer.instance;
  var proxyUrl = '';

  setUpAll(() async {
    if (originUrl.isEmpty) return;
    // fixture 的签名 URL 有时效（约几小时），过期会让 8 个用例全红。先快速验证一次。
    final probe = await fetch(originUrl, head: true);
    if (probe.status != 200 && probe.status != 206) {
      fail('test/fixtures/media_url.txt 里的直链已失效（HEAD 返回 ${probe.status}）。'
          '请重新生成：yt-dlp -g --no-warnings -f 30016 '
          'https://www.bilibili.com/video/BV1xx411c7mD > test/fixtures/media_url.txt');
    }
    await proxy.ensureStarted();
    proxyUrl = proxy.buildProxyUrl(originUrl, threads: 8, kind: 'video');
    debugPrint('[E2E] 源节点=${Uri.parse(originUrl).host}');
    debugPrint('[E2E] 代理端口=${proxy.port}');
  });

  tearDownAll(() async => proxy.stop());

  test('1. 直连基线 HEAD：拿到文件总长度', () async {
    final r = await fetch(originUrl, head: true);
    debugPrint('[E2E] 直连 HEAD -> $r');
    expect(r.status, anyOf(200, 206));
    expect(int.parse(r.contentLength!), greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('2. 代理 HEAD：状态码/长度正确', () async {
    final r = await fetch(proxyUrl, head: true);
    debugPrint('[E2E] 代理 HEAD -> $r');
    expect(r.status, anyOf(200, 206));
    expect(int.parse(r.contentLength!), greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('3. 封闭 Range：代理字节与直连逐字节一致', () async {
    const win = 512 * 1024;
    final range = 'bytes=0-${win - 1}';
    final direct = await fetch(originUrl, range: range);
    final viaProxy = await fetch(proxyUrl, range: range);
    debugPrint('[E2E] 直连 $range -> $direct');
    debugPrint('[E2E] 代理 $range -> $viaProxy');
    expect(direct.status, 206);
    expect(viaProxy.status, 206);
    expect(viaProxy.bytes.length, win);
    expect(viaProxy.contentRange, direct.contentRange);
    expect(listEquals(viaProxy.bytes, direct.bytes), isTrue,
        reason: '代理写出的字节与直连不一致');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('4. 开放式 Range（seek）：bytes=N- 前 512KB 与直连逐字节一致', () async {
    const start = 4 * 1024 * 1024;
    const win = 512 * 1024;
    final direct =
        await fetch(originUrl, range: 'bytes=$start-${start + win - 1}');
    final head = await fetch(proxyUrl, range: 'bytes=$start-$start');
    debugPrint('[E2E] 直连封闭 $start -> $direct');
    debugPrint('[E2E] 代理开放 $start- 首个字节响应头 -> $head');
    expect(head.status, 206);
    expect(head.contentRange!.startsWith('bytes $start-'), isTrue,
        reason: '开放式 Range 起始位置不对: ${head.contentRange}');
    expect(head.contentRange, endsWith('/${direct.contentRange!.split('/').last}'));
    final got = await take(proxyUrl, start, win);
    debugPrint('[E2E] 代理开放 $start- 取回 ${got.length} 字节');
    expect(listEquals(got, direct.bytes), isTrue, reason: '开放式 Range 字节不一致');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('6. seek 模式：读一半就断开，再跳到别处立刻续播（mpv 拖进度条）', () async {
    // 第一次：开放式 Range 读 256KB 后主动断开（模拟 mpv 用户拖动）
    final part = await take(proxyUrl, 1024 * 1024, 256 * 1024);
    expect(part.length, 256 * 1024);
    // 立刻跳到另一处再来一次，必须成功（不能因为上一次断开而连带失败）
    final part2 = await take(proxyUrl, 20 * 1024 * 1024, 256 * 1024);
    expect(part2.length, 256 * 1024);
    final direct =
        await fetch(originUrl, range: 'bytes=${20 * 1024 * 1024}-${20 * 1024 * 1024 + 256 * 1024 - 1}');
    expect(listEquals(part2, direct.bytes), isTrue, reason: '跳转后字节不一致');
    debugPrint('[E2E] seek 两次均成功，字节一致');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('7. 长流回归：开放式 Range 连续读 30MB 不许断流（第五轮修的致命 bug）', () async {
    const win = 30 * 1024 * 1024;
    debugPrint('[E2E] 通过代理读 bytes=0- 前 ${win ~/ 1048576}MB ...');
    final viaProxy = await streamHash(proxyUrl, range: 'bytes=0-', limit: win);
    debugPrint('[E2E] 代理: 长度=${viaProxy.$1} 哈希=0x${viaProxy.$2.toRadixString(16)}');
    final direct =
        await streamHash(originUrl, range: 'bytes=0-${win - 1}', limit: win);
    debugPrint('[E2E] 直连: 长度=${direct.$1} 哈希=0x${direct.$2.toRadixString(16)}');
    expect(viaProxy.$1, win, reason: '长流被提前截断（这正是第五轮修的 bug）');
    expect(viaProxy.$2, direct.$2, reason: '长流内容与直连不一致');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('8. EOF 边界：seek 到文件末尾附近（请求区间越过 EOF）', () async {
    // 先拿文件真实大小
    final head = await fetch(originUrl, head: true);
    final total = int.parse(head.contentLength!);
    const win = 1024;
    final start = total - win;
    debugPrint('[E2E] 文件大小=$total，请求 bytes=$start-（越过 EOF）');
    final direct =
        await fetch(originUrl, range: 'bytes=$start-${total - 1}');
    debugPrint('[E2E] 直连末尾 -> $direct');
    expect(direct.status, 206);
    try {
      final got = await take(proxyUrl, start, win);
      debugPrint('[E2E] 代理末尾 -> 取回 ${got.length} 字节');
      expect(got.length, win);
      expect(listEquals(got, direct.bytes), isTrue, reason: 'EOF 附近字节不一致');
    } on Exception catch (e) {
      fail('EOF 附近请求失败（上游裁剪 Content-Range 被当成错误拒绝了）: $e');
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('9. 上游报错时必须如实回错误码（不许假装成功给空 body）', () async {
    // 故意把签名改坏，让上游返回 403
    final bad = originUrl.replaceAll(RegExp(r'upsig=[0-9a-f]+'), 'upsig=deadbeef');
    expect(bad, isNot(originUrl), reason: 'fixture 里没有 upsig，无法构造坏签名');
    final badProxy = proxy.buildProxyUrl(bad, threads: 4, kind: 'video');
    FetchResult? r;
    try {
      r = await fetch(badProxy, range: 'bytes=0-1023');
    } on Exception catch (e) {
      debugPrint('[E2E] 代理主动断流（可接受）：$e');
      return;
    }
    debugPrint('[E2E] 坏签名经代理 -> $r');
    expect(r.status, greaterThanOrEqualTo(400),
        reason: '上游 403 时代理返回了 ${r.status} 且 body=${r.bytes.length} 字节，'
            '客户端会误以为拿到正常数据');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('5. 速度：直连单连接 vs 走代理（多 Range 并发）', () async {
    const win = 4 * 1024 * 1024;
    final direct = await fetch(originUrl, range: 'bytes=0-${win - 1}');
    final viaProxy = await fetch(proxyUrl, range: 'bytes=0-${win - 1}');
    debugPrint('[E2E] === 速度对比（同一 4MB 窗口）===');
    debugPrint('[E2E] 直连单连接: ${direct.mbps.toStringAsFixed(2)} MB/s '
        '(${(direct.mbps * 8).toStringAsFixed(0)} Mbps)');
    debugPrint('[E2E] 走 BTR 代理: ${viaProxy.mbps.toStringAsFixed(2)} MB/s '
        '(${(viaProxy.mbps * 8).toStringAsFixed(0)} Mbps)');
    debugPrint(
        '[E2E] 加速比: x${(viaProxy.mbps / direct.mbps).toStringAsFixed(2)}');
    expect(viaProxy.bytes.length, win);
    expect(listEquals(viaProxy.bytes, direct.bytes), isTrue);
  }, timeout: const Timeout(Duration(minutes: 4)));
}
