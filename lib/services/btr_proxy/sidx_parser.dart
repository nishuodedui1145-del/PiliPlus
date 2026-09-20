import 'dart:math';
import 'dart:typed_data';

import 'package:PiliPlus/services/btr_proxy/range_core.dart';

/// SIDX 数据分片信息
class SidxSegment {
  final int index;
  final int start;
  final int end;
  final int length;
  final int time;
  final int duration;
  final double startTime;
  final double endTime;
  final double durationSeconds;

  SidxSegment({
    required this.index,
    required this.start,
    required this.end,
    required this.length,
    required this.time,
    required this.duration,
    required this.startTime,
    required this.endTime,
    required this.durationSeconds,
  });
}

/// SIDX 解析结果
class SidxResult {
  final List<SidxSegment> segments;
  final int timescale;
  final int earliestPresentationTime;
  final int firstOffset;

  SidxResult({
    required this.segments,
    required this.timescale,
    required this.earliestPresentationTime,
    required this.firstOffset,
  });
}

class _SidxCacheEntry {
  final SidxResult result;
  final int timestamp;

  _SidxCacheEntry(this.result, this.timestamp);
}

/// SIDX 缓存，按 URL path 作为 key
class SidxCache {
  static final Map<String, _SidxCacheEntry> _cache = {};
  static const int _ttlMs = 600000; // 10分钟

  /// 提取 URL 中的 path 作为缓存 Key，去除参数和签名信息
  static String urlToKey(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.path;
    } catch (e) {
      BtrLog.rateLimitedLog(
        'sidx_cache_url_fail',
        '[BTR] [SidxCache] 解析 URL 失败: $e',
      );
      return url;
    }
  }

  /// 获取缓存，过期则返回 null 并清除
  static SidxResult? get(String urlKey) {
    final entry = _cache[urlKey];
    if (entry == null) return null;
    
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - entry.timestamp > _ttlMs) {
      _cache.remove(urlKey);
      return null;
    }
    return entry.result;
  }

  /// 存入缓存
  static void put(String urlKey, SidxResult result) {
    _cache[urlKey] = _SidxCacheEntry(
      result,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// 失效特定缓存
  static void invalidate(String urlKey) {
    _cache.remove(urlKey);
  }

  /// 清空全部缓存
  static void clear() {
    _cache.clear();
  }
}

/// SIDX 解析器
abstract final class SidxParser {
  /// 读取 64位无符号整型
  static int? _readUint64(ByteData view, int offset) {
    final high = view.getUint32(offset);
    final low = view.getUint32(offset + 4);
    // 组合高低位，Dart 的 int 支持 64位
    final value = (high * 4294967296) + low;
    return value;
  }

  /// 读取 Box 类型
  static String _readType(Uint8List bytes, int offset) {
    return String.fromCharCodes(bytes.sublist(offset, offset + 4));
  }

  /// 解析 SIDX box
  static SidxResult? parseSidx(Uint8List bytes, [int absoluteStart = 0]) {
    final view = ByteData.sublistView(bytes);
    int boxOffset = 0;

    while (boxOffset + 8 <= bytes.length) {
      int boxSize = view.getUint32(boxOffset);
      final type = _readType(bytes, boxOffset + 4);
      int headerSize = 8;

      if (boxSize == 1) {
        if (boxOffset + 16 > bytes.length) return null;
        boxSize = _readUint64(view, boxOffset + 8) ?? 0;
        headerSize = 16;
      } else if (boxSize == 0) {
        boxSize = bytes.length - boxOffset;
      }

      if (boxSize == 0 || boxSize < headerSize || boxOffset + boxSize > bytes.length) {
        return null;
      }

      if (type == 'sidx') {
        int cursor = boxOffset + headerSize;
        if (cursor + 12 > boxOffset + boxSize) return null;

        final version = view.getUint8(cursor);
        cursor += 4; // skip version & flags
        cursor += 4; // skip reference_ID
        
        final timescale = view.getUint32(cursor);
        cursor += 4;
        if (timescale == 0) return null;

        int earliestPresentationTime;
        int firstOffset;

        if (version == 0) {
          if (cursor + 8 > boxOffset + boxSize) return null;
          earliestPresentationTime = view.getUint32(cursor);
          firstOffset = view.getUint32(cursor + 4);
          cursor += 8;
        } else if (version == 1) {
          if (cursor + 16 > boxOffset + boxSize) return null;
          earliestPresentationTime = _readUint64(view, cursor) ?? 0;
          firstOffset = _readUint64(view, cursor + 8) ?? 0;
          cursor += 16;
        } else {
          return null;
        }

        cursor += 2; // skip reserved
        if (cursor + 2 > boxOffset + boxSize) return null;
        final referenceCount = view.getUint16(cursor);
        cursor += 2;

        if (referenceCount < 1 || referenceCount > 10000 || cursor + referenceCount * 12 > boxOffset + boxSize) {
          return null;
        }

        int byteCursor = absoluteStart + boxOffset + boxSize + firstOffset;
        int timeCursor = earliestPresentationTime;
        final segments = <SidxSegment>[];

        for (int index = 0; index < referenceCount; index += 1) {
          final reference = view.getUint32(cursor);
          final referenceType = (reference >> 31) & 1;
          final referencedSize = reference & 0x7fffffff;
          final duration = view.getUint32(cursor + 4);
          cursor += 12;

          if (referencedSize == 0) return null;

          // 防回归 P2-11: 分层 sidx（referenceType != 0）指向子 sidx box。
          // 当前不递归加载子 sidx，宁可不用也不给残缺有空洞的分段表，
          // 整个 parseSidx 直接返回 null 安全回退到等分切片。
          if (referenceType != 0) {
            return null;
          }

          segments.add(SidxSegment(
            index: segments.length,
            start: byteCursor,
            end: byteCursor + referencedSize - 1,
            length: referencedSize,
            time: timeCursor,
            duration: duration,
            startTime: timeCursor / timescale,
            endTime: (timeCursor + duration) / timescale,
            durationSeconds: duration / timescale,
          ));
          byteCursor += referencedSize;
          timeCursor += duration;
        }

        if (segments.isEmpty) return null;

        return SidxResult(
          earliestPresentationTime: earliestPresentationTime,
          firstOffset: firstOffset,
          segments: segments,
          timescale: timescale,
        );
      }
      boxOffset += boxSize;
    }
    return null;
  }

  /// 二分查找包含目标时间 (秒) 的分片索引
  static int segmentIndexAt(List<SidxSegment> segments, double seconds) {
    if (segments.isEmpty) return -1;
    final target = seconds < 0 ? 0.0 : seconds;
    int low = 0;
    int high = segments.length - 1;

    while (low <= high) {
      final middle = (low + high) >> 1;
      final segment = segments[middle];
      if (target < segment.startTime) {
        high = middle - 1;
      } else if (target >= segment.endTime) {
        low = middle + 1;
      } else {
        return middle;
      }
    }
    
    int result = low;
    if (result < 0) result = 0;
    if (result >= segments.length) result = segments.length - 1;
    return result;
  }

  /// 规划"按 SIDX 分段边界对齐、且单片不超过 [maxPieceBytes]"的 RangePiece 列表，
  /// 保证严格连续覆盖 [rangeStart, rangeEnd]（无缝隙、无重叠）。
  ///
  /// 为什么必须在片内再细分（真机实测教训）：B 站真实分段的**单段就有 5~8 MiB**。
  /// 若一段一片：
  ///   1. 在途内存 = 并发数 × 单片大小 → 真机跑到 `在途=33/上限=33` × ~7 MiB ≈ **230 MB**；
  ///   2. "慢块阈值 1.2s"这类按 512 KiB 标定的判据会永远判慢 → hedge／切单连接逻辑误触发
  ///      （真机日志里出现成片的"慢块…耗时 11.5s（阈值 1.20s）"噪音）。
  /// 官方在分段之上同样是用 splitRange 切成小片下发的（minChunkBytes=64 KiB），
  /// 所以"对齐分段起点 + 片内按 512 KiB 细分"能同时保住对齐收益和既有内存/阈值模型。
  static List<RangePiece> planSegmentAlignedPieces(
    List<SidxSegment> segments,
    int rangeStart,
    int rangeEnd, {
    int maxPieceBytes = RangeCore.defaultMaxPieceBytes,
  }) {
    if (segments.isEmpty || rangeStart > rangeEnd) return const [];
    final cap = maxPieceBytes > 0
        ? maxPieceBytes
        : RangeCore.defaultMaxPieceBytes;

    // 1. 先按分段边界切出"对齐区间"（含首尾的非分段区域）
    final spans = <(int, int)>[];
    final firstSeg = segments.first;
    final lastSeg = segments.last;

    if (rangeStart < firstSeg.start) {
      spans.add((rangeStart, min(rangeEnd, firstSeg.start - 1)));
      if (rangeEnd < firstSeg.start) {
        return _subdivideSpans(spans, cap);
      }
    }

    for (final seg in segments) {
      if (seg.end < rangeStart) continue;
      if (seg.start > rangeEnd) break;
      final start = max(rangeStart, seg.start);
      final end = min(rangeEnd, seg.end);
      if (start <= end) spans.add((start, end));
    }

    if (rangeEnd > lastSeg.end) {
      spans.add((max(rangeStart, lastSeg.end + 1), rangeEnd));
    }

    return _subdivideSpans(spans, cap);
  }

  /// 把若干对齐区间各自按 [cap] 切成连续小片，并统一编号
  static List<RangePiece> _subdivideSpans(
    List<(int, int)> spans,
    int cap,
  ) {
    final pieces = <RangePiece>[];
    for (final (spanStart, spanEnd) in spans) {
      var cursor = spanStart;
      while (cursor <= spanEnd) {
        final end = min(cursor + cap - 1, spanEnd);
        pieces.add(RangePiece(
          index: pieces.length,
          start: cursor,
          end: end,
          length: end - cursor + 1,
        ));
        cursor = end + 1;
      }
    }
    return pieces;
  }
}
