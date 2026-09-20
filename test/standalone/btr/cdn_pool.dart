import 'dart:math';

import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;

import 'cdn_type.dart';

import 'range_core.dart';

/// 记录单次下载节点的健康状态
class CdnNodeHealth {
  int failures = 0;
  int blockedUntil = 0;
  int lastSuccessAt = 0;
  double bps = 0.0;

  bool isBlocked(int now) => blockedUntil > now;
}

/// 取不到视频码率参数(bw)时的保守兜底码率（字节/秒）：按典型 1080P60（真实码率约 0.77 MB/s，
/// 门限约 0.92 MB/s）对齐，取 1.0 MB/s。
/// 修正码率单位后，原 3.0 MB/s（门限 3.6 MB/s）过高，会导致能流畅播放 1080P 的正常节点被误判解绑。
const double kUnknownBitrateFallbackBps = 1.0 * 1024 * 1024;

/// 粘性节点解绑速度门限倍数：实测速度低于「码率 × 该倍数」即解绑
const double kStickySpeedMargin = 1.2;

/// 负责记录并封禁坏节点（对齐官方 cdn-resolver.js:125-146 node / address / pair 三级封禁）
class CdnBanList {
  final int strikeLimit;
  final Map<String, int> _strikes = {};
  final Set<String> _banned = {};

  final Map<String, int> _addressStrikes = {};
  final Set<String> _addressBanned = {};

  final Map<String, int> _pairStrikes = {};
  final Set<String> _pairBanned = {};

  CdnBanList({this.strikeLimit = 2});

  static String hostOf(String url) {
    try {
      return Uri.parse(url).host.toLowerCase();
    } catch (_) {
      return '';
    }
  }

  static String addressOf(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.path.toLowerCase();
    } catch (_) {
      return '';
    }
  }

  static String pairOf(String url) {
    final h = hostOf(url);
    final a = addressOf(url);
    if (h.isEmpty || a.isEmpty) return '';
    return '$h|$a';
  }

  /// 记录一次传输结果。若传输了 >0 字节，或为 Range 不支持降级，则不算作死节点
  bool record(String url, int receivedBytes, Object? error, {bool isAbort = false}) {
    if (isAbort || error is RangeNotSupportedException || receivedBytes > 0) return false;

    final host = hostOf(url);
    final address = addressOf(url);
    final pair = pairOf(url);

    // 官方规范：某个下载地址一直被服务器拒绝（如 403 / 404 / 410），只停用这个地址与 pair，不连累节点 strike
    if (error is UpstreamHttpException &&
        (error.statusCode == 403 ||
            error.statusCode == 404 ||
            error.statusCode == 410)) {
      if (address.isNotEmpty && !_addressBanned.contains(address)) {
        final c = (_addressStrikes[address] ?? 0) + 1;
        _addressStrikes[address] = c;
        if (c >= strikeLimit) _addressBanned.add(address);
      }
      if (pair.isNotEmpty && !_pairBanned.contains(pair)) {
        final c = (_pairStrikes[pair] ?? 0) + 1;
        _pairStrikes[pair] = c;
        if (c >= strikeLimit) _pairBanned.add(pair);
      }
      return false;
    }

    if (address.isNotEmpty && !_addressBanned.contains(address)) {
      final c = (_addressStrikes[address] ?? 0) + 1;
      _addressStrikes[address] = c;
      if (c >= strikeLimit) _addressBanned.add(address);
    }
    if (pair.isNotEmpty && !_pairBanned.contains(pair)) {
      final c = (_pairStrikes[pair] ?? 0) + 1;
      _pairStrikes[pair] = c;
      if (c >= strikeLimit) _pairBanned.add(pair);
    }

    if (host.isEmpty || _banned.contains(host)) return false;

    final count = (_strikes[host] ?? 0) + 1;
    _strikes[host] = count;
    if (count >= strikeLimit) {
      _banned.add(host);
      return true;
    }
    return false;
  }

  bool allows(String url) {
    final host = hostOf(url);
    if (host.isNotEmpty && _banned.contains(host)) return false;
    final address = addressOf(url);
    if (address.isNotEmpty && _addressBanned.contains(address)) return false;
    final pair = pairOf(url);
    if (pair.isNotEmpty && _pairBanned.contains(pair)) return false;
    return true;
  }

  List<String> get bannedHosts => _banned.toList();
  List<String> get bannedAddresses => _addressBanned.toList();
  List<String> get bannedPairs => _pairBanned.toList();

  void reset() {
    _strikes.clear();
    _banned.clear();
    _addressStrikes.clear();
    _addressBanned.clear();
    _pairStrikes.clear();
    _pairBanned.clear();
  }
}

/// CDN 节点分组类型（对齐官方 cdn-resolver.js 的 mainland 与 overseas 模式）
enum CdnGroup {
  mainland,
  overseas,
}

/// CDN 节点池与调度器（对应 BTR 的 cdn-resolver.js）
class CdnPool {
  /// 官方大陆节点清单（8 个，来自 MrTangLuyao/Bilibili-thread-ripper cdn-resolver.js）
  static const List<String> mainlandHosts = [
    'upos-sz-mirrorali.bilivideo.com',
    'upos-sz-mirrorhw.bilivideo.com',
    'upos-sz-mirrorbos.bilivideo.com',
    'upos-sz-mirror08c.bilivideo.com',
    'upos-sz-mirrorbd.bilivideo.com',
    'upos-sz-mirror14b.bilivideo.com',
    'upos-sz-estgoss.bilivideo.com',
    'upos-sz-mirrorcos.bilivideo.com',
  ];

  /// 官方海外节点清单（4 个，来自 MrTangLuyao/Bilibili-thread-ripper cdn-resolver.js）
  static const List<String> overseasHosts = [
    'upos-sz-mirrorcosov.bilivideo.com',
    'upos-sz-mirroraliov.bilivideo.com',
    'cn-hk-eq-01-01.bilivideo.com',
    'cn-hk-eq-01-03.bilivideo.com',
  ];

  final List<String> originalUrls;
  final CdnBanList banList;

  /// 用户在设置/快捷面板里手动指定的节点分组（null = 按实测自动选组）。
  /// 对应官方插件的「CDN 模式」（大陆 / 海外）。手动指定时不再自动选组。
  final CdnGroup? preferredGroup;

  final Map<String, CdnNodeHealth> _health = {};
  final Set<String> _deadUrls = {};
  final Random _random = Random();
  int _rangeCursor = 0;
  int _mediaRangeCount = 0;

  CdnGroup _activeGroup = CdnGroup.mainland;
  CdnGroup get activeGroup => _activeGroup;

  void selectGroup(CdnGroup group) {
    _activeGroup = group;
  }

  late final List<String> _mainlandCandidateUrls;
  late final List<String> _overseasCandidateUrls;
  late final List<String> _anchorCandidateUrls;
  late final List<String> _allFallbackUrls;

  /// 本次播放自适应决策得出的最优并发数（同一视频生命周期内保持）
  int? adaptiveConcurrency;

  /// 是否已切入单连接顺序透传模式（实测多连接无收益时开启）
  bool isSingleConnectionMode = false;

  /// 记录基准单连接实测速度（字节/秒）
  double lastSingleConnectionSpeedBps = 0.0;

  /// 粘性单连接偏好过期时间（毫秒时间戳，TTL 120 秒）
  int _stickySingleConnectionUntilMs = 0;
  static const int kStickySingleConnectionTtlMs = 120 * 1000;

  /// 连续未达标区间计数（连续 3 个区间满足对比式解粘条件则解粘）
  int _consecutiveSubstandardIntervals = 0;

  /// 本视频切单连接的次数统计
  int singleConnectionSwitchCount = 0;

  /// 本视频粘性单连接解除（切回多连接）的次数统计
  int stickyReleaseCount = 0;

  /// 本视频模式切换（切单连接/解粘切多连接）总次数统计
  int modeSwitchCount = 0;

  /// 切入单连接时的多连接聚合吞吐（字节/秒），用于后续对比式解粘判据
  double multiBpsAtSwitch = 0.0;

  /// 最近一次切入单连接时的多连接聚合吞吐（解粘后保留用于埋点日志输出）
  double lastMultiBpsAtSwitch = 0.0;

  /// 模式切换时间戳历史（用于限制 1 分钟最多 2 次切换）
  final List<int> _modeSwitchTimestamps = [];

  /// 模式切换最小驻留时间（毫秒，20 秒）
  static const int kMinModeDwellMs = 20 * 1000;

  /// 同一视频每分钟最多模式切换次数（2 次）
  static const int kMaxModeSwitchesPerMinute = 2;

  /// 检查并记录一次模式切换（任务 C）。
  /// 1. 每次模式切换（切入单连接 / 解粘切回多连接）后，最少驻留 20 秒才允许再次切换；
  /// 2. 同一视频每分钟最多 2 次模式切换；超限则保持当前模式并记限速日志：
  ///    `[BTR] 模式切换受限（本分钟已达上限），保持当前模式=X`。
  bool tryRecordModeSwitch(String currentMode) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _modeSwitchTimestamps.removeWhere((t) => now - t > 60000);

    // 1. 每次模式切换后最少驻留 20 秒
    if (_modeSwitchTimestamps.isNotEmpty) {
      final lastSwitch = _modeSwitchTimestamps.last;
      final elapsed = now - lastSwitch;
      if (elapsed < kMinModeDwellMs) {
        BtrLog.rateLimitedLog(
          'mode_switch_dwell_limit',
          '[BTR] 模式切换受限（驻留未满 20 秒），保持当前模式=$currentMode',
        );
        return false;
      }
    }

    // 2. 每分钟最多 2 次模式切换
    if (_modeSwitchTimestamps.length >= kMaxModeSwitchesPerMinute) {
      BtrLog.rateLimitedLog(
        'mode_switch_rate_limit',
        '[BTR] 模式切换受限（本分钟已达上限），保持当前模式=$currentMode',
      );
      return false;
    }

    _modeSwitchTimestamps.add(now);
    modeSwitchCount++;
    return true;
  }

  /// 是否命中粘性单连接偏好（未过期且处于粘性状态）
  bool get hasStickySingleConnection {
    if (_stickySingleConnectionUntilMs <= 0) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now > _stickySingleConnectionUntilMs) {
      clearStickySingleConnection();
      return false;
    }
    return true;
  }

  /// 启用粘性单连接偏好（TTL 120 秒，记录切入时多连接聚合吞吐）
  void enableStickySingleConnection({double multiBpsAtSwitch = 0.0}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _stickySingleConnectionUntilMs = now + kStickySingleConnectionTtlMs;
    _consecutiveSubstandardIntervals = 0;
    isSingleConnectionMode = true;
    adaptiveConcurrency = 1;
    this.multiBpsAtSwitch = multiBpsAtSwitch;
    lastMultiBpsAtSwitch = multiBpsAtSwitch;
  }

  /// 检查单连接区间实测吞吐，连续 3 个区间满足对比式解粘条件时解粘（任务 B & C）：
  /// 1. currentSingleBps < targetBps * 0.8
  /// 2. multiBpsAtSwitch > currentSingleBps * 1.1
  /// 3. 若 multiBpsAtSwitch 缺失（<= 0），不解粘
  /// 4. 模式切换受最小驻留 20s 与每分钟最多 2 次硬约束
  /// 返回 true 表示成功解粘切回多连接
  bool recordSingleConnectionIntervalThroughput(
    double currentBps,
    double targetBps,
  ) {
    if (!hasStickySingleConnection) return false;

    // 任务 B.3：若 multiBpsAtSwitch 缺失（0），不解粘（宁可保持单连接，也不要无证据地来回切）
    if (multiBpsAtSwitch <= 0) {
      _consecutiveSubstandardIntervals = 0;
      return false;
    }

    final threshold = targetBps * RangeCore.switchBackMargin;
    final isSubstandard = currentBps < threshold;
    final isMultiBetter =
        multiBpsAtSwitch > currentBps * RangeCore.switchBackMultiBetterFactor;

    if (isSubstandard && isMultiBetter) {
      _consecutiveSubstandardIntervals++;
      if (_consecutiveSubstandardIntervals >= 3) {
        // 任务 C：模式切换频率与驻留时间硬约束
        if (!tryRecordModeSwitch('单连接')) {
          return false;
        }
        stickyReleaseCount++;
        clearStickySingleConnection();
        return true;
      }
    } else {
      _consecutiveSubstandardIntervals = 0;
      if (!isSubstandard) {
        // 单连接达标时刷新 TTL
        final now = DateTime.now().millisecondsSinceEpoch;
        _stickySingleConnectionUntilMs = now + kStickySingleConnectionTtlMs;
      }
    }
    return false;
  }

  /// 清除粘性单连接偏好
  void clearStickySingleConnection() {
    if (multiBpsAtSwitch > 0) {
      lastMultiBpsAtSwitch = multiBpsAtSwitch;
    }
    _stickySingleConnectionUntilMs = 0;
    _consecutiveSubstandardIntervals = 0;
    isSingleConnectionMode = false;
    adaptiveConcurrency = null;
    slowPieceThreshold = RangeCore.slowPieceThresholdDefault;
    multiBpsAtSwitch = 0.0;
  }

  /// 是否已判定加速不可行并降级为直连透传（对齐官方 page-hook.js:1074-1081 / 140-158）
  bool isDirectPassthrough = false;

  /// 重接管尝试次数（最多 3 次，4s / 8s / 16s，2 分钟窗口重置）
  int retakeoverAttempts = 0;

  /// 上次降级时间戳（毫秒）
  int lastFallbackTimeMs = 0;

  /// 下一次允许重接管的时间戳（毫秒）
  int nextRetakeoverTimeMs = 0;

  /// 降级窗口开始时间戳（用于 2 分钟窗口重置）
  int fallbackWindowStartMs = 0;

  /// 记录一次降级为直连透传
  void markDirectFallback(String reason) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (fallbackWindowStartMs == 0 ||
        now - fallbackWindowStartMs > RangeCore.retakeoverWindowMs) {
      fallbackWindowStartMs = now;
      retakeoverAttempts = 0;
    }
    isDirectPassthrough = true;
    lastFallbackTimeMs = now;
    final attempt = retakeoverAttempts + 1;
    // 首次重接管延迟 = 宽限期(3500ms，对齐官方 page-hook.js:1074-1081)
    //                + 退避(4000/8000/16000ms，对齐官方 page-hook.js:140-158)
    // ⚠️ 宽限期只能体现在时间戳上，绝不能在请求路径里 await 阻塞（那会变成真卡顿）。
    final delayMs = RangeCore.fallbackGraceMs +
        RangeCore.retakeoverBaseDelayMs * (1 << min(retakeoverAttempts, 2));
    nextRetakeoverTimeMs = now + delayMs;
    BtrLog.rateLimitedLog(
      'direct_fallback',
      '[BTR] 降级直连: 原因=$reason 重试=第${min(attempt, RangeCore.retakeoverMaxAttempts)}次/${RangeCore.retakeoverMaxAttempts}',
    );
  }

  /// 检查当前是否允许尝试重接管（未超上限且退避时间已到）
  bool checkRetakeoverEligible() {
    if (!isDirectPassthrough) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (fallbackWindowStartMs > 0 &&
        now - fallbackWindowStartMs > RangeCore.retakeoverWindowMs) {
      fallbackWindowStartMs = 0;
      retakeoverAttempts = 0;
    }
    if (retakeoverAttempts >= RangeCore.retakeoverMaxAttempts) {
      return false;
    }
    if (now >= nextRetakeoverTimeMs) {
      retakeoverAttempts++;
      return true;
    }
    return false;
  }

  /// 标记重接管成功，恢复加速状态
  void onRetakeoverSuccess(String host) {
    isDirectPassthrough = false;
    retakeoverAttempts = 0;
    fallbackWindowStartMs = 0;
    BtrLog.log('[BTR] 重接管成功');
  }

  /// 跨节点文件总长度一致性校验（对齐官方 idm-downloader.js:445-446）
  int? verifiedTotalLength;
  String? verifiedTotalHost;

  /// 校验从 [host] 收到的文件总长度 [total] 是否与已有记录一致。
  /// 若不一致返回 false，并输出告警埋点；首次遇到或一致返回 true。
  bool checkTotalLengthConsistency(int total, String host) {
    if (verifiedTotalLength == null) {
      verifiedTotalLength = total;
      verifiedTotalHost = host;
      return true;
    }
    if (verifiedTotalLength == total) {
      return true;
    }
    BtrLog.rateLimitedLog(
      'total_mismatch_${verifiedTotalLength}_$total',
      '[BTR] 不同节点返回的文件总长度不一致: ${verifiedTotalHost ?? "known"}=$verifiedTotalLength $host=$total',
    );
    return false;
  }

  /// 锁定的最快粘性节点 URL
  String? _stickyUrl;
  String? get stickyUrl => isAnchorEligible() ? anchorUrl : _stickyUrl;

  /// BTR CDN 竞速提示信息
  String? _racerHintHost;
  String? _racerHintUrl;

  bool get hasRacerHint => _racerHintHost != null && _racerHintHost!.isNotEmpty;

  void applyRacerHint(String host, double bytesPerSec) {
    _racerHintHost = host;
    final lowerHost = host.toLowerCase();

    String? matchedUrl;
    for (final u in _allFallbackUrls) {
      if (CdnBanList.hostOf(u) == lowerHost) {
        matchedUrl = u;
        break;
      }
    }
    if (matchedUrl == null) {
      for (final u in originalUrls) {
        if (CdnBanList.hostOf(u) == lowerHost) {
          matchedUrl = u;
          break;
        }
      }
    }
    if (matchedUrl == null && originalUrls.isNotEmpty) {
      try {
        final donorUri = Uri.parse(originalUrls.first);
        final defaultPort = donorUri.scheme == 'http' ? 80 : 443;
        matchedUrl = donorUri.replace(host: host, port: defaultPort).toString();
      } catch (_) {}
    }

    if (matchedUrl != null) {
      _racerHintUrl = matchedUrl;
      final h = _health.putIfAbsent(matchedUrl, CdnNodeHealth.new);
      if (h.bps < bytesPerSec) {
        h.bps = bytesPerSec;
      }
      setStickyUrl(matchedUrl);
    }
  }

  void clearRacerHint() {
    _racerHintHost = null;
    if (_stickyUrl == _racerHintUrl) {
      _stickyUrl = null;
    }
    _racerHintUrl = null;
  }

  /// 是否已完成启动测速
  bool hasSpeedTested = false;

  /// 当前视频码率（字节/秒），用于判定粘性节点是否跌破 1.2 倍与自适应慢块阈值
  double? videoBitrateBytesPerSec;

  /// 当前视频自适应慢块判定阈值（初始为无并发信息时的固定 1200ms 回退，在自适应并发决策点动态更新）
  Duration slowPieceThreshold = RangeCore.slowPieceThresholdDefault;

  /// 在自适应评估决策点根据并发数与目标带宽动态更新慢块阈值（防震荡）
  void updateSlowPieceThreshold({
    required int concurrency,
    double? targetBps,
    int pieceBytes = RangeCore.defaultMaxPieceBytes,
  }) {
    slowPieceThreshold = RangeCore.adaptiveSlowPieceThreshold(
      videoBitrateBytesPerSec,
      targetBps: targetBps,
      concurrency: concurrency,
      pieceBytes: pieceBytes,
    );
  }

  /// 原始 URL 的首个地址作为锚点节点（用户在 App 中当前选定的 CDN）
  String? get anchorUrl => originalUrls.isNotEmpty ? originalUrls.first : null;

  /// 锚点节点的 Host
  String? get anchorHost {
    final anchor = anchorUrl;
    return anchor != null ? CdnBanList.hostOf(anchor) : null;
  }

  /// 起播测速时大陆组候选（最多 4 个）
  List<String> get mainlandProbeCandidates {
    final list = <String>[
      if (anchorUrl != null && !overseasHosts.contains(anchorHost)) anchorUrl!,
      ..._mainlandCandidateUrls,
    ];
    final seen = <String>{};
    return list.where(seen.add).take(4).toList();
  }

  /// 起播测速时海外组候选（最多 4 个）
  List<String> get overseasProbeCandidates {
    final list = <String>[
      if (anchorUrl != null && overseasHosts.contains(anchorHost)) anchorUrl!,
      ..._overseasCandidateUrls,
    ];
    final seen = <String>{};
    return list.where(seen.add).take(4).toList();
  }

  CdnPool({
    required this.originalUrls,
    CdnBanList? banList,
    this.videoBitrateBytesPerSec,
    this.preferredGroup,
  }) : banList = banList ?? CdnBanList() {
    videoBitrateBytesPerSec ??= _extractBitrateBytesPerSec(originalUrls.isNotEmpty ? originalUrls.first : '');
    slowPieceThreshold = RangeCore.adaptiveSlowPieceThreshold(
      videoBitrateBytesPerSec,
      concurrency: null,
    );
    _logBitrateParsing();
    _initCandidatePools();
  }

  /// 打印码率解析埋点日志（仅打印 host，严禁打印含签名的完整 URL）
  void _logBitrateParsing() {
    if (!kDebugMode) return;
    final host = anchorHost;
    final hostPrefix = (host != null && host.isNotEmpty) ? 'host=$host, ' : '';
    final rate = videoBitrateBytesPerSec;
    if (rate != null && rate > 0) {
      final bw = (rate * 8.0).round();
      final mbps = rate / 1000000.0;
      final targetMbps =
          RangeCore.requiredThroughputBytesPerSec(rate) / 1000000.0;
      debugPrint(
        '[BTR] 码率解析: ${hostPrefix}bw=$bw bps → ${mbps.toStringAsFixed(2)} MB/s'
        '（单连接够用门限 ${targetMbps.toStringAsFixed(2)} MB/s）',
      );
    } else {
      const fallbackMbps = RangeCore.singleAdequateFallbackBps / 1000000.0;
      debugPrint(
        '[BTR] 码率解析: $hostPrefix未获取到码率(bw缺失) → '
        '兜底单连接够用门限 ${fallbackMbps.toStringAsFixed(2)} MB/s',
      );
    }
  }

  /// 从上游播放 URL 中提取视频/音频码率（字节/秒）。
  ///
  /// 依据：bilibili 的 bw 参数单位为 bit/s（实测 bw=155643 ↔ yt-dlp 报 156 kbps），下游一律按字节/秒比较，故 ÷8。
  static double? _extractBitrateBytesPerSec(String url) =>
      RangeCore.parseBitrateBytesPerSec(url);

  final Map<String, int> _semiDeadStrikes = {};

  /// 将具体地址加入本视频不可用集合（仅停用该失败地址，不连累同节点的其它合成/备用地址）
  void markUnusable(String url) {
    if (url.isNotEmpty) {
      _deadUrls.add(url);
    }
  }

  /// 记录一次半死节点请求（已收到部分字节但耗时 > 3×期望耗时且 > 4000ms）
  /// 达到 strikeLimit 后通过 markUnusable(url) 停用该具体 URL，不影响整个节点组
  int recordSemiDead(String url) {
    if (url.isEmpty) return 0;
    final strikes = (_semiDeadStrikes[url] ?? 0) + 1;
    _semiDeadStrikes[url] = strikes;
    if (strikes >= banList.strikeLimit) {
      markUnusable(url);
    }
    return strikes;
  }

  /// 地址是否不可用（在不可用地址集合中，或所在 host 已被 BanList 封禁）
  bool isDead(String url) {
    return _deadUrls.contains(url) || !banList.allows(url);
  }

  /// 地址是否可用（未在不可用地址集合中，且所在 host 未被 BanList 封禁）
  bool isUsable(String url) {
    if (_deadUrls.contains(url)) return false;
    return banList.allows(url);
  }

  /// 锚点节点是否可用且实测速度达标（>= 码率 * 1.2）
  bool isAnchorEligible() {
    final anchor = anchorUrl;
    if (anchor == null || anchor.isEmpty) return false;
    if (!isUsable(anchor)) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_health[anchor]?.isBlocked(now) ?? false) return false;
    final minSpeed =
        (videoBitrateBytesPerSec ?? kUnknownBitrateFallbackBps) * kStickySpeedMargin;
    final speed = _health[anchor]?.bps ?? 0.0;
    return speed >= minSpeed;
  }

  /// 判定粘性节点是否依然可用
  bool isStickyValid(String? url) {
    if (url == null || url.isEmpty) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    // ① 该节点不可在不可用集合或 BanList 中
    if (!isUsable(url)) return false;
    // ③ 该节点被临时阻断
    if (_health[url]?.isBlocked(now) ?? false) return false;
    // ② 该节点实测速度掉到"视频码率的 1.2 倍"以下
    //    码率参数(bw)缺失时用保守兜底值：宁可多切节点，也不要锁死在慢节点上。
    final minSpeed =
        (videoBitrateBytesPerSec ?? kUnknownBitrateFallbackBps) * kStickySpeedMargin;
    final speed = _health[url]?.bps ?? 0.0;
    if (speed > 0 && speed < minSpeed) return false;
    return true;
  }

  /// 设置本次视频的粘性节点
  void setStickyUrl(String url) {
    if (isStickyValid(url)) {
      _stickyUrl = url;
    }
  }

  /// 获取指定节点的历史平滑速度
  double? getSpeed(String url) => _health[url]?.bps;

  static bool isAkamaiHost(String host) {
    final lower = host.toLowerCase();
    return lower == 'akamaized.net' || lower.endsWith('.akamaized.net');
  }

  static bool isAkamaiUrl(String url) {
    try {
      return isAkamaiHost(Uri.parse(url).host);
    } catch (_) {
      return false;
    }
  }

  /// 初始化候选池：按大陆组、海外组、锚点候选分别构建，并生成全量 19 节点最低兜底池
  void _initCandidatePools() {
    final seenMainland = <String>{};
    final mainlandList = <String>[];

    final seenOverseas = <String>{};
    final overseasList = <String>[];

    final seenAnchor = <String>{};
    final anchorList = <String>[];

    void addUrl(String? u) {
      if (u == null || u.isEmpty) return;
      if (!RangeCore.isBilibiliMediaUrl(u)) return;
      final host = CdnBanList.hostOf(u);
      if (mainlandHosts.contains(host)) {
        if (seenMainland.add(u)) mainlandList.add(u);
      } else if (overseasHosts.contains(host)) {
        if (seenOverseas.add(u)) overseasList.add(u);
      } else {
        if (seenAnchor.add(u)) anchorList.add(u);
      }
    }

    // 1. 分类原始 URL：若属于某一组则归入该组，否则单独作为锚点候选
    for (final url in originalUrls) {
      addUrl(url);
    }

    // 2. 寻找非 Akamai 的 donor 模版合成两组候选节点
    final donor = originalUrls.firstWhere(
      (u) => !isAkamaiUrl(u) && RangeCore.isBilibiliMediaUrl(u),
      orElse: () => '',
    );

    if (donor.isNotEmpty) {
      try {
        final donorUri = Uri.parse(donor);
        final defaultPort = donorUri.scheme == 'http' ? 80 : 443;
        for (final host in mainlandHosts) {
          final synthetic =
              donorUri.replace(host: host, port: defaultPort).toString();
          if (RangeCore.isBilibiliMediaUrl(synthetic) && seenMainland.add(synthetic)) {
            mainlandList.add(synthetic);
          }
        }
        for (final host in overseasHosts) {
          final synthetic =
              donorUri.replace(host: host, port: defaultPort).toString();
          if (RangeCore.isBilibiliMediaUrl(synthetic) && seenOverseas.add(synthetic)) {
            overseasList.add(synthetic);
          }
        }
      } catch (_) {}
    }

    _mainlandCandidateUrls = mainlandList.isNotEmpty ? mainlandList : originalUrls;
    _overseasCandidateUrls = overseasList.isNotEmpty ? overseasList : originalUrls;
    _anchorCandidateUrls = anchorList;

    // 3. 构建全量 19 个节点（最低兜底池，保证任何情况下候选项不为空）
    _allFallbackUrls = _buildAllFallbackUrls(donor);
  }

  /// 构造包含全部 19 个 CDNService 节点的最低兜底池
  List<String> _buildAllFallbackUrls(String donor) {
    final result = <String>[];
    final seen = <String>{};

    void addUrl(String? u) {
      if (u == null || u.isEmpty) return;
      if (RangeCore.isBilibiliMediaUrl(u) && seen.add(u)) {
        result.add(u);
      }
    }

    for (final url in originalUrls) {
      addUrl(url);
    }

    if (donor.isNotEmpty) {
      try {
        final donorUri = Uri.parse(donor);
        final defaultPort = donorUri.scheme == 'http' ? 80 : 443;
        for (final cdn in CDNService.values) {
          final targetHost = cdn.host;
          if (targetHost != null &&
              targetHost.isNotEmpty &&
              !isAkamaiHost(targetHost)) {
            final synthetic = donorUri
                .replace(host: targetHost, port: defaultPort)
                .toString();
            addUrl(synthetic);
          }
        }
      } catch (_) {}
    }

    return result.isEmpty ? originalUrls : result;
  }

  List<String> _getMainPoolUrls() {
    final base = _activeGroup == CdnGroup.mainland
        ? _mainlandCandidateUrls
        : _overseasCandidateUrls;
    final hint = _racerHintUrl;
    final result = <String>[
      ..._anchorCandidateUrls,
      ?hint,
      ...base,
    ];
    final seen = <String>{};
    final deduped = result.where(seen.add).toList();
    return deduped.isEmpty ? originalUrls : deduped;
  }

  List<String> _getBackupPoolUrls() {
    final base = _activeGroup == CdnGroup.mainland
        ? _overseasCandidateUrls
        : _mainlandCandidateUrls;
    final hint = _racerHintUrl;
    final result = <String>[
      ..._anchorCandidateUrls,
      ?hint,
      ...base,
    ];
    final seen = <String>{};
    final deduped = result.where(seen.add).toList();
    return deduped.isEmpty ? originalUrls : deduped;
  }

  List<String> _withAnchor(List<String> list, {bool availableOnly = false}) {
    final anchor = anchorUrl;
    if (anchor == null || !isUsable(anchor) || list.contains(anchor)) {
      return list;
    }
    if (availableOnly) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (_health[anchor]?.isBlocked(now) ?? false) {
        return list;
      }
    }
    return [anchor, ...list];
  }

  /// 是否包含海外 CDN 节点
  bool get hasOverseasCandidates => _overseasCandidateUrls.isNotEmpty;

  /// 预热轮数对齐官方（cdn-resolver.js:153）：大陆组 1 轮、海外组 4 轮
  int get warmupLimit => _activeGroup == CdnGroup.overseas ? 4 : 1;

  /// 获取当前候选 URL 列表（严格遵循分组与兜底顺序）：
  /// 1. 主候选池：优先未阻断可用节点 -> 可用但临时阻断节点（不盲目切死节点）
  /// 2. 兜底池：主池全不可用时启用 -> 优先未阻断 -> 临时阻断
  /// 3. 全量 19 节点：两组均不可用时回退 -> 优先未阻断 -> 临时阻断
  /// 4. 最低回退：全量 19 个节点（官方规则：全停用时仍继续尝试，确保绝不返回空候选）
  List<String> urls() {
    final now = DateTime.now().millisecondsSinceEpoch;

    // 1. 主候选池
    final mainCandidates = _getMainPoolUrls();
    final mainUsable = mainCandidates.where(isUsable).toList();
    if (mainUsable.isNotEmpty) {
      final mainAvailable =
          mainUsable.where((u) => !(_health[u]?.isBlocked(now) ?? false)).toList();
      if (mainAvailable.isNotEmpty) return _withAnchor(mainAvailable, availableOnly: true);
      return _withAnchor(mainUsable);
    }

    // 2. 兜底池（仅在主池节点全部不可用/被停用时启用）
    final backupCandidates = _getBackupPoolUrls();
    final backupUsable = backupCandidates.where(isUsable).toList();
    if (backupUsable.isNotEmpty) {
      final backupAvailable =
          backupUsable.where((u) => !(_health[u]?.isBlocked(now) ?? false)).toList();
      if (backupAvailable.isNotEmpty) return _withAnchor(backupAvailable, availableOnly: true);
      return _withAnchor(backupUsable);
    }

    // 3. 全量 19 个节点回退
    final allUsable = _allFallbackUrls.where(isUsable).toList();
    if (allUsable.isNotEmpty) {
      final allAvailable =
          allUsable.where((u) => !(_health[u]?.isBlocked(now) ?? false)).toList();
      if (allAvailable.isNotEmpty) return _withAnchor(allAvailable, availableOnly: true);
      return _withAnchor(allUsable);
    }

    // 4. 最低回退（保证候选项绝不为空，不抛异常/死锁）
    return _allFallbackUrls.isNotEmpty ? _allFallbackUrls : originalUrls;
  }

  /// 从候选列表中按实测速度加权选择一个首选节点（快的多分块）
  String pickWeightedCandidate(List<String> candidates) {
    if (candidates.isEmpty) return '';
    if (candidates.length == 1) return candidates.first;

    final weights = candidates.map((u) {
      final bps = _health[u]?.bps ?? 0.0;
      return max(bps, RangeCore.minWeightedSelectionBps);
    }).toList();

    final totalWeight = weights.fold(0.0, (sum, w) => sum + w);
    if (totalWeight <= 0) return candidates.first;

    final randVal = _random.nextDouble() * totalWeight;
    var accum = 0.0;
    for (var i = 0; i < candidates.length; i++) {
      accum += weights[i];
      if (randVal <= accum) {
        return candidates[i];
      }
    }
    return candidates.last;
  }

  /// 为 pieceIndex 选择候选节点列表：
  /// 1. 锚点优先：若锚点未被拉黑且实测速度不低于码率 × 1.2，优先分派给锚点
  /// 2. 锚点降级时：从可用节点里按实测速度加权选择首选节点，快的多分块，其余按速度降序排列作为备选与重试候选
  List<String> ordered(int pieceIndex, {Set<String>? exclude}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final candidates = urls()
        .where((u) => isUsable(u) && (exclude == null || !exclude.contains(u)))
        .toList();
    if (candidates.isEmpty) return urls();

    // 1. 锚点优先：只要锚点没被拉黑、且实测速度不低于"码率 × 1.2"，就优先分派给它
    final anchor = anchorUrl;
    if (anchor != null && candidates.contains(anchor) && isAnchorEligible()) {
      final others = candidates.where((u) => u != anchor).toList()
        ..sort((a, b) => (_health[b]?.bps ?? 0.0).compareTo(_health[a]?.bps ?? 0.0));
      return [anchor, ...others];
    }

    final available =
        candidates.where((u) => !(_health[u]?.isBlocked(now) ?? false)).toList();
    final pool = available.isNotEmpty ? available : candidates;

    if (pool.length <= 1) return pool;

    // 2. 锚点不达标时，若有 racerHint，将 racerHint 节点排到最前
    final hint = _racerHintUrl;
    if (hint != null &&
        pool.contains(hint) &&
        isUsable(hint) &&
        !(_health[hint]?.isBlocked(now) ?? false)) {
      final others = pool.where((u) => u != hint).toList()
        ..sort((a, b) => (_health[b]?.bps ?? 0.0).compareTo(_health[a]?.bps ?? 0.0));
      return [hint, ...others];
    }

    // 3. 按实测速度加权分配首选节点，其余候选按速度降序作为备选与重试候选
    final selected = pickWeightedCandidate(pool);
    final others = pool.where((u) => u != selected).toList()
      ..sort((a, b) => (_health[b]?.bps ?? 0.0).compareTo(_health[a]?.bps ?? 0.0));
    return [selected, ...others];
  }

  /// 获取适合批量 Range 请求的高优候选节点（按测速和成功记录排序）
  List<String> rangeCandidates() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final pool = urls().where((u) => isUsable(u) && !(_health[u]?.isBlocked(now) ?? false)).toList()
      ..sort((a, b) {
        final ha = _health[a];
        final hb = _health[b];
        final aSuccess = (ha?.lastSuccessAt ?? 0) > 0 ? 1 : 0;
        final bSuccess = (hb?.lastSuccessAt ?? 0) > 0 ? 1 : 0;
        if (bSuccess != aSuccess) return bSuccess - aSuccess;
        return (hb?.bps ?? 0.0).compareTo(ha?.bps ?? 0.0);
      });

    if (pool.isEmpty) return urls();

    // 锚点优先：若锚点可用且速度达标，优先固定用它
    final anchor = anchorUrl;
    if (anchor != null && pool.contains(anchor) && isAnchorEligible()) {
      final others = pool.where((u) => u != anchor).toList();
      return [anchor, ...others];
    }

    // 节点粘性：若已锁定最快节点且仍有效，优先固定用它
    if (_stickyUrl != null) {
      if (isStickyValid(_stickyUrl)) {
        final sticky = _stickyUrl!;
        final speed = _health[sticky]?.bps ?? 0.0;
        final others = pool.where((u) => u != sticky).toList();
        final skippedCount = others.length;
        BtrLog.rateLimitedLog(
          'sticky_node',
          '[BTR] 节点粘性 锁定 ${BtrLog.hostOf(sticky)}（实测 ${(speed / (1024 * 1024)).toStringAsFixed(2)} MB/s），本轮跳过 $skippedCount 个候选',
        );
        return [sticky, ...others];
      } else {
        _stickyUrl = null;
      }
    }

    final firstRange = _mediaRangeCount == 0;
    final width = min(firstRange ? pool.length : 3, pool.length);
    List<String> selected;

    if (_mediaRangeCount < warmupLimit) {
      selected = pool.sublist(0, width);
      _rangeCursor = width % pool.length;
    } else {
      final offset = _rangeCursor % pool.length;
      final rotated = pool.sublist(offset)..addAll(pool.sublist(0, offset));
      selected = rotated.sublist(0, width);
      _rangeCursor = (_rangeCursor + width) % pool.length;
    }
    _mediaRangeCount++;
    return selected;
  }

  /// 救援候选节点（用于 hedge 备用路）
  List<String> rescueCandidates() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final pool = urls().where((u) => isUsable(u) && !(_health[u]?.isBlocked(now) ?? false)).toList()
      ..sort((a, b) {
        final ha = _health[a];
        final hb = _health[b];
        final aSuccess = (ha?.lastSuccessAt ?? 0) > 0 ? 1 : 0;
        final bSuccess = (hb?.lastSuccessAt ?? 0) > 0 ? 1 : 0;
        if (bSuccess != aSuccess) return bSuccess - aSuccess;
        return (hb?.bps ?? 0.0).compareTo(ha?.bps ?? 0.0);
      });
    return pool.isNotEmpty ? pool : urls();
  }

  /// 记录节点请求成功与瞬时速度
  void success(String url, double bps) {
    final currentBps = _health[url]?.bps ?? 0.0;
    _health.putIfAbsent(url, CdnNodeHealth.new)
      ..failures = 0
      ..blockedUntil = 0
      ..lastSuccessAt = DateTime.now().millisecondsSinceEpoch
      ..bps = currentBps > 0 ? (currentBps * 0.65 + bps * 0.35) : bps;
  }

  /// 记录节点请求失败（若非主动取消且非 Range 不支持，按指数退避临时阻断，并累加 0 字节惩罚）
  void failure(String url, Object? error, {int receivedBytes = 0, bool isAbort = false}) {
    if (isAbort || error is RangeNotSupportedException) return;
    banList.record(url, receivedBytes, error, isAbort: false);

    final h = _health.putIfAbsent(url, CdnNodeHealth.new);
    h.failures++;
    final backoffSeconds = min(60, 3 * pow(2, min(h.failures, 4)).toInt());
    h.blockedUntil = DateTime.now().millisecondsSinceEpoch + backoffSeconds * 1000;
  }

  void reset() {
    _health.clear();
    banList.reset();
    _deadUrls.clear();
    _semiDeadStrikes.clear();
    clearRacerHint();
    _rangeCursor = 0;
    _mediaRangeCount = 0;
    adaptiveConcurrency = null;
    _stickyUrl = null;
    hasSpeedTested = false;
    _activeGroup = CdnGroup.mainland;
    isSingleConnectionMode = false;
    lastSingleConnectionSpeedBps = 0.0;
    clearStickySingleConnection();
    singleConnectionSwitchCount = 0;
    stickyReleaseCount = 0;
    modeSwitchCount = 0;
    _modeSwitchTimestamps.clear();
    multiBpsAtSwitch = 0.0;
    lastMultiBpsAtSwitch = 0.0;
    videoBitrateBytesPerSec = _extractBitrateBytesPerSec(originalUrls.isNotEmpty ? originalUrls.first : '');
    slowPieceThreshold = RangeCore.adaptiveSlowPieceThreshold(
      videoBitrateBytesPerSec,
      concurrency: null,
    );
    isDirectPassthrough = false;
    retakeoverAttempts = 0;
    lastFallbackTimeMs = 0;
    nextRetakeoverTimeMs = 0;
    fallbackWindowStartMs = 0;
    verifiedTotalLength = null;
    verifiedTotalHost = null;
  }
}
