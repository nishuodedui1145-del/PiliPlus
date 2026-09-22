import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

/// 表示一个具体的字节区间
class ByteRange {
  final int start;
  final int end;
  final int? total;

  const ByteRange({
    required this.start,
    required this.end,
    this.total,
  });

  int get length => end - start + 1;

  @override
  String toString() =>
      'ByteRange($start-$end/${total == null ? '*' : total.toString()})';
}

/// 表示 HTTP 请求中的 Range 范围（end 可能未指定，如 bytes=0-）
class HttpRange {
  final int start;
  final int? end;

  const HttpRange({
    required this.start,
    this.end,
  });

  int? get length => end != null ? end! - start + 1 : null;

  @override
  String toString() => 'HttpRange($start-${end ?? ''})';
}

/// 拆分出的单个并发 piece
class RangePiece {
  final int index;
  final int start;
  final int end;
  final int length;

  const RangePiece({
    required this.index,
    required this.start,
    required this.end,
    required this.length,
  });

  @override
  String toString() =>
      'RangePiece(index: $index, bytes: $start-$end, length: $length)';
}

/// 上游不支持或忽略 Range 异常（触发单连接顺序透传降级）
class RangeNotSupportedException implements Exception {
  final String message;
  const RangeNotSupportedException(this.message);

  @override
  String toString() => 'RangeNotSupportedException: $message';
}

/// 上游 HTTP 错误响应异常（携带状态码与 URI，如 403 Forbidden）
class UpstreamHttpException implements Exception {
  final int statusCode;
  final String message;
  final Uri? uri;

  const UpstreamHttpException(this.statusCode, this.message, {this.uri});

  @override
  String toString() =>
      'UpstreamHttpException: HTTP $statusCode ($message)${uri != null ? ' host: ${uri!.host}' : ''}';
}

/// BTR 核心 Range 解析、切分与校验逻辑
abstract final class RangeCore {
  static const int defaultConcurrency = 8;
  static const int defaultMinChunkBytes = 64 * 1024; // 64 KiB

  /// 固定分块大小（默认 512 KiB）
  /// ↑ 回退到第十一轮的值（真机 A/B：128 KiB 那次起播更慢、速率更差）
  ///
  /// 与官方的关系（`range-core.js:35` splitRange 的真实算法）：
  ///   片数 = min(并发, ceil(区间长度 / minChunkBytes))，**片长 = 区间长度 / 片数**
  /// 也就是说官方那个「64 KiB」只是**小片区间的下限**，不是标称片长：默认 8 线程、
  /// 4 MiB 区间时官方片长 = 4 MiB / 8 = **512 KiB**，与我们一致。区间更大时官方片长会涨到
  /// MB 级，我们固定在 512 KiB —— 这是**故意的**：片长与并发解耦，在途内存才有上界
  /// （= 并发 × 片长），「慢块阈值 / hedge」这类按片标定的判据也才始终可用。
  ///
  /// 外部同类实现的取向同样指向"别切太小"：aria2 的 `--min-split-size` 默认 **20 MiB**
  /// （官方解释是防止连接抖动），yt-dlp 教程推荐 `-k 1M`；HTTP/1.1 新连接要走 TCP 慢启动，
  /// 64 KiB 这种小片在 40~80 ms RTT 的跨洋链路上基本被 RTT/建连开销吃掉。
  ///
  /// 块数 = ceil(区间长度 / maxPieceBytes)；峰值内存上限 = 并发 × maxPieceBytes
  /// （例如 8 × 512 KiB = 4 MiB，32 × 512 KiB = 16 MiB）
  static const int defaultMaxPieceBytes = 512 * 1024; // 512 KiB

  /// 视频侧并发预算下限（建议 8，避免并发被压死无法起播）
  static const int minVideoBudget = 8;

  /// 全局并发预算上限（防止极端配置耗尽系统文件描述符）
  static const int maxGlobalSockets = 64;

  /// 探速/测速独立小预算并发上限（建议并发 <= 2，不与视频 piece 争抢）
  static const int maxProbeConcurrency = 2;

  /// 计算官方并发预算分配（对齐官方 idm-downloader.js:313-318 / 387-392）：
  /// - 视频侧预算不得低于下限（8），且受全局上限（64）约束，不再出现「视频=4 / 全局=7」
  /// - 音频固定 2 条，补救预留 1 条
  static ({int rescueReserve, int mediaBudget, int audioBudget, int videoBudget})
      calculateBudget(int c) {
    final effectiveC = max(minVideoBudget, min(maxGlobalSockets, c));
    const audioBudget = 2;
    const rescueReserve = 1;
    final videoBudget = effectiveC;
    final mediaBudget = videoBudget + rescueReserve;
    return (
      rescueReserve: rescueReserve,
      mediaBudget: mediaBudget,
      audioBudget: audioBudget,
      videoBudget: videoBudget,
    );
  }

  /// 自适应并发判定阈值：实测单连接速度 >= 4 MB/s 时降为 2 并发（真机实测 CDN 单连接几乎达不到原 8 MB/s）
  static const double fastNodeBpsThreshold = 4.0 * 1024 * 1024; // 4 MB/s (~32 Mbps)
  static const int fastNodeConcurrency = 2; // 快节点并发数（先按 2 试）
  static const double adaptiveGainThreshold = 1.3; // 并发收益阈值 (需达 1.3x 单连接速度，对齐任务 C 建议阈值)

  /// 切单连接的额外门限：单连接自身至少达到「码率 × 该倍数」才认为"不需要并发"。
  /// 否则（例如全网 0.1 MB/s 的死网络）切单连接会把多连接的聚合能力白白丢掉。
  /// 提高安全边际（从 1.2 提升至 1.5，对齐任务 2.1 建议），避免低估带宽需求。
  static const double singleConnectionAdequateMargin = 1.5;

  /// 播放基准目标吞吐倍数（用于慢块理论耗时评估与分片节拍，码率 × 1.2）
  static const double playbackPacingMargin = 1.2;

  /// 短样本（如 64~128KB 竞速/启动探测）测速结果打折系数（对齐任务 2.2，打七折保守化）
  static const double shortSampleDiscount = 0.7;

  /// 拿不到码率参数时的"单连接够用"下限（0.4 MB/s ≈ 3.2 Mbps，够 1080p60）。
  /// 判据：单连接实测 ≥ 该值 且 聚合没比它快 1.3 倍 → 才切单连接。
  static const double singleAdequateFallbackBps = 0.4 * 1024 * 1024;

  /// 从上游播放 URL 中解析视频/音频码率（字节/秒）。
  ///
  /// 依据：bilibili 的 bw 参数单位为 bit/s（实测 bw=155643 ↔ yt-dlp 报 156 kbps），
  /// 下游一律按字节/秒比较，故 ÷8.0。
  static double? parseBitrateBytesPerSec(String url) {
    try {
      final uri = Uri.parse(url);
      final bwStr = uri.queryParameters['bw'];
      if (bwStr != null) {
        final bw = double.tryParse(bwStr);
        if (bw != null && bw > 0) return bw / 8.0;
      }
    } catch (_) {}
    return null;
  }

  /// 别名：从 URL 提取码率
  static double? extractBitrateFromUrl(String url) => parseBitrateBytesPerSec(url);

  /// 视频最低合理码率下限（50 kbps = 6.25 KB/s）
  static const double minReasonableVideoBitrateBps = 50.0 * 1000 / 8.0;

  /// 视频码率合理性校验（低于最低合理下限或远低于同一次 playurl 中其他视频候选则判定为可疑非视频轨）
  static double? validateVideoBitrate([
    double? rawBytesPerSec,
  ]) => validateVideoBitrateEx(rawBytesPerSec: rawBytesPerSec);

  /// 扩展视频码率合理性校验（支持位置参数与命名参数两种调用方式）
  static double? validateVideoBitrateEx({
    double? rawBytesPerSec,
    double? bitrateBytesPerSec,
    String? source,
    List<double>? candidateBitratesBytesPerSec,
    List<double>? otherCandidateBitratesBps,
  }) {
    final effectiveRaw = rawBytesPerSec ?? bitrateBytesPerSec;
    if (effectiveRaw == null || effectiveRaw <= 0) {
      return null;
    }
    final bwBps = effectiveRaw * 8.0;
    if (bwBps < minReasonableVideoBitrateBps * 8.0) {
      BtrLog.log(
        '[BTR] 码率解析可疑: bw=${bwBps.round()}（疑似非视频轨）'
        '${source != null ? ' source=$source' : ''}',
      );
      return null;
    }
    final candidates = candidateBitratesBytesPerSec ?? otherCandidateBitratesBps;
    if (candidates != null && candidates.isNotEmpty) {
      final validCandidates =
          candidates.where((b) => b * 8.0 >= minReasonableVideoBitrateBps * 8.0).toList();
      if (validCandidates.isNotEmpty) {
        final minCandidate = validCandidates.reduce(min);
        if (effectiveRaw < minCandidate * 0.3) {
          BtrLog.log(
            '[BTR] 码率解析可疑: bw=${bwBps.round()}（疑似非视频轨）'
            '${source != null ? ' source=$source' : ''}',
          );
          return null;
        }
      }
    }
    return effectiveRaw;
  }

  /// 单条连接吞吐的下限（32 KB/s）；用于避免 perConn 过小导致反推出荒唐的并发数
  static const double minPerConnectionBps = 32.0 * 1024;

  /// 并发"小步爬升"上限：一次评估最多把并发提到这么多条
  /// （避免在坏网络里按反推公式一步顶到配置上限，如 32 条——真机 04:06 日志那种）
  static const int maxRampConcurrency = 8;

  /// 切回多连接时的迟滞系数：单连接速度低于「目标 × 该系数（0.8）」才考虑解粘，
  /// 与切入判据（≥ 目标）拉开 20% 死区，防止在两者之间反复横跳。
  static const double switchBackMargin = 0.8;

  /// 切入单连接硬条件容差：单连接吞吐必须 >= 多连接聚合吞吐 × 该系数（0.95）
  static const double singleNotWorseFactor = 0.95;

  /// 解粘对比硬条件：切入时多连接吞吐必须 > 当前单连接吞吐 × 该系数（1.1）
  static const double switchBackMultiBetterFactor = 1.1;

  /// 模式切换最小驻留时间（20 秒）
  static const Duration minModeDwell = Duration(seconds: 20);

  /// 模式切换每分钟最大次数（2 次）
  static const int maxModeSwitchesPerMinute = 2;

  /// "够用"的目标吞吐（字节/秒）：优先「码率 × 1.2」；拿不到码率时用 0.4 MB/s 下限。
  /// 切入/切出单连接、反推并发数都必须用同一个函数取值，否则会出现门限倒挂
  /// （历史 bug：切入用 0.4 MB/s、切回却用 3 MB/s×1.2=3.6 MB/s，必然反复横跳）。
  static double requiredThroughputBytesPerSec(double? bitrateBytesPerSec) =>
      bitrateBytesPerSec != null && bitrateBytesPerSec > 0
          ? bitrateBytesPerSec * singleConnectionAdequateMargin
          : singleAdequateFallbackBps;

  /// 自适应并发评估的最小可信样本（时长 / 字节数）；样本不足时不下结论，避免按噪声切换。
  static const double minAdaptiveSampleSeconds = 1.0;
  static const int minAdaptiveSampleBytes = 512 * 1024;
  static const int defaultMaxInFlightExtra = 2; // 全局在途 socket 预算增量 (默认 concurrency + 2)
  static const int minPieceRetries = 3; // 单分块失败最小重试次数

  static const Duration firstByteTimeout = Duration(milliseconds: 15000);
  static const Duration stallTimeout = Duration(milliseconds: 4000);
  static const Duration attemptTimeout = Duration(milliseconds: 15000);
  static const Duration hedgeDelay = Duration(milliseconds: 900);

  /// 起播阶段 hedge 延迟（对齐官方 idm-downloader.js:249 startup hedge = min(250, hedgeDelayMs)）
  static const Duration startupHedgeDelay = Duration(milliseconds: 250);

  /// 慢块判定倍数（实际耗时 > 1.6 × expectedPieceMs 算慢块）
  static const double slowPieceFactor = 1.6;

  /// 慢块阈值下限（400ms）
  static const Duration slowPieceMinThreshold = Duration(milliseconds: 400);

  /// 慢块阈值上限（3000ms）
  static const Duration slowPieceMaxThreshold = Duration(milliseconds: 3000);

  /// 慢块阈值默认/回退值（1200ms）
  static const Duration slowPieceThresholdDefault = Duration(milliseconds: 1200);

  /// 默认慢块判定与补救阈值（保留兼容原有静态引用）
  static const Duration slowPieceThreshold = slowPieceThresholdDefault;

  /// 历史固定档位常量（保留兼容）
  static const Duration slowPieceThreshold4K = Duration(milliseconds: 800);
  static const Duration slowPieceThreshold1080p60 = Duration(milliseconds: 900);
  static const Duration slowPieceThreshold1080p = Duration(milliseconds: 1500);
  static const double bitrateThreshold4K = 12.0 * 1000 * 1000 / 8; // 12 Mbps = 1.5 MB/s
  static const double bitrateThreshold1080p60 = 5.0 * 1000 * 1000 / 8; // 5 Mbps = 0.625 MB/s
  static const double bitrateThreshold1080p = 4.0 * 1000 * 1000 / 8; // 4 Mbps = 0.5 MB/s

  /// 计算单个 piece 的理论期望耗时（毫秒）：
  /// expectedPieceMs = pieceBytes ÷ (targetBps ÷ concurrency)
  static double calculateExpectedPieceMs({
    required int pieceBytes,
    double? targetBps,
    int? concurrency,
    double? bitrateBytesPerSec,
  }) {
    final c = (concurrency != null && concurrency > 0)
        ? concurrency
        : defaultConcurrency;
    final effectiveTargetBps = (targetBps != null && targetBps > 0)
        ? targetBps
        : (bitrateBytesPerSec != null && bitrateBytesPerSec > 0
            ? bitrateBytesPerSec * playbackPacingMargin
            : singleAdequateFallbackBps);
    final perConnBps = effectiveTargetBps / c;
    if (perConnBps <= 0) return 1200.0;
    return (pieceBytes / perConnBps) * 1000.0;
  }

  /// 慢块阈值按每连接份额动态计算（对齐第十六轮任务 A）：
  /// - expectedPieceMs = pieceBytes ÷ (targetBps ÷ concurrency)
  /// - 实际耗时 > slowPieceFactor(1.6) × expectedPieceMs 才算慢块
  /// - 阈值夹在 [slowPieceMinThreshold(400ms), slowPieceMaxThreshold(3000ms)]
  /// - 码率未知或无并发信息时回退固定 slowPieceThresholdDefault(1200ms)
  static Duration adaptiveSlowPieceThreshold(
    double? bitrateBytesPerSec, {
    double? targetBps,
    int? concurrency,
    int pieceBytes = defaultMaxPieceBytes,
  }) {
    if (bitrateBytesPerSec == null || bitrateBytesPerSec <= 0) {
      return slowPieceThresholdDefault;
    }
    if (concurrency == null || concurrency <= 0) {
      return slowPieceThresholdDefault;
    }
    final effectiveTargetBps = (targetBps != null && targetBps > 0)
        ? targetBps
        : (bitrateBytesPerSec * playbackPacingMargin);
    if (effectiveTargetBps <= 0) {
      return slowPieceThresholdDefault;
    }
    final perConnBps = effectiveTargetBps / concurrency;
    if (perConnBps <= 0) {
      return slowPieceThresholdDefault;
    }
    final expectedPieceMs = (pieceBytes / perConnBps) * 1000.0;
    final thresholdMs = (expectedPieceMs * slowPieceFactor).round();
    final clampedMs = thresholdMs.clamp(
      slowPieceMinThreshold.inMilliseconds,
      slowPieceMaxThreshold.inMilliseconds,
    );
    return Duration(milliseconds: clampedMs);
  }

  /// 启动测速候选节点数总量上限（回退到第十一轮的 4 个候选）
  static const int defaultStartupProbeCandidateCount = 4;

  /// 启动测速每批最大并发路数（对齐 maxProbeConcurrency: 最多 2 路并发，不与视频 piece 争抢）
  static const int defaultStartupProbeBatchConcurrency = maxProbeConcurrency;

  /// 启动测速分块大小（64 KiB：必须在 0.5 秒预算内测得出速度，
  /// 用 256KB 样本在慢节点上会全部超时 -> 等于没测，真机 04:06 日志已确认）
  static const int defaultStartupProbeChunkBytes = 64 * 1024;

  /// 首响应硬上限：从收到客户端请求到**必须发出响应头**的最长时间。
  /// 必须短于 mpv/ffmpeg 读响应头的超时（实测约 4~5 秒会报
  /// "http: Error reading HTTP response: Connection timed out"）。
  /// 超过就先用「1 字节 Range」把头顶出去（Dart 的 HttpServer 只有在写入
  /// 至少 1 字节 body 时才真正发响应头 —— PC 实测确认），再转纯数据透传。
  static const Duration firstResponseDeadline = Duration(milliseconds: 1800);

  /// "1 字节顶头"请求的超时：与既有首字节超时一致（跨海首字节常见 1~3s，避免 1.2s 过早超时退化为 200）
  static const Duration primerFetchTimeout = firstByteTimeout;

  /// 启动测速整体时间上限（压到 0.4 秒：这个时间段内播放器在等第一个字节，
  /// 真机对比过 1.5 秒上限会让起播黑屏明显变长）
  static const Duration startupProbeTotalTimeout = Duration(milliseconds: 400);

  /// 启动测速单批超时（0.3 秒；超时的批次视为未知，不拉黑节点、不阻塞起播）
  static const Duration startupProbeBatchTimeout = Duration(milliseconds: 300);

  /// 加权选择可用节点时的下限速度（64 KB/s），防止极慢节点权重为 0 或出现异常比例
  static const double minWeightedSelectionBps = 64.0 * 1024;

  /// 起播交错竞速延迟列表（对齐官方 idm-downloader.js:315: [0, 120, 300]ms）
  static const List<int> startupStaggerDelaysMs = [0, 120, 300];

  /// 起播最多竞速候选数（对齐官方 cdn-resolver.js:254: candidates.slice(0, 8)）
  static const int startupMaxRaceCandidates = 8;

  /// 降级直连后自动重试并发的退避公式（对齐官方 page-hook.js:157:
  ///   delay = 4000 * 2^(attempt-1)，最多 3 次，2 分钟窗口重置）
  static const int retakeoverMaxAttempts = 3;
  static const int retakeoverBaseDelayMs = 4000;
  static const int retakeoverWindowMs = 120000; // 2 分钟

  /// 降级直连前的宽限延迟（对齐官方 page-hook.js:1081: setTimeout(..., 3500)）
  static const int fallbackGraceMs = 3500;

  /// 起播硬截止时间（对齐 fallbackGraceMs: 3500ms，超时未出数据立即 302 让路）
  static const Duration startupHardDeadline = Duration(milliseconds: fallbackGraceMs);

  /// 起播阶段并发起手值公式的 ratio 分档阈值（对齐官方 native-mse-player.js:365-369）
  /// 代理层翻译：按 ratio = throughput / required 分档推导起播并发起手值
  ///   ratio >= 3.0 → 起手 2 并发（网络极好且远超需求，少量并发即够）
  ///   ratio >= 2.0 → 起手 4 并发
  ///   ratio >= 1.0 → 起手 6 并发
  ///   ratio < 1.0  → 起手 8 并发
  static const List<(double, int)> startupConcurrencyTiers = [
    (3.0, 2),
    (2.0, 4),
    (1.0, 6),
    (0.0, 8),
  ];

  /// 并发升档档位阶梯（对齐任务 1.2）
  static const List<int> concurrencyTiers = [2, 4, 6, 8, 12, 16, 24, 32];

  /// 根据当前并发与上限计算升一档后的并发数（用于队头饿死连续对冲升档）
  static int nextConcurrencyTier(int current, int maxCap) {
    for (final tier in concurrencyTiers) {
      if (tier > current) {
        return min(tier, maxCap);
      }
    }
    return maxCap;
  }

  static final RegExp _mediaSuffixRegex =
      RegExp(r'\.(?:m4s|mp4|flv)(?:\?|$)', caseSensitive: false);

  static final RegExp _mediaHostRegex = RegExp(
    r'(?:^|\.)(?:bilivideo\.(?:com|cn|net)|akamaized\.net|szbdyd\.com|hdslb\.com|xycdn\.com|mountaintoys\.cn|nexusedgeio\.com|ahdohpiechei\.com)$',
    caseSensitive: false,
  );

  /// 解析简单的 "start-end" 字符串
  static ByteRange? parseByteRange(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    final match = RegExp(r'^(\d+)-(\d+)$').firstMatch(trimmed);
    if (match == null) return null;
    final start = int.tryParse(match.group(1)!);
    final end = int.tryParse(match.group(2)!);
    if (start == null || end == null || end < start || start < 0) return null;
    return ByteRange(start: start, end: end);
  }

  /// 解析 HTTP 请求头中的 Range: bytes=start-end 或 bytes=start-
  static HttpRange? parseRangeHeader(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    final match =
        RegExp(r'^bytes=(\d+)-(\d+)?$', caseSensitive: false).firstMatch(trimmed);
    if (match == null) return null;
    final start = int.tryParse(match.group(1)!);
    if (start == null || start < 0) return null;
    final endStr = match.group(2);
    if (endStr != null && endStr.isNotEmpty) {
      final end = int.tryParse(endStr);
      if (end == null || end < start) return null;
      return HttpRange(start: start, end: end);
    }
    return HttpRange(start: start, end: null);
  }

  /// 解析 HTTP 响应头中的 Content-Range: bytes start-end/total 或 bytes start-end/*
  static ByteRange? parseContentRange(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    final match =
        RegExp(r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$', caseSensitive: false)
            .firstMatch(trimmed);
    if (match == null) return null;
    final start = int.tryParse(match.group(1)!);
    final end = int.tryParse(match.group(2)!);
    if (start == null || end == null || end < start || start < 0) return null;
    final totalStr = match.group(3);
    final total = totalStr == '*' ? null : int.tryParse(totalStr!);
    if (total != null && (total <= end || total < 0)) return null;
    return ByteRange(start: start, end: end, total: total);
  }

  /// 将 [start, end] 区间按固定块上限 [maxPieceBytes] 切分成多个 RangePiece
  /// 块大小与并发数完全解耦，块数 = ceil(区间长度 / maxPieceBytes)
  ///
  /// 【内存上限保证】：单 piece 大小最多为 maxPieceBytes（默认 64 KiB）。
  /// 在滑动窗口调度下，在途 + 缓冲的 piece 数严格不超过 concurrency，
  /// 故整段流式传输的峰值内存占用有明确上限：concurrency × maxPieceBytes（例如 8 × 64 KiB = 512 KiB，32 × 64 KiB = 2 MiB）。
  static List<RangePiece> splitRange(
    int start,
    int end, {
    int maxPieceBytes = defaultMaxPieceBytes,
    int? concurrency, // 保留兼容老调用，切块大小不再由 concurrency 决定
  }) {
    final length = end - start + 1;
    if (length <= 0) return const [];
    final pieceSize = maxPieceBytes.clamp(32 * 1024, 16 * 1024 * 1024);
    final count = (length / pieceSize).ceil();
    final pieces = <RangePiece>[];
    var cursor = start;
    for (var index = 0; index < count; index++) {
      final curEnd = min(cursor + pieceSize - 1, end);
      final size = curEnd - cursor + 1;
      pieces.add(RangePiece(
        index: index,
        start: cursor,
        end: curEnd,
        length: size,
      ));
      cursor = curEnd + 1;
    }
    return pieces;
  }

  /// 按序拼接所有 chunk，若长度不匹配则抛出 RangeError
  static Uint8List concatChunks(List<Uint8List> chunks, int expectedLength) {
    final output = Uint8List(expectedLength);
    var offset = 0;
    for (final chunk in chunks) {
      if (offset + chunk.lengthInBytes > expectedLength) {
        throw RangeError('子区间超出目标长度');
      }
      output.setRange(offset, offset + chunk.lengthInBytes, chunk);
      offset += chunk.lengthInBytes;
    }
    if (offset != expectedLength) {
      throw RangeError('子区间总长度不符：$offset/$expectedLength');
    }
    return output;
  }

  /// 检查是否为合法的哔哩哔哩媒体 URL
  static bool isBilibiliMediaUrl(String value) {
    try {
      final uri = Uri.parse(value);
      if (!uri.hasScheme || (uri.scheme != 'http' && uri.scheme != 'https')) {
        return false;
      }
      return _mediaSuffixRegex.hasMatch(uri.path) &&
          _mediaHostRegex.hasMatch(uri.host);
    } catch (_) {
      return false;
    }
  }
}

/// BTR 诊断埋点日志工具（支持限流与 URL 脱敏截断，内置 2000 行环形缓冲）
abstract final class BtrLog {
  static const int maxCapacity = 2000;
  static const int maxRateLimitKeys = 512;
  static final ListQueue<String> _buffer = ListQueue<String>();
  static final Map<String, int> _lastLogTimeMs = {};

  /// 环形缓冲当前行数
  static int get length => _buffer.length;

  /// 日志快照：返回最近最多 2000 行日志的只读副本
  static List<String> snapshot() => List<String>.from(_buffer);

  /// 清空日志环形缓冲与限流记录
  static void clear() {
    _buffer.clear();
    _lastLogTimeMs.clear();
  }

  static void _append(String safeMessage) {
    if (safeMessage.contains('\n')) {
      for (final line in safeMessage.split('\n')) {
        _appendLine(line);
      }
    } else {
      _appendLine(safeMessage);
    }
  }

  static void _appendLine(String line) {
    if (_buffer.length >= maxCapacity) {
      _buffer.removeFirst();
    }
    _buffer.addLast(line);
  }

  /// 异常脱敏：把异常文本里的 http(s) 直链压成 host，防止带签名的 query 进日志。
  /// 不能用 Uri.parse 兜底 —— 解析失败会退回原始串，等于没脱敏；这里只做纯文本截取，
  /// 连 scheme 一起丢掉，保证输出里不可能残留 query。
  static String redact(Object? e) {
    if (e == null) return 'null';
    return e.toString().replaceAllMapped(
          RegExp(r'''[a-zA-Z][a-zA-Z0-9+.\-]*://[^\s,)\]}"']+'''),
          (m) {
            final raw = m.group(0)!;
            final rest = raw.substring(raw.indexOf('://') + 3);
            final end = rest.indexOf(RegExp(r'[/?#]'));
            final host = end >= 0 ? rest.substring(0, end) : rest;
            return host.isEmpty ? '<url>' : host;
          },
        );
  }

  /// 截断 URL 仅保留 host，严禁将包含签名的完整 URL 打印进日志
  static String hostOf(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.host.isNotEmpty ? uri.host : url;
    } catch (_) {
      return url;
    }
  }

  /// 提取用于测速简报的短节点名（如 upos-sz-mirrorcosov -> cosov）
  static String shortNodeName(String url) {
    try {
      final host = Uri.parse(url).host;
      final match = RegExp(r'mirror([a-zA-Z0-9_-]+)').firstMatch(host);
      if (match != null) return match.group(1)!;
      final parts = host.split('.');
      return parts.isNotEmpty ? parts.first : host;
    } catch (_) {
      return url;
    }
  }

  /// 普通调试日志输出（经过 redact 脱敏，进环形缓冲并输出到控制台；发布版同样输出，便于真机 logcat 诊断）
  static void log(String message) {
    final safe = redact(message);
    _append(safe);
    {
      debugPrint(safe);
    }
  }

  /// 限流日志输出：同 key 每条日志最多 1 次/秒（经过 redact 脱敏，进环形缓冲并输出到控制台；发布版同样输出，便于真机 logcat 诊断）
  static void rateLimitedLog(
    String key,
    String message, {
    int minIntervalMs = 1000,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _lastLogTimeMs[key] ?? 0;
    if (now - last >= minIntervalMs) {
      if (_lastLogTimeMs.length >= maxRateLimitKeys &&
          !_lastLogTimeMs.containsKey(key)) {
        _lastLogTimeMs.clear();
      }
      _lastLogTimeMs[key] = now;
      final safe = redact(message);
      _append(safe);
      {
        debugPrint(safe);
      }
    }
  }
}

