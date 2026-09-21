// BTR CDN 自动竞速（A 档）独立单元测试
//
// 验证 6 项核心规则：
// 1. 本地起 3 个假 CDN（快/中/慢），断言一定选最快的那个；
// 2. 其中一个返回 403 / 超时，断言不会选中它，且不影响选出最快的；
// 3. 全部失败（三个都 403），断言返回 null 且 cached 不变；
// 4. 迟滞：先写入 cached=1.00 MB/s，再造一次"新最优 1.10 MB/s"保持；再造"新最优 1.30 MB/s"替换；
// 5. TTL：ttlMs 设 200ms，等 300ms 断言 isFresh == false、cached == null；
// 6. 样本上限：断言整批下载字节数 ≤ maxCandidates × probeBytes。

import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

// ⚠️ 必须引镜像目录（btr/），不能相对路径引 lib/：同名类会被加载两份，`is` 判断静默失效
import 'btr/cdn_pool.dart';
import 'btr/cdn_racer.dart';

Future<HttpServer> createFakeCdnServer({
  required int delayMsPerChunk,
  int chunkSize = 8192,
  int totalBytes = 65536,
  int statusCode = HttpStatus.ok,
  bool hang = false,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((HttpRequest request) async {
    if (hang) {
      // 超时挂起测试
      return;
    }
    if (statusCode != HttpStatus.ok &&
        statusCode != HttpStatus.partialContent) {
      request.response.statusCode = statusCode;
      await request.response.close();
      return;
    }

    final chunk = List<int>.filled(chunkSize, 0x42);
    request.response.statusCode = HttpStatus.partialContent;
    request.response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes 0-${totalBytes - 1}/$totalBytes',
    );
    request.response.headers.set(
      HttpHeaders.contentLengthHeader,
      '$totalBytes',
    );
    request.response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');

    var written = 0;
    while (written < totalBytes) {
      final toWrite = min(chunkSize, totalBytes - written);
      if (toWrite < chunkSize) {
        request.response.add(chunk.sublist(0, toWrite));
      } else {
        request.response.add(chunk);
      }
      await request.response.flush();
      written += toWrite;
      if (delayMsPerChunk > 0 && written < totalBytes) {
        await Future<void>.delayed(Duration(milliseconds: delayMsPerChunk));
      }
    }
    await request.response.close();
  });
  return server;
}

void main() {
  test('1. 假 CDN 选最快：本地起 3 个假 CDN（快/中/慢），断言一定选最快的那个', () async {
    final fastServer = await createFakeCdnServer(delayMsPerChunk: 0);
    final medServer = await createFakeCdnServer(delayMsPerChunk: 15);
    final slowServer = await createFakeCdnServer(delayMsPerChunk: 50);

    try {
      final racer = CdnRacer(
        probeBudgetMs: 800,
        maxCandidates: 6,
        probeBytes: 65536,
        logger: (_) {},
      );

      final fastHost = '127.0.0.1:${fastServer.port}';
      final medHost = '127.0.0.1:${medServer.port}';
      final slowHost = '127.0.0.1:${slowServer.port}';

      // 无论传入候选顺序如何，都必须选出最快的那个
      final result = await racer.raceThroughput(
        candidates: [slowHost, medHost, fastHost],
        sampleUrl: 'http://$fastHost/video.m4s?auth_key=dummy',
        group: 'auto',
      );

      expect(result, isNotNull);
      expect(result!.host, equals(fastHost));
      expect(result.bytesPerSec, greaterThan(0));
    } finally {
      await fastServer.close(force: true);
      await medServer.close(force: true);
      await slowServer.close(force: true);
    }
  });

  test('2. 坏节点不影响：其中一个返回 403 / 超时，断言不会选中它且选出最快节点', () async {
    final fastServer = await createFakeCdnServer(delayMsPerChunk: 0);
    final badServer403 = await createFakeCdnServer(
      delayMsPerChunk: 0,
      statusCode: HttpStatus.forbidden,
    );
    final timeoutServer = await createFakeCdnServer(
      delayMsPerChunk: 0,
      hang: true,
    );

    try {
      final racer = CdnRacer(
        probeBudgetMs: 500,
        maxCandidates: 6,
        probeBytes: 65536,
        logger: (_) {},
      );

      final fastHost = '127.0.0.1:${fastServer.port}';
      final badHost = '127.0.0.1:${badServer403.port}';
      final hangHost = '127.0.0.1:${timeoutServer.port}';

      final result = await racer.raceThroughput(
        candidates: [badHost, hangHost, fastHost],
        sampleUrl: 'http://$fastHost/video.m4s',
        group: 'auto',
      );

      expect(result, isNotNull);
      expect(result!.host, equals(fastHost));
      expect(result.host, isNot(equals(badHost)));
      expect(result.host, isNot(equals(hangHost)));
    } finally {
      await fastServer.close(force: true);
      await badServer403.close(force: true);
      await timeoutServer.close(force: true);
    }
  });

  test('3. 全部失败不改：三个节点都 403 时返回 null 且 cached 不变', () async {
    final s1 = await createFakeCdnServer(
      delayMsPerChunk: 0,
      statusCode: HttpStatus.forbidden,
    );
    final s2 = await createFakeCdnServer(
      delayMsPerChunk: 0,
      statusCode: HttpStatus.forbidden,
    );
    final s3 = await createFakeCdnServer(
      delayMsPerChunk: 0,
      statusCode: HttpStatus.forbidden,
    );

    try {
      final racer = CdnRacer(
        probeBudgetMs: 500,
        logger: (_) {},
      );
      final initialCached = CdnRaceResult(
        host: 'existing-host.bilivideo.com',
        bytesPerSec: 1024 * 1024,
        measuredAtMs: DateTime.now().millisecondsSinceEpoch,
        candidateCount: 1,
        group: 'mainland',
      );
      racer.cached = initialCached;

      final result = await racer.raceThroughput(
        candidates: [
          '127.0.0.1:${s1.port}',
          '127.0.0.1:${s2.port}',
          '127.0.0.1:${s3.port}',
        ],
        sampleUrl: 'http://127.0.0.1:${s1.port}/video.m4s',
        group: 'auto',
      );

      expect(result, isNull);
      expect(racer.cached, equals(initialCached));
    } finally {
      await s1.close(force: true);
      await s2.close(force: true);
      await s3.close(force: true);
    }
  });

  test('4. 迟滞保持与替换：新最优未达 1.2× 保持现役，达标后替换', () async {
    final racer = CdnRacer(
      hysteresisFactor: 1.2,
      probeBudgetMs: 800,
      logger: (_) {},
    );

    final initialCached = CdnRaceResult(
      host: 'existing-cdn.bilivideo.com',
      bytesPerSec: 1.0 * 1024 * 1024,
      measuredAtMs: DateTime.now().millisecondsSinceEpoch,
      candidateCount: 1,
      group: 'mainland',
    );
    racer.cached = initialCached;

    // 第一次：测出 1.10 MB/s（未达 1.2× 迟滞） -> 必须保持现役
    final s1_10 = await createFakeCdnServer(delayMsPerChunk: 7);
    try {
      final res1 = await racer.raceThroughput(
        candidates: ['127.0.0.1:${s1_10.port}'],
        sampleUrl: 'http://127.0.0.1:${s1_10.port}/video.m4s',
        group: 'auto',
      );
      expect(res1, isNotNull);
      expect(res1!.host, equals('existing-cdn.bilivideo.com'));
      expect(res1.bytesPerSec, equals(1.0 * 1024 * 1024));
    } finally {
      await s1_10.close(force: true);
    }

    // 第二次：测出 1.30+ MB/s（达标 1.2× 迟滞） -> 替换现役
    final s1_30 = await createFakeCdnServer(delayMsPerChunk: 0);
    try {
      final res2 = await racer.raceThroughput(
        candidates: ['127.0.0.1:${s1_30.port}'],
        sampleUrl: 'http://127.0.0.1:${s1_30.port}/video.m4s',
        group: 'auto',
      );
      expect(res2, isNotNull);
      expect(res2!.host, equals('127.0.0.1:${s1_30.port}'));
      expect(res2.bytesPerSec, greaterThan(1.2 * 1024 * 1024));
      expect(racer.cached!.host, equals('127.0.0.1:${s1_30.port}'));
    } finally {
      await s1_30.close(force: true);
    }
  });

  test('5. TTL 过期：ttlMs 设 200ms，等 300ms 断言 isFresh == false、cached == null', () async {
    final racer = CdnRacer(
      ttlMs: 200,
      logger: (_) {},
    );

    // ignore: cascade_invocations — 紧随其后的 expect(racer.xxx) 无法并入级联
    racer.cached = CdnRaceResult(
      host: 'ttl-test.bilivideo.com',
      bytesPerSec: 2.0 * 1024 * 1024,
      measuredAtMs: DateTime.now().millisecondsSinceEpoch,
      candidateCount: 1,
      group: 'mainland',
    );

    expect(racer.isFresh, isTrue);
    expect(racer.cached, isNotNull);

    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(racer.isFresh, isFalse);
    expect(racer.cached, isNull);
  });

  test('6. 样本上限：断言整批下载字节数 ≤ maxCandidates × probeBytes', () async {
    const maxCand = 3;
    const probeBytes = 65536;

    final servers = <HttpServer>[];
    for (var i = 0; i < maxCand; i++) {
      servers.add(
        await createFakeCdnServer(delayMsPerChunk: 0, totalBytes: probeBytes),
      );
    }

    try {
      final racer = CdnRacer(
        maxCandidates: maxCand,
        probeBytes: probeBytes,
        probeBudgetMs: 800,
        logger: (_) {},
      );

      final candidates = servers.map((s) => '127.0.0.1:${s.port}').toList();
      final res = await racer.raceThroughput(
        candidates: candidates,
        sampleUrl: 'http://${candidates.first}/sample.m4s',
        group: 'auto',
      );

      expect(res, isNotNull);
      expect(
        racer.lastTotalSampleBytes,
        lessThanOrEqualTo(maxCand * probeBytes),
      );
    } finally {
      for (final s in servers) {
        await s.close(force: true);
      }
    }
  });

  test('7. auto 分组候选过滤：海外/大陆交替各取，Akamai 被跳过，两组均有代表', () {
    final racer = CdnRacer(maxCandidates: 6);
    final candidates = [
      'upos-sz-mirrorali.bilivideo.com',
      'upos-sz-mirroralib.bilivideo.com',
      'upos-sz-mirroralio1.bilivideo.com',
      'upos-sz-mirrorcos.bilivideo.com',
      'upos-sz-mirrorcosb.bilivideo.com',
      'upos-sz-mirrorcoso1.bilivideo.com',
      'upos-hz-mirrorakam.akamaized.net',
      'upos-sz-mirroraliov.bilivideo.com',
      'upos-sz-mirrorcosov.bilivideo.com',
      'upos-sz-mirrorhwov.bilivideo.com',
    ];

    final filtered = racer.filterCandidates(
      candidates: candidates,
      group: 'auto',
    );

    // 1. 长度不超过 6
    expect(filtered.length, equals(6));
    // 2. Akamai 节点被跳过
    expect(filtered.contains('upos-hz-mirrorakam.akamaized.net'), isFalse);
    // 3. 海外与大陆交替各取：第 1 个为海外，第 2 个为大陆，依此类推
    expect(CdnRacer.overseasHosts.contains(filtered[0]), isTrue);
    expect(CdnRacer.overseasHosts.contains(filtered[1]), isFalse);
    expect(CdnRacer.overseasHosts.contains(filtered[2]), isTrue);
    expect(CdnRacer.overseasHosts.contains(filtered[3]), isFalse);
    expect(CdnRacer.overseasHosts.contains(filtered[4]), isTrue);
    expect(CdnRacer.overseasHosts.contains(filtered[5]), isFalse);
  });

  test('8. 假极速截断校验：未收满 probeBytes 的响应直接判为失败返回 null', () async {
    const probeBytes = 65536;
    // 假服务器只吐 8192 字节（远低于 65536 * 0.95）就断流
    final truncatedServer = await createFakeCdnServer(
      delayMsPerChunk: 0,
      totalBytes: 8192,
    );

    try {
      final racer = CdnRacer(
        probeBytes: probeBytes,
        probeBudgetMs: 800,
        logger: (_) {},
      );

      final host = '127.0.0.1:${truncatedServer.port}';
      final result = await racer.raceThroughput(
        candidates: [host],
        sampleUrl: 'http://$host/video.m4s',
        group: 'auto',
      );

      // 未收满直接判为失败（返回 null），不得算作有效吞吐
      expect(result, isNull);
    } finally {
      await truncatedServer.close(force: true);
    }
  });

  test('9. 分组防穿透：粘性节点不在当前分组可用池时不被 rangeCandidates 采用', () {
    final pool = CdnPool(
      originalUrls: [
        'https://upos-sz-mirrorcosov.bilivideo.com/video.m4s',
      ],
      preferredGroup: CdnGroup.overseas,
    );

    // 模拟竞速把大陆节点写入粘性
    const mainlandHost = 'upos-sz-mirrorali.bilivideo.com';
    pool.applyRacerHint(mainlandHost, 10 * 1024 * 1024);

    final candidates = pool.rangeCandidates();
    // 选出的候选池首位不得是越界的大陆节点
    expect(candidates, isNotEmpty);
    expect(
      candidates.first.contains(mainlandHost),
      isFalse,
      reason: '粘性节点不得越过当前 overseas 分组',
    );
  });
}
