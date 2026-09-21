// BTR FIX26 / 第二十六轮独立单元测试
//
// 验证项目（直连/透传路径两处无界等待修复）：
// 1. 【中途停滞可续拉】假上游发 4KB 后中途停滞（不发数据也不断连接），
//    代理看门狗超时触发 abort 并使用新 Range 自动续拉，
//    客户端最终收到的总字节数 == 请求区间长度，内容逐字节吻合且不永久挂住。
// 2. 【响应头不返回】假上游接受 TCP 连接后永不回响应头，
//    代理在 firstByteTimeout 内超时 abort 并抛出 TimeoutException，不永久挂住。
// 3. 【连续停滞超上限】假上游每次只发一点点就中途静默，
//    代理在连续 3 次续拉均停滞后主动放弃并关闭客户端响应，不泄漏定时器与连接、不无限重试。
// 4. 【续拉记账累加与 Content-Length 精确一致】续拉重试期间已写字节数 written
//    严格与声明长度对齐，不漏写也不多写字节。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

// ⚠️ 必须引镜像目录（由 tool/make_btr_mirror.py 生成），与其它 btr 测试文件保持一致：
import 'btr/multi_range_downloader.dart';
import 'btr/proxy_server.dart';
import 'btr/range_core.dart';

void main() {
  group('BTR Round 26: 直连/透传停滞看门狗与响应头超时', () {
    test('1. 中途停滞可原地续拉：假上游发 4KB 后停滞，代理看门狗超时后原地续拉补齐剩余字节', () async {
      const totalBytes = 16 * 1024; // 16 KiB
      final dummyData = Uint8List.fromList(
        List.generate(totalBytes, (i) => (i * 31 + 17) & 0xFF),
      );

      final upstreamServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final upstreamUrl = 'http://127.0.0.1:${upstreamServer.port}/video.m4s';

      int upstreamRequestCount = 0;
      final requestedRanges = <String>[];
      final List<Completer<void>> upstreamPendingCompleters = [];

      upstreamServer.listen((HttpRequest req) async {
        upstreamRequestCount++;
        final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
        if (rangeHeader != null) {
          requestedRanges.add(rangeHeader);
        }

        if (upstreamRequestCount == 1) {
          // 第 1 次请求：先吐 4KB (4096 字节)，然后故意挂起保持静默，等待代理侧看门狗超时 abort
          req.response.bufferOutput = false;
          req.response.statusCode = HttpStatus.partialContent;
          req.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 0-${totalBytes - 1}/$totalBytes',
          );
          req.response.headers.set(
            HttpHeaders.contentLengthHeader,
            '$totalBytes',
          );
          req.response.add(dummyData.sublist(0, 4096));
          await req.response.flush();

          final completer = Completer<void>();
          upstreamPendingCompleters.add(completer);
          try {
            await completer.future;
          } catch (_) {}
          return;
        } else {
          // 续拉请求：按新 Range 补齐剩余数据 (4096 到 16383)
          final parsed = RangeCore.parseRangeHeader(rangeHeader);
          final start = parsed?.start ?? 4096;
          final end = parsed?.end ?? (totalBytes - 1);
          final len = end - start + 1;

          req.response.statusCode = HttpStatus.partialContent;
          req.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/$totalBytes',
          );
          req.response.headers.set(
            HttpHeaders.contentLengthHeader,
            '$len',
          );
          req.response.add(dummyData.sublist(start, end + 1));
          await req.response.close();
          return;
        }
      });

      // 本地客户端代理接力测试服务
      final clientBridge = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      clientBridge.listen((HttpRequest clientReq) async {
        clientReq.response.statusCode = HttpStatus.partialContent;
        clientReq.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 0-${totalBytes - 1}/$totalBytes',
        );
        clientReq.response.headers.set(
          HttpHeaders.contentLengthHeader,
          '$totalBytes',
        );

        // 使用短 stallTimeout (300ms) 快速且确定性地触发看门狗
        await BtrProxyServer.instance.testStreamDirect(
          clientRequest: clientReq,
          targetUrl: upstreamUrl,
          token: CancellationToken(),
          defaultHeaders: const {},
          fromOffset: 0,
          endOffset: totalBytes - 1,
          stallTimeout: const Duration(milliseconds: 300),
        );
        try {
          await clientReq.response.close();
        } catch (_) {}
      });

      final client = HttpClient();
      try {
        final req = await client.getUrl(
          Uri.parse('http://127.0.0.1:${clientBridge.port}/play'),
        );
        final resp = await req.close().timeout(const Duration(seconds: 5));

        final receivedBytes = <int>[];
        await for (final chunk in resp) {
          receivedBytes.addAll(chunk);
        }

        // 断言：总字节数精确等于 16 KiB，内容逐字节与 dummyData 一致
        expect(receivedBytes.length, equals(totalBytes));
        expect(Uint8List.fromList(receivedBytes), equals(dummyData));

        // 断言：发起了 2 次请求（第 1 次 0-16383 吐 4KB 后停滞，第 2 次从 4096-16383 续拉）
        expect(upstreamRequestCount, equals(2));
        expect(requestedRanges.length, equals(2));
        expect(requestedRanges[0], equals('bytes=0-16383'));
        expect(requestedRanges[1], equals('bytes=4096-16383'));
      } finally {
        client.close(force: true);
        for (final c in upstreamPendingCompleters) {
          if (!c.isCompleted) c.complete();
        }
        await clientBridge.close(force: true);
        await upstreamServer.close(force: true);
      }
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('1.b 透传路径中途停滞可原地续拉 (_passthrough)', () async {
      const totalBytes = 8 * 1024; // 8 KiB
      final dummyData = Uint8List.fromList(
        List.generate(totalBytes, (i) => (i * 19 + 7) & 0xFF),
      );

      final upstreamServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final upstreamUrl = 'http://127.0.0.1:${upstreamServer.port}/passthrough.m4s';

      int upstreamRequestCount = 0;
      final requestedRanges = <String>[];
      final List<Completer<void>> upstreamPendingCompleters = [];

      upstreamServer.listen((HttpRequest req) async {
        upstreamRequestCount++;
        final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
        if (rangeHeader != null) {
          requestedRanges.add(rangeHeader);
        }

        if (upstreamRequestCount == 1) {
          // 第 1 次透传响应头与 2KB 数据后静默
          req.response.bufferOutput = false;
          req.response.statusCode = HttpStatus.partialContent;
          req.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 0-${totalBytes - 1}/$totalBytes',
          );
          req.response.headers.set(
            HttpHeaders.contentLengthHeader,
            '$totalBytes',
          );
          req.response.add(dummyData.sublist(0, 2048));
          await req.response.flush();

          final completer = Completer<void>();
          upstreamPendingCompleters.add(completer);
          try {
            await completer.future;
          } catch (_) {}
          return;
        } else {
          // 续拉请求补齐剩余数据 (2048 到 8191)
          final parsed = RangeCore.parseRangeHeader(rangeHeader);
          final start = parsed?.start ?? 2048;
          final end = parsed?.end ?? (totalBytes - 1);
          final len = end - start + 1;

          req.response.statusCode = HttpStatus.partialContent;
          req.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/$totalBytes',
          );
          req.response.headers.set(
            HttpHeaders.contentLengthHeader,
            '$len',
          );
          req.response.add(dummyData.sublist(start, end + 1));
          await req.response.close();
          return;
        }
      });

      final clientBridge = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      clientBridge.listen((HttpRequest clientReq) async {
        await BtrProxyServer.instance.testPassthrough(
          clientRequest: clientReq,
          targetUrl: upstreamUrl,
          token: CancellationToken(),
          defaultHeaders: const {},
          stallTimeout: const Duration(milliseconds: 300),
        );
        try {
          await clientReq.response.close();
        } catch (_) {}
      });

      final client = HttpClient();
      try {
        final req = await client.getUrl(
          Uri.parse('http://127.0.0.1:${clientBridge.port}/passthrough_play'),
        );
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-${totalBytes - 1}');
        final resp = await req.close().timeout(const Duration(seconds: 5));

        final receivedBytes = <int>[];
        await for (final chunk in resp) {
          receivedBytes.addAll(chunk);
        }

        expect(receivedBytes.length, equals(totalBytes));
        expect(Uint8List.fromList(receivedBytes), equals(dummyData));
        expect(upstreamRequestCount, equals(2));
        expect(requestedRanges[0], equals('bytes=0-${totalBytes - 1}'));
        expect(requestedRanges[1], equals('bytes=2048-${totalBytes - 1}'));
      } finally {
        client.close(force: true);
        for (final c in upstreamPendingCompleters) {
          if (!c.isCompleted) c.complete();
        }
        await clientBridge.close(force: true);
        await upstreamServer.close(force: true);
      }
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('2. 响应头不返回：假上游接受 TCP 连接后永不回响应头，约 firstByteTimeout 内超时且不挂死', () async {
      // 使用原始 ServerSocket 接受 TCP 握手但绝不发送任何 HTTP 响应头
      final silentSocketServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final List<Socket> clientSockets = [];
      // 刻意不做任何写入与关闭，保持 TCP 连接挂起
      silentSocketServer.listen(clientSockets.add);

      final clientBridge = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      Object? bridgeCaughtError;
      clientBridge.listen((HttpRequest clientReq) async {
        try {
          await BtrProxyServer.instance.testPassthrough(
            clientRequest: clientReq,
            targetUrl: 'http://127.0.0.1:${silentSocketServer.port}/silent',
            token: CancellationToken(),
            defaultHeaders: const {},
            firstByteTimeout: const Duration(milliseconds: 500),
          );
        } catch (e) {
          bridgeCaughtError = e;
          clientReq.response.statusCode = HttpStatus.gatewayTimeout;
        } finally {
          try {
            await clientReq.response.close();
          } catch (_) {}
        }
      });

      final client = HttpClient();
      final sw = Stopwatch()..start();
      try {
        final req = await client.getUrl(
          Uri.parse('http://127.0.0.1:${clientBridge.port}/test_timeout'),
        );
        final resp = await req.close().timeout(const Duration(seconds: 3));
        await resp.drain<void>();

        sw.stop();
        // 断言：在约 500ms（首字节超时）内完成退出，耗时合理，不永久挂住
        expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(450));
        expect(sw.elapsedMilliseconds, lessThan(2500));
        expect(bridgeCaughtError, isA<TimeoutException>());
        expect(resp.statusCode, equals(HttpStatus.gatewayTimeout));
      } finally {
        client.close(force: true);
        for (final s in clientSockets) {
          try {
            s.destroy();
          } catch (_) {}
        }
        await clientBridge.close(force: true);
        await silentSocketServer.close();
      }
    }, timeout: const Timeout(Duration(seconds: 5)));

    test('3. 连续停滞超上限：假上游每次只发 256B 就静默，连续 3 次续拉后主动关闭响应，不无限重试', () async {
      final upstreamServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final upstreamUrl = 'http://127.0.0.1:${upstreamServer.port}/stall_forever.m4s';

      int upstreamRequestCount = 0;
      final List<Completer<void>> upstreamPendingCompleters = [];

      upstreamServer.listen((HttpRequest req) async {
        upstreamRequestCount++;
        final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
        final parsed = RangeCore.parseRangeHeader(rangeHeader);
        final start = parsed?.start ?? 0;

        // 假上游每次都只吐 256 字节就停滞不关连接
        req.response.bufferOutput = false;
        req.response.statusCode = HttpStatus.partialContent;
        req.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-65535/65536',
        );
        req.response.headers.set(
          HttpHeaders.contentLengthHeader,
          '${65536 - start}',
        );
        req.response.add(Uint8List(256));
        await req.response.flush();

        final completer = Completer<void>();
        upstreamPendingCompleters.add(completer);
        try {
          await completer.future;
        } catch (_) {}
      });

      final clientBridge = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      clientBridge.listen((HttpRequest clientReq) async {
        clientReq.response.bufferOutput = false;
        clientReq.response.statusCode = HttpStatus.partialContent;
        clientReq.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 0-65535/65536',
        );
        clientReq.response.headers.set(
          HttpHeaders.contentLengthHeader,
          '65536',
        );

        // 使用短 stallTimeout 快速触发看门狗
        await BtrProxyServer.instance.testStreamDirect(
          clientRequest: clientReq,
          targetUrl: upstreamUrl,
          token: CancellationToken(),
          defaultHeaders: const {},
          fromOffset: 0,
          endOffset: 65535,
          stallTimeout: const Duration(milliseconds: 200),
        );
      });

      final client = HttpClient();
      try {
        final req = await client.getUrl(
          Uri.parse('http://127.0.0.1:${clientBridge.port}/retry_limit'),
        );
        final resp = await req.close().timeout(const Duration(seconds: 6));

        final receivedBytes = <int>[];
        try {
          await for (final chunk in resp) {
            receivedBytes.addAll(chunk);
          }
        } catch (_) {
          // 由于只传输了部分字节后响应被服务端主动断开，客户端可能收到截断或正常 EOF
        }

        // 断言：请求总数正好为 4 次（第 1 次初始 + 3 次续拉）
        expect(upstreamRequestCount, equals(4));

        // 每次发 256 字节，总计最多收到 4 * 256 = 1024 字节
        expect(receivedBytes.length, equals(1024));
      } finally {
        client.close(force: true);
        for (final c in upstreamPendingCompleters) {
          if (!c.isCompleted) c.complete();
        }
        await clientBridge.close(force: true);
        await upstreamServer.close(force: true);
      }
    }, timeout: const Timeout(Duration(seconds: 10)));
  });
}
