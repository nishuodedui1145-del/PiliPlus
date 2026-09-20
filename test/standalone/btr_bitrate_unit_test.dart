import 'package:flutter_test/flutter_test.dart';

import 'package:PiliPlus/services/btr_proxy/cdn_pool.dart';
import 'package:PiliPlus/services/btr_proxy/range_core.dart';

void main() {
  group('BTR 码率单位修正回归测试 (bit/s -> 字节/秒)', () {
    test('1. 480p URL: bw=155643 解析出码率 ≈ 19455.4 B/s，required ≈ 23346 B/s', () {
      const url =
          'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/11/22/33/test_480p.m4s?bw=155643&mid=123';
      final bitrate = RangeCore.parseBitrateBytesPerSec(url);

      expect(bitrate, isNotNull);
      // bw=155643 bit/s ÷ 8.0 = 19455.375 B/s，误差要求 < 0.1
      expect(bitrate!, closeTo(19455.4, 0.1));

      final requiredThroughput =
          RangeCore.requiredThroughputBytesPerSec(bitrate);
      // 19455.375 * 1.2 = 23346.45 B/s
      expect(requiredThroughput, closeTo(23346.0, 1.0));
    });

    test('2. 4K URL: bw=19240000 -> 码率 2405000 B/s (≈2.41 MB/s)，target = 码率×1.2', () {
      const url =
          'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/11/22/33/test_4k.m4s?bw=19240000&mid=123';
      final bitrate = RangeCore.parseBitrateBytesPerSec(url);

      expect(bitrate, isNotNull);
      // 19240000 bit/s ÷ 8.0 = 2405000.0 B/s (即 2.405 MB/s ≈ 2.41 MB/s)
      expect(bitrate, equals(2405000.0));

      final target = RangeCore.requiredThroughputBytesPerSec(bitrate);
      // 2405000 * 1.2 = 2886000.0 B/s (即 2.886 MB/s ≈ 2.89 MB/s)
      expect(target, equals(2405000.0 * 1.2));
      expect(target, equals(2886000.0));
    });

    test('3. 音频 URL: bw=1080000 -> 135000 B/s', () {
      const url =
          'https://upos-sz-mirrorali.bilivideo.com/upgcxcode/11/22/33/test_audio.m4s?bw=1080000&mid=123';
      final bitrate = RangeCore.parseBitrateBytesPerSec(url);

      expect(bitrate, isNotNull);
      // 1080000 bit/s ÷ 8.0 = 135000.0 B/s
      expect(bitrate, equals(135000.0));

      final target = RangeCore.requiredThroughputBytesPerSec(bitrate);
      expect(target, equals(135000.0 * 1.2));
    });

    test('4. 慢块阈值：无并发信息回退固定 1200ms；有并发时按每连接份额动态算', () {
      // 旧语义（按码率固定分档 0.8/0.9/1.5s）已被"按每连接份额动态计算"取代：
      // 真机 4K+7 并发时每块理论 1.22s，固定 0.9s 阈值把只慢 6% 的块全判成慢块，
      // 5 分钟触发 109 次慢块 + 177 次抢包（hedge 风暴）。

      // ① 没有并发信息 → 一律回退固定 1200ms（构造/reset 时就是这种情形）
      for (final rate in [2405000.0, 766000.0, 155643.0, 19455.375]) {
        expect(
          RangeCore.adaptiveSlowPieceThreshold(rate),
          equals(RangeCore.slowPieceThresholdDefault),
        );
      }
      // 码率为空即使给了并发 → 仍回退
      expect(
        RangeCore.adaptiveSlowPieceThreshold(null, concurrency: 7),
        equals(RangeCore.slowPieceThresholdDefault),
      );

      // ② 4K：2.405 MB/s→目标 2.886 MB/s、并发 7、块 512KiB
      //    expected = 524288 ÷ (2886000/7) ≈ 1271.6ms → ×1.6 ≈ 2035ms
      final t4k = RangeCore.adaptiveSlowPieceThreshold(2405000.0, concurrency: 7);
      expect(t4k.inMilliseconds, inInclusiveRange(1900, 2200));

      // ③ 1080P60：0.766 MB/s→目标 0.919 MB/s、并发 3
      //    expected ≈ 1711ms → ×1.6 ≈ 2738ms
      final t1080 = RangeCore.adaptiveSlowPieceThreshold(766000.0, concurrency: 3);
      expect(t1080.inMilliseconds, inInclusiveRange(2600, 3000));

      // ④ 下限夹取：并发 1、码率 2.405 MB/s → expected≈182ms → ×1.6≈291ms → 夹到 400ms
      expect(
        RangeCore.adaptiveSlowPieceThreshold(2405000.0, concurrency: 1)
            .inMilliseconds,
        equals(400),
      );

      // ⑤ 上限夹取：并发 1、480p 低码率 → expected≈22.5s → ×1.6≈35.9s → 夹到 3000ms
      expect(
        RangeCore.adaptiveSlowPieceThreshold(19455.375, concurrency: 1)
            .inMilliseconds,
        equals(3000),
      );

      // ⑥ 非法码率 → 兜底
      expect(
        RangeCore.adaptiveSlowPieceThreshold(0.0),
        equals(RangeCore.slowPieceThresholdDefault),
      );
      expect(
        RangeCore.adaptiveSlowPieceThreshold(-100.0),
        equals(RangeCore.slowPieceThresholdDefault),
      );
    });

    test('5. 异常/边界 URL 解析', () {
      // 缺少 bw 参数
      expect(
        RangeCore.parseBitrateBytesPerSec(
            'https://upos-sz-mirrorcos.bilivideo.com/video.m4s?mid=123'),
        isNull,
      );

      // 非法非数字 bw
      expect(
        RangeCore.parseBitrateBytesPerSec(
            'https://upos-sz-mirrorcos.bilivideo.com/video.m4s?bw=invalid'),
        isNull,
      );

      // 负数或 0 bw
      expect(
        RangeCore.parseBitrateBytesPerSec(
            'https://upos-sz-mirrorcos.bilivideo.com/video.m4s?bw=0'),
        isNull,
      );
      expect(
        RangeCore.parseBitrateBytesPerSec(
            'https://upos-sz-mirrorcos.bilivideo.com/video.m4s?bw=-1000'),
        isNull,
      );

      // 空 URL
      expect(RangeCore.parseBitrateBytesPerSec(''), isNull);

      // 码率为 null 时的兜底吞吐需求 (0.4 MB/s)
      expect(
        RangeCore.requiredThroughputBytesPerSec(null),
        equals(RangeCore.singleAdequateFallbackBps),
      );
    });

    test('6. CdnPool 构造与 reset 时自动按字节/秒解析码率', () {
      const url4k =
          'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/11/22/33/test_4k.m4s?bw=19240000&mid=123';
      final pool = CdnPool(originalUrls: [url4k]);

      // 构造时自动解析（阈值此时没有并发信息 → 回退固定 1200ms，真判定在下载器决策点更新）
      expect(pool.videoBitrateBytesPerSec, equals(2405000.0));
      expect(
        pool.slowPieceThreshold,
        equals(RangeCore.slowPieceThresholdDefault),
      );

      // reset() 后重新正确解析
      pool.reset();
      expect(pool.videoBitrateBytesPerSec, equals(2405000.0));
      expect(
        pool.slowPieceThreshold,
        equals(RangeCore.slowPieceThresholdDefault),
      );

      // 测试 bw 缺失时的兜底门限
      const urlNoBw =
          'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/11/22/33/test.m4s?mid=123';
      final poolNoBw = CdnPool(originalUrls: [urlNoBw]);
      expect(poolNoBw.videoBitrateBytesPerSec, isNull);
      expect(
        poolNoBw.slowPieceThreshold,
        equals(RangeCore.slowPieceThresholdDefault),
      );
    });
  });
}
