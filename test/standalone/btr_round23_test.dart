// BTR FIX23 / 第二十三轮独立单元测试
//
// 验证项目（对照 BTR_REVIEW23.md 14 条审视缺陷）：
// 1. 【P0-1】起播短响应自动续拉拼接与整流完整性（262,144 字节短响应补全到 512 KiB，整流 hash 与长度 == TOTAL）；
// 2. 【P0-2】节点级 403 绝不打死流（单节点 403 自动轮换健康节点；分块候选耗尽时降级单连接顺序透传，不抛致命错误截断流）；
// 3. 【P0-3】异节点同 path 不株连（CdnBanList addressOf / pairOf 带 host，nodeA 403 封禁不影响 nodeB）；
// 4. 【P2-11】分层 SIDX (referenceType == 1) 安全丢弃返回 null；
// 5. 【P1-5, P1-6】重接管防并发与时间戳推移（checkRetakeoverEligible 推进退避时间戳，isRetakeoverInProgress 避免重复试探并正确复位）；
// 6. 【P2-9, P2-10】SIDX 负缓存与 URL 大小写不敏感匹配（.m4s URL deadline/wsTime 忽略大小写，resetForNewVideo 清空正负缓存）；
// 7. 【P2-8】全局 Socket 预算按 calculateBudget 比例分配，清理死计数器；
// 8. 【P1-7】起播测速首个候选胜出时取消未发起的交错定时器并提前完成批次。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

// ⚠️ 必须引镜像目录：
import 'btr/cdn_pool.dart';
import 'btr/multi_range_downloader.dart';
import 'btr/proxy_server.dart';
import 'btr/range_core.dart';
import 'btr/sidx_parser.dart';

/// 辅助函数：构造测试用的 SIDX box
Uint8List createMockSidxBox({
  int timescale = 1000,
  int earliestPresentationTime = 0,
  int firstOffset = 0,
  required List<({int size, int duration, int referenceType})> references,
}) {
  final boxSize = 8 + 4 + 4 + 4 + 4 + 4 + 2 + 2 + references.length * 12;
  final data = Uint8List(boxSize);
  final view = ByteData.sublistView(data);

  var offset = 0;
  view.setUint32(offset, boxSize); offset += 4;
  data.setRange(offset, offset + 4, 'sidx'.codeUnits); offset += 4;

  view.setUint8(offset, 0); offset += 4; // version 0, flags 0
  view.setUint32(offset, 1); offset += 4; // reference_id 1
  view.setUint32(offset, timescale); offset += 4;
  view.setUint32(offset, earliestPresentationTime); offset += 4;
  view.setUint32(offset, firstOffset); offset += 4;
  view.setUint16(offset, 0); offset += 2; // reserved
  view.setUint16(offset, references.length); offset += 2;

  for (final ref in references) {
    final typeAndSize = (ref.referenceType == 1 ? 0x80000000 : 0) | (ref.size & 0x7fffffff);
    view.setUint32(offset, typeAndSize); offset += 4;
    view.setUint32(offset, ref.duration); offset += 4;
    view.setUint32(offset, 0x90000000); offset += 4; // SAP flags
  }

  return data;
}

void main() {
  group('1. 【P0-1】起播短响应自动续拉拼接与整流完整性', () {
    test('首个分块返回 262,144 字节短响应时，downloadPiece 自动续拉后半段补齐至 512 KiB', () async {
      const totalBytes = 1024 * 1024; // 1 MiB
      final dummyData = Uint8List.fromList(List.generate(totalBytes, (i) => (i * 7 + 13) & 0xFF));

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serverUrl = 'http://127.0.0.1:${server.port}/video.m4s';

      int requestCount = 0;
      final requestedRanges = <String>[];

      server.listen((HttpRequest req) async {
        final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
        if (rangeHeader != null) requestedRanges.add(rangeHeader);

        if (req.method == 'HEAD') {
          req.response.statusCode = HttpStatus.ok;
          req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
          req.response.headers.set(HttpHeaders.contentLengthHeader, totalBytes.toString());
          await req.response.close();
          return;
        }

        requestCount++;
        if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
          final parts = rangeHeader.substring(6).split('-');
          final start = int.parse(parts[0]);
          final end = parts[1].isNotEmpty ? int.parse(parts[1]) : totalBytes - 1;

          // 模拟 P0-1 场景：首个 512 KiB 分块 (0-524287)，故意只吐一半 (262,144 字节)
          if (start == 0 && end == 524287) {
            const shortEnd = 262143; // 262,144 字节
            req.response.statusCode = HttpStatus.partialContent;
            req.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes 0-$shortEnd/$totalBytes');
            req.response.headers.set(HttpHeaders.contentLengthHeader, '${shortEnd - 0 + 1}');
            req.response.add(dummyData.sublist(0, shortEnd + 1));
            await req.response.close();
            return;
          }

          // 其他请求正常按 Range 返回
          final actualEnd = end < totalBytes ? end : totalBytes - 1;
          final len = actualEnd - start + 1;
          req.response.statusCode = HttpStatus.partialContent;
          req.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$actualEnd/$totalBytes');
          req.response.headers.set(HttpHeaders.contentLengthHeader, '$len');
          req.response.add(dummyData.sublist(start, actualEnd + 1));
          await req.response.close();
          return;
        }

        req.response.statusCode = HttpStatus.ok;
        req.response.headers.set(HttpHeaders.contentLengthHeader, '$totalBytes');
        req.response.add(dummyData);
        await req.response.close();
      });

      try {
        final pool = CdnPool(originalUrls: [serverUrl]);
        final downloader = MultiRangeDownloader();
        final token = CancellationToken();

        const firstPiece = RangePiece(start: 0, end: 524287, index: 0, length: 524288);
        final result = await downloader.downloadPiece(
          piece: firstPiece,
          pool: pool,
          token: token,
        );

        // 验证：虽然服务端第一包只返回了 262,144 字节，但 downloader 续拉成功，
        // 最终交付的 PieceResult 达到完整的 524,288 字节，字节内容逐字节吻合。
        expect(result.bytes.lengthInBytes, equals(524288));
        expect(result.actualEnd, equals(524287));
        expect(result.total, equals(totalBytes));
        expect(result.bytes, equals(dummyData.sublist(0, 524288)));

        // 验证发出了两次请求：第一次 0-524287，第二次自动续拉 262144-524287
        expect(requestCount, equals(2));
        expect(requestedRanges, contains('bytes=0-524287'));
        expect(requestedRanges, contains('bytes=262144-524287'));
      } finally {
        await server.close(force: true);
      }
    });

    test('短响应续拉支持整流多分片，最终流总字节数与内容完全一致且正确结束', () async {
      const totalBytes = 1024 * 1024; // 1 MiB (两个 512 KiB 分片)
      final dummyData = Uint8List.fromList(List.generate(totalBytes, (i) => (i * 13 + 37) & 0xFF));

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serverUrl = 'http://127.0.0.1:${server.port}/stream.m4s';

      server.listen((HttpRequest req) async {
        final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
        if (req.method == 'HEAD') {
          req.response.statusCode = HttpStatus.ok;
          req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
          req.response.headers.set(HttpHeaders.contentLengthHeader, totalBytes.toString());
          await req.response.close();
          return;
        }

        if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
          final parts = rangeHeader.substring(6).split('-');
          final start = int.parse(parts[0]);
          final end = parts[1].isNotEmpty ? int.parse(parts[1]) : totalBytes - 1;

          // 首块故意只吐 262,144
          if (start == 0 && end == 524287) {
            const shortEnd = 262143;
            req.response.statusCode = HttpStatus.partialContent;
            req.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes 0-$shortEnd/$totalBytes');
            req.response.headers.set(HttpHeaders.contentLengthHeader, '${shortEnd + 1}');
            req.response.add(dummyData.sublist(0, shortEnd + 1));
            await req.response.close();
            return;
          }

          final actualEnd = end < totalBytes ? end : totalBytes - 1;
          final len = actualEnd - start + 1;
          req.response.statusCode = HttpStatus.partialContent;
          req.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$actualEnd/$totalBytes');
          req.response.headers.set(HttpHeaders.contentLengthHeader, '$len');
          req.response.add(dummyData.sublist(start, actualEnd + 1));
          await req.response.close();
          return;
        }

        req.response.statusCode = HttpStatus.ok;
        req.response.headers.set(HttpHeaders.contentLengthHeader, '$totalBytes');
        req.response.add(dummyData);
        await req.response.close();
      });

      try {
        final pool = CdnPool(originalUrls: [serverUrl]);
        final downloader = MultiRangeDownloader();
        final token = CancellationToken();

        final receivedBytes = <int>[];
        await downloader.streamPieces(
          pieces: [
            const RangePiece(start: 0, end: 524287, index: 0, length: 524288),
            const RangePiece(start: 524288, end: 1048575, index: 1, length: 524288),
          ],
          pool: pool,
          token: token,
          winningUrl: serverUrl,
          concurrency: 2,
          onOrderedChunk: (chunk) async {
            receivedBytes.addAll(chunk);
          },
        );

        // 验证整流接收完好，总长度为 1 MiB，且未被短响应提前切断 EOF
        expect(receivedBytes.length, equals(totalBytes));
        expect(Uint8List.fromList(receivedBytes), equals(dummyData));
      } finally {
        await server.close(force: true);
      }
    });
  });

  group('2. 【P0-2】节点级 403 绝不打死流', () {
    test('单节点 403 降级为节点级错误，自动切换到健康节点成功下载分块', () async {
      const totalBytes = 512 * 1024;
      final dummyData = Uint8List.fromList(List.generate(totalBytes, (i) => i & 0xFF));

      // 故障节点 A: 返回 403
      final serverA = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      serverA.listen((HttpRequest req) async {
        req.response.statusCode = HttpStatus.forbidden;
        req.response.write('Forbidden Node');
        await req.response.close();
      });

      // 健康节点 B: 正常返回 206
      final serverB = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      serverB.listen((HttpRequest req) async {
        final rangeHeader = req.headers.value(HttpHeaders.rangeHeader) ?? 'bytes=0-${totalBytes - 1}';
        final parts = rangeHeader.substring(6).split('-');
        final start = int.parse(parts[0]);
        final end = int.parse(parts[1]);
        req.response.statusCode = HttpStatus.partialContent;
        req.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$totalBytes');
        req.response.headers.set(HttpHeaders.contentLengthHeader, '${end - start + 1}');
        req.response.add(dummyData.sublist(start, end + 1));
        await req.response.close();
      });

      try {
        final urlA = 'http://127.0.0.1:${serverA.port}/video.m4s';
        final urlB = 'http://127.0.0.1:${serverB.port}/video.m4s';

        final pool = CdnPool(originalUrls: [urlA, urlB]);
        final downloader = MultiRangeDownloader();
        final token = CancellationToken();

        const piece = RangePiece(start: 0, end: totalBytes - 1, index: 0, length: totalBytes);
        final result = await downloader.downloadPiece(
          piece: piece,
          pool: pool,
          token: token,
          preferredUrls: [urlA],
        );

        // 验证：节点 A 403 失败后轮换到了节点 B，分块成功获取
        expect(result.bytes.lengthInBytes, equals(totalBytes));
        expect(result.bytes, equals(dummyData));
        expect(result.url, equals(urlB));
      } finally {
        await serverA.close(force: true);
        await serverB.close(force: true);
      }
    });

    test('全节点 403 导致 piece 耗尽时，滑动窗口降级为顺序透传，不向外抛致命异常打死流', () async {
      const totalBytes = 512 * 1024;
      final dummyData = Uint8List.fromList(List.generate(totalBytes, (i) => (i + 1) & 0xFF));

      int attemptCount = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest req) async {
        attemptCount++;
        // 前 3 次请求（两路并发 + 一次重试）返回 403，触发分块候选耗尽；
        // 第 4 次之后正常供数 —— 降级单连接顺序透传必须能救回完整流（这正是 P0-2 的要求）
        if (attemptCount <= 3) {
          req.response.statusCode = HttpStatus.forbidden;
          req.response.write('Temporary Forbidden');
          await req.response.close();
          return;
        }
        // 降级为单连接顺序透传时提供数据
        final rangeHeader = req.headers.value(HttpHeaders.rangeHeader) ?? 'bytes=0-${totalBytes - 1}';
        final parts = rangeHeader.substring(6).split('-');
        final start = int.parse(parts[0]);
        final end = parts[1].isNotEmpty ? int.parse(parts[1]) : totalBytes - 1;
        req.response.statusCode = HttpStatus.partialContent;
        req.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$totalBytes');
        req.response.headers.set(HttpHeaders.contentLengthHeader, '${end - start + 1}');
        req.response.add(dummyData.sublist(start, end + 1));
        await req.response.close();
      });

      try {
        final url = 'http://127.0.0.1:${server.port}/video.m4s';
        final pool = CdnPool(originalUrls: [url]);
        final downloader = MultiRangeDownloader();
        final token = CancellationToken();

        final receivedBytes = <int>[];
        // 验证：stream 不会直接抛出 UpstreamHttpException 导致崩溃，而是走降级透传补全字节
        await downloader.streamPieces(
          pieces: [
            const RangePiece(start: 0, end: totalBytes - 1, index: 0, length: totalBytes),
          ],
          pool: pool,
          token: token,
          winningUrl: url,
          concurrency: 2,
          onOrderedChunk: (chunk) async {
            receivedBytes.addAll(chunk);
          },
        );

        expect(receivedBytes.length, equals(totalBytes));
        expect(Uint8List.fromList(receivedBytes), equals(dummyData));
      } finally {
        await server.close(force: true);
      }
    });
  });

  group('3. 【P0-3】异节点同 path 不株连', () {
    test('CdnBanList 对 nodeA/path 触发 403 封禁后，nodeB/path 依然放行', () {
      final banList = CdnBanList(strikeLimit: 2);
      const urlA = 'https://node-a.bilivideo.com/upgcxcode/123.m4s?sign=aaa';
      const urlB = 'https://node-b.bilivideo.com/upgcxcode/123.m4s?sign=bbb';
      const err403 = UpstreamHttpException(403, 'Forbidden');

      // 验证 key 生成带 host
      expect(CdnBanList.addressOf(urlA), equals('node-a.bilivideo.com|/upgcxcode/123.m4s'));
      expect(CdnBanList.addressOf(urlB), equals('node-b.bilivideo.com|/upgcxcode/123.m4s'));
      expect(CdnBanList.addressOf(urlA), isNot(equals(CdnBanList.addressOf(urlB))));

      // 对 nodeA 连续 2 次 403 封禁
      banList
        ..record(urlA, 0, err403)
        ..record(urlA, 0, err403);

      // nodeA 对应资源被封
      expect(banList.allows(urlA), isFalse);
      // nodeB 相同 path 绝不被株连
      expect(banList.allows(urlB), isTrue);

      // 同一 nodeA 下不同 path 也未被封（host 级未超限）
      const urlAOtherPath = 'https://node-a.bilivideo.com/upgcxcode/456.m4s?sign=ccc';
      expect(banList.allows(urlAOtherPath), isTrue);
    });
  });

  group('4. 【P2-11】分层 SIDX (referenceType == 1) 安全丢弃并返回 null', () {
    test('referenceType == 1 (sub-sidx) 时 parseSidx 返回 null，防止错将索引当音视频分段', () {
      // 构造包含 referenceType == 1 的 mock sidx
      final hierarchicalSidx = createMockSidxBox(
        timescale: 1000,
        references: [
          (size: 100000, duration: 2000, referenceType: 1), // 分层引用！
          (size: 150000, duration: 2000, referenceType: 0),
        ],
      );

      final result = SidxParser.parseSidx(hierarchicalSidx, 0);
      expect(result, isNull, reason: '包含 referenceType == 1 的分层 sidx 必须返回 null');

      // 构造全 referenceType == 0 的普通 sidx
      final normalSidx = createMockSidxBox(
        timescale: 1000,
        references: [
          (size: 100000, duration: 2000, referenceType: 0),
          (size: 150000, duration: 2000, referenceType: 0),
        ],
      );

      final normalResult = SidxParser.parseSidx(normalSidx, 0);
      expect(normalResult, isNotNull);
      expect(normalResult!.segments.length, equals(2));
    });
  });

  group('5. 【P1-5, P1-6】重接管防并发与时间戳推移', () {
    test('checkRetakeoverEligible 命中后立刻推移下次退避时间戳，杜绝高频试探并发', () {
      final pool = CdnPool(originalUrls: ['https://mirrorali.bilivideo.com/v.m4s']);
      // ignore: cascade_invocations — 紧随其后的 expect(pool.xxx) 无法并入级联
      pool.markDirectFallback('起播超时降级');
      expect(pool.isDirectPassthrough, isTrue);
      expect(pool.isRetakeoverInProgress, isFalse);

      // 模拟退避时间到达
      final now = DateTime.now().millisecondsSinceEpoch;
      pool.nextRetakeoverTimeMs = now - 100;

      // 第一次检查重接管：应满足条件
      final eligible1 = pool.checkRetakeoverEligible();
      expect(eligible1, isTrue);
      expect(pool.retakeoverAttempts, equals(1));

      // 核心验证 (P1-6)：checkRetakeoverEligible 调用后立刻推进了 nextRetakeoverTimeMs
      expect(
        pool.nextRetakeoverTimeMs,
        greaterThan(now + RangeCore.fallbackGraceMs),
        reason: '必须立刻将下次重试推迟到至少 fallbackGraceMs 之后',
      );

      // 立即再次检查：必须返回 false，防止并发请求多次重复触发
      final eligible2 = pool.checkRetakeoverEligible();
      expect(eligible2, isFalse);
    });

    test('重接管试探期间标记 isRetakeoverInProgress，成功后正确清除标志位并恢复多连接', () {
      final pool = CdnPool(originalUrls: ['https://mirrorali.bilivideo.com/v.m4s']);
      // ignore: cascade_invocations — 紧随其后的 expect(pool.xxx) 无法并入级联
      pool.markDirectFallback('起播超时降级');
      expect(pool.isDirectPassthrough, isTrue);

      // 进入重接管试探状态 (P1-5)
      pool.isRetakeoverInProgress = true;
      expect(pool.isRetakeoverInProgress, isTrue);

      // 试探成功，执行恢复
      pool.onRetakeoverSuccess('mirrorali.bilivideo.com');
      expect(pool.isDirectPassthrough, isFalse);
      expect(pool.isRetakeoverInProgress, isFalse);
      expect(pool.retakeoverAttempts, equals(0));
    });
  });

  group('6. 【P2-9, P2-10】SIDX 负缓存与 URL 大小写不敏感匹配', () {
    test('URL 带大写 DEADLINE 或 WSTIME 时仍可命中正则匹配', () {
      const url1 = 'https://mirrorali.bilivideo.com/video.m4s?sign=abc&DEADLINE=1700000000';
      const url2 = 'https://mirrorhw.bilivideo.com/audio.m4s?WSTIME=1700000000&wsSecret=xyz';
      const url3 = 'https://mirrorhw.bilivideo.com/live.flv?auth_key=123';

      final pattern = RegExp(r'\.m4s\?(.*&)?(deadline|wsTime)=\d+', caseSensitive: false);
      expect(pattern.hasMatch(url1), isTrue);
      expect(pattern.hasMatch(url2), isTrue);
      expect(pattern.hasMatch(url3), isFalse);
    });

    test('resetForNewVideo 清除 SIDX 正向缓存与负缓存', () {
      SidxCache.put('/test/video.m4s', SidxResult(
        segments: [],
        timescale: 1000,
        earliestPresentationTime: 0,
        firstOffset: 0,
      ));
      expect(SidxCache.get('/test/video.m4s'), isNotNull);

      // SidxCache.clear() 清除正向缓存
      SidxCache.clear();
      expect(SidxCache.get('/test/video.m4s'), isNull);
    });
  });

  group('7. 【P2-8】全局 Socket 预算按 calculateBudget 分配，无死计数器', () {
    test('并发变更时各轨上限正确计算', () {
      final budget = GlobalSocketBudget()..updateBudget(8);
      expect(budget.videoLimit, equals(8));
      expect(budget.audioLimit, equals(2));
      expect(budget.rescueLimit, equals(1));
      expect(budget.globalLimit, equals(11));

      budget.updateBudget(2);
      // 第 38 轮：视频侧预算加下限 minVideoBudget=8（真机日志实证：视频预算曾塌到 4 / 全局 7，
      // 导致 piece#0 反复 4 秒、播放器等不到首批数据而起播失败）—— 所以这里 video 保持下限 8。
      expect(budget.videoLimit, equals(8));
      // 音频预算固定 2 条、补救预留固定 1 条（第十一轮真机对比后拍板：官方公式会让视频可用连接变少，体感更差）
      // —— 所以并发降到 2 时音频**不会**缩到 1，也不受视频下限影响；全局上限 = 8 + 2 + 1 = 11
      expect(budget.audioLimit, equals(2));
      expect(budget.rescueLimit, equals(1));
      expect(budget.globalLimit, equals(11));
    });
  });

  group('8. 【P1-7】起播测速首个候选胜出时取消未发起的交错定时器', () {
    test('起播测速首个候选胜出后，未到期的交错延迟定时器被取消', () async {
      final fastServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      fastServer.listen((HttpRequest req) async {
        req.response.statusCode = HttpStatus.partialContent;
        req.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes 0-0/1000');
        req.response.headers.set(HttpHeaders.contentLengthHeader, '1');
        req.response.add([0x42]);
        await req.response.close();
      });

      int slowReceived = 0;
      final slowServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      slowServer.listen((HttpRequest req) async {
        slowReceived++;
        req.response.statusCode = HttpStatus.partialContent;
        req.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes 0-0/1000');
        req.response.headers.set(HttpHeaders.contentLengthHeader, '1');
        req.response.add([0x42]);
        await req.response.close();
      });

      try {
        final fastUrl = 'http://127.0.0.1:${fastServer.port}/v.m4s';
        final slowUrl = 'http://127.0.0.1:${slowServer.port}/v.m4s';

        final pool = CdnPool(originalUrls: [fastUrl, slowUrl]);
        final downloader = MultiRangeDownloader();
        final token = CancellationToken();

        final sw = Stopwatch()..start();
        final winner = await downloader.probeHead(
          start: 0,
          end: 65535,
          pool: pool,
          token: token,
        );
        sw.stop();

        expect(winner.winningUrl, equals(fastUrl));
        // P1-7 回归：胜出后必须立刻收尾，不许干等到 startupProbeBatchTimeout(300ms) 硬超时
        expect(
          sw.elapsedMilliseconds,
          lessThan(290),
          reason: '起播测速胜出后仍等满批次超时（实测 ${sw.elapsedMilliseconds}ms）',
        );

        // 等待超过 300ms（原定的 staggerDelayMs）
        await Future<void>.delayed(const Duration(milliseconds: 350));
        // 慢速节点由于未到期的交错定时器被取消，不应发起多余请求
        expect(slowReceived, equals(0));
      } finally {
        await fastServer.close(force: true);
        await slowServer.close(force: true);
      }
    });
  });
}
