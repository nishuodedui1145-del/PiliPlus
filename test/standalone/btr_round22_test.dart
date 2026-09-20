// BTR FIX19 / 第二十二轮独立单元测试
//
// 验证项目：
// 1. defaultMaxPieceBytes 恢复为 512 KiB；
// 2. SidxParser & SidxCache：SIDX 解析、分段索引检索、按边界规划连续无重叠切片；
// 3. 跨节点总长度一致性校验 (checkTotalLengthConsistency)；
// 4. 降级直连 + 自动重接管 (markDirectFallback, checkRetakeoverEligible, onRetakeoverSuccess)；
// 5. CdnBanList node / address / pair 三级封禁粒度与 fail-open 保护；
// 6. 画面与声音分开预算 (GlobalSocketBudget) 与全局在途硬上限；
// 7. 起播并发起手值推导 (startupConcurrencyTiers)。

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

// ⚠️ 必须引镜像目录（与 btr_proxy_e2e_test.dart 一致）：
//    模块内部是用 package:PiliPlus/... 互相引用的，如果这里用相对路径引 lib/，
//    同一个类会被加载成两份，`error is UpstreamHttpException` 这类判断会静默失效。
//    跑测试前先执行：python tool/make_btr_mirror.py
import 'btr/cdn_pool.dart';
import 'btr/proxy_server.dart';
import 'btr/range_core.dart';
import 'btr/sidx_parser.dart';

Uint8List createMockSidxBox({
  int timescale = 1000,
  int earliestPresentationTime = 0,
  int firstOffset = 0,
  required List<({int size, int duration})> references,
}) {
  // sidx box header: 4 (size) + 4 ('sidx')
  // fullbox: 1 (version=0) + 3 (flags)
  // reference_id: 4
  // timescale: 4
  // earliest_presentation_time: 4 (v0)
  // first_offset: 4 (v0)
  // reserved: 2
  // reference_count: 2
  // each ref: 4 (type+size) + 4 (duration) + 4 (SAP) = 12 bytes
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
    view.setUint32(offset, ref.size & 0x7fffffff); offset += 4;
    view.setUint32(offset, ref.duration); offset += 4;
    view.setUint32(offset, 0x90000000); offset += 4; // SAP flags
  }

  return data;
}

void main() {
  group('1. RangeCore 常量与切块基准', () {
    test('defaultMaxPieceBytes 必须为 512 KiB', () {
      expect(RangeCore.defaultMaxPieceBytes, equals(512 * 1024));
    });

    test('起播 hedge 常量与交错延迟常量对齐', () {
      expect(RangeCore.startupHedgeDelay.inMilliseconds, equals(250));
      expect(RangeCore.hedgeDelay.inMilliseconds, equals(900));
      expect(RangeCore.startupStaggerDelaysMs, equals([0, 120, 300]));
      expect(RangeCore.startupMaxRaceCandidates, equals(8));
      expect(RangeCore.fallbackGraceMs, equals(3500));
      expect(RangeCore.retakeoverMaxAttempts, equals(3));
      expect(RangeCore.retakeoverBaseDelayMs, equals(4000));
      expect(RangeCore.retakeoverWindowMs, equals(120000));
    });
  });

  group('2. SidxParser & SidxCache', () {
    test('正确解析 mock SIDX box 并提取各分段字节区间', () {
      final sidxBytes = createMockSidxBox(
        timescale: 1000,
        references: [
          (size: 100000, duration: 2000),
          (size: 150000, duration: 2000),
          (size: 120000, duration: 2000),
        ],
      );

      final result = SidxParser.parseSidx(sidxBytes, 0);
      expect(result, isNotNull);
      expect(result!.segments.length, equals(3));

      // 第一个分段起始位置在 sidx box 之后
      final sidxBoxLen = sidxBytes.length;
      expect(result.segments[0].start, equals(sidxBoxLen));
      expect(result.segments[0].end, equals(sidxBoxLen + 100000 - 1));
      expect(result.segments[0].durationSeconds, equals(2.0));

      expect(result.segments[1].start, equals(result.segments[0].end + 1));
      expect(result.segments[1].end, equals(result.segments[1].start + 150000 - 1));

      expect(result.segments[2].start, equals(result.segments[1].end + 1));
      expect(result.segments[2].end, equals(result.segments[2].start + 120000 - 1));
    });

    test('planSegmentAlignedPieces 保证对目标区间无重叠且严格连续覆盖', () {
      final sidxBytes = createMockSidxBox(
        timescale: 1000,
        references: [
          (size: 100000, duration: 2000), // e.g. 56 .. 100055
          (size: 150000, duration: 2000), // e.g. 100056 .. 250055
          (size: 120000, duration: 2000), // e.g. 250056 .. 370055
        ],
      );
      final sidx = SidxParser.parseSidx(sidxBytes, 0)!;

      // 覆盖从 0 到 300000（跨越前两个分段）
      final pieces = SidxParser.planSegmentAlignedPieces(sidx.segments, 0, 300000);
      expect(pieces.isNotEmpty, isTrue);

      // 验证第一块从 0 开始，最后一块以 300000 结束
      expect(pieces.first.start, equals(0));
      expect(pieces.last.end, equals(300000));

      // 验证相邻块完全连续、无空隙、无重合
      for (var i = 0; i < pieces.length - 1; i++) {
        expect(pieces[i].end + 1, equals(pieces[i + 1].start));
      }
    });

    test('真实尺寸分段（5 MiB）必须片内再细分到 <=512 KiB，否则在途内存爆炸', () {
      // 真机实测教训：B 站单段就有 5~8 MiB，一段一片时出现 在途=33 × ~7 MiB ≈ 230 MB，
      // 且"慢块 1.2s"阈值对 8 MiB 分片永远判慢 → 大量误报。
      final sidxBytes = createMockSidxBox(
        timescale: 1000,
        references: [
          (size: 5 * 1024 * 1024, duration: 6000),
          (size: 2 * 1024 * 1024, duration: 3000),
        ],
      );
      final sidx = SidxParser.parseSidx(sidxBytes, 0)!;
      final total = sidx.segments.last.end;

      final pieces = SidxParser.planSegmentAlignedPieces(sidx.segments, 0, total);
      expect(pieces.length, greaterThan(10), reason: '7 MiB 至少要切成 14 片');
      expect(
        pieces.every((p) => p.length <= RangeCore.defaultMaxPieceBytes),
        isTrue,
        reason: '出现超过 512 KiB 的分片 → 在途内存 = 并发 × 单片大小 会失控',
      );
      for (var i = 0; i < pieces.length - 1; i++) {
        expect(pieces[i].end + 1, equals(pieces[i + 1].start));
      }
      expect(pieces.first.start, equals(0));
      expect(pieces.last.end, equals(total));
    });

    test('SidxCache 提取 path 作为稳定 key 并支持 TTL', () {
      const url1 = 'https://mirrorali.bilivideo.com/upgcxcode/123.m4s?sign=abc&deadline=100';
      const url2 = 'https://mirrorhw.bilivideo.com/upgcxcode/123.m4s?sign=def&deadline=200';

      final key1 = SidxCache.urlToKey(url1);
      final key2 = SidxCache.urlToKey(url2);
      expect(key1, equals('/upgcxcode/123.m4s'));
      expect(key1, equals(key2));

      final dummy = SidxResult(
        segments: [],
        timescale: 1000,
        earliestPresentationTime: 0,
        firstOffset: 0,
      );
      SidxCache.put(key1, dummy);
      expect(SidxCache.get(key1), isNotNull);
      SidxCache.invalidate(key1);
      expect(SidxCache.get(key1), isNull);
    });
  });

  group('3. 跨节点总长度一致性校验 (checkTotalLengthConsistency)', () {
    test('首个节点建立基准，同长度放行，不同长度告警并返回 false', () {
      final pool = CdnPool(originalUrls: ['https://mirrorali.bilivideo.com/v.m4s']);

      // 第一次收到 1000000
      expect(pool.checkTotalLengthConsistency(1000000, 'mirrorali.bilivideo.com'), isTrue);
      // 同一文件其它节点同样返回 1000000 放行
      expect(pool.checkTotalLengthConsistency(1000000, 'mirrorhw.bilivideo.com'), isTrue);

      // 异常节点返回了 1000500，拒绝拼装
      expect(pool.checkTotalLengthConsistency(1000500, 'mirrorcos.bilivideo.com'), isFalse);
    });
  });

  group('4. 降级直连与自动重接管 (page-hook 对齐)', () {
    test('记录降级直连与最多 3 次指数退避重接管', () {
      final pool = CdnPool(originalUrls: ['https://mirrorali.bilivideo.com/v.m4s']);
      expect(pool.isDirectPassthrough, isFalse);

      // 触发降级
      pool.markDirectFallback('测试超时降级');
      expect(pool.isDirectPassthrough, isTrue);
      expect(pool.retakeoverAttempts, equals(0));

      // 刚降级不可重接管（退避 4s 未到）
      expect(pool.checkRetakeoverEligible(), isFalse);

      // 模拟退避时间到达
      pool.nextRetakeoverTimeMs = DateTime.now().millisecondsSinceEpoch - 1;
      expect(pool.checkRetakeoverEligible(), isTrue);
      expect(pool.retakeoverAttempts, equals(1));

      // 成功恢复
      pool.onRetakeoverSuccess('mirrorali.bilivideo.com');
      expect(pool.isDirectPassthrough, isFalse);
      expect(pool.retakeoverAttempts, equals(0));
    });
  });

  group('5. CdnBanList 三级封禁 (node / address / pair)', () {
    test('403 仅封禁 address 和 pair，不连累 host', () {
      final banList = CdnBanList(strikeLimit: 2);
      const url = 'https://mirrorali.bilivideo.com/video/stream1.m4s?sign=1';
      const err403 = UpstreamHttpException(403, 'Forbidden');

      banList
        ..record(url, 0, err403)
        ..record(url, 0, err403);

      // 该特定地址与 pair 被封禁
      expect(banList.allows(url), isFalse);
      // 但同节点的其它资源依然放行（node 未被连累）
      const anotherUrl = 'https://mirrorali.bilivideo.com/video/stream2.m4s?sign=2';
      expect(banList.allows(anotherUrl), isTrue);
    });

    test('连续 0 字节错误达到 strikeLimit 封禁 host', () {
      final banList = CdnBanList(strikeLimit: 2);
      const url1 = 'https://mirrorali.bilivideo.com/video/stream1.m4s';
      const url2 = 'https://mirrorali.bilivideo.com/video/stream2.m4s';

      // 第 1 次 strike：未达上限，host 仍放行
      expect(banList.record(url1, 0, Exception('Connection reset')), isFalse,
          reason: '第 1 次 strike 未达 strikeLimit，不应封禁 host');
      expect(banList.allows(url1), isTrue);

      // 第 2 次 strike：达到 strikeLimit，封禁 host 且 record 返回 true
      expect(banList.record(url2, 0, Exception('Timeout')), isTrue,
          reason: '第 2 次 strike 达 strikeLimit，应封禁 host');
      expect(banList.allows(url1), isFalse);
      expect(banList.allows(url2), isFalse);
    });
  });

  group('6. 画面/声音分开预算 (GlobalSocketBudget)', () {
    test('预算按并发计算并独立分配画面与声音额度', () {
      final budget = GlobalSocketBudget()..updateBudget(8);

      // c=8 时: audio=2, rescue=1, video=8, globalLimit=11
      expect(budget.videoLimit, equals(8));
      expect(budget.audioLimit, equals(2));
      expect(budget.rescueLimit, equals(1));
      expect(budget.globalLimit, equals(11));
    });
  });

  group('7. 起播并发起手值分档推导 (startupConcurrencyTiers)', () {
    test('ratio >= 3.0 返回 2 并发，ratio 低返回 8 并发', () {
      int getTier(double ratio, int maxAllowed) {
        for (final tier in RangeCore.startupConcurrencyTiers) {
          if (ratio >= tier.$1) {
            return tier.$2.clamp(1, maxAllowed);
          }
        }
        return maxAllowed;
      }

      expect(getTier(3.5, 8), equals(2));
      expect(getTier(2.0, 8), equals(4));
      expect(getTier(1.5, 8), equals(6));
      expect(getTier(0.8, 8), equals(8));
    });
  });
}
