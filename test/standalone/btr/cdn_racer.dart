import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'range_core.dart';

/// CDN 竞速测量结果
class CdnRaceResult {
  /// 选中的最优节点 host（只记 host，不记完整 URL）
  final String host;

  /// 实测吞吐（字节/秒）
  final double bytesPerSec;

  /// 测量时刻（毫秒时间戳）
  final int measuredAtMs;

  /// 参与竞速的候选数
  final int candidateCount;

  /// 节点分组 ('mainland' | 'overseas' | 'auto')
  final String group;

  /// 是否为下界估计值（未收满但收到可观样本，或小样本降级）
  final bool isEstimated;

  const CdnRaceResult({
    required this.host,
    required this.bytesPerSec,
    required this.measuredAtMs,
    required this.candidateCount,
    required this.group,
    this.isEstimated = false,
  });

  /// 用于竞速 hint 时的保守吞吐（下界估计取 0.6 倍折扣，收满实测取原值）
  double get hintBytesPerSec =>
      isEstimated ? bytesPerSec * 0.6 : bytesPerSec;

  @override
  String toString() =>
      'CdnRaceResult(host: $host, speed: ${(bytesPerSec / (1024 * 1024)).toStringAsFixed(2)} MB/s${isEstimated ? " (估算)" : ""}, group: $group)';
}

/// 单个候选节点的探测结果状态
class CdnCandidateProbeResult {
  final String host;
  final double bps;
  final int bytes;
  final bool isEstimated;
  final bool isUnmeasured;

  const CdnCandidateProbeResult({
    required this.host,
    required this.bps,
    required this.bytes,
    this.isEstimated = false,
    this.isUnmeasured = false,
  });

  const CdnCandidateProbeResult.unmeasured(this.host)
      : bps = 0.0,
        bytes = 0,
        isEstimated = false,
        isUnmeasured = true;

  bool get isSuccessful => !isUnmeasured && bps > 0;
}

/// 手动重新竞速结果状态
enum CdnRaceOutcome {
  ok,
  noSample,
  noWinner,
  failed,
}

/// 手动重新竞速结果包装
class CdnRaceReraceResult {
  final CdnRaceOutcome outcome;
  final CdnRaceResult? result;

  const CdnRaceReraceResult({
    required this.outcome,
    this.result,
  });

  const CdnRaceReraceResult.ok(CdnRaceResult res)
      : outcome = CdnRaceOutcome.ok,
        result = res;

  const CdnRaceReraceResult.noSample()
      : outcome = CdnRaceOutcome.noSample,
        result = null;

  const CdnRaceReraceResult.noWinner()
      : outcome = CdnRaceOutcome.noWinner,
        result = null;

  const CdnRaceReraceResult.failed()
      : outcome = CdnRaceOutcome.failed,
        result = null;

  @override
  String toString() => 'CdnRaceReraceResult(outcome: $outcome, result: $result)';
}

/// 纯 Dart 实现的 CDN 自动竞速器
///
/// 约束：不得 import lib/models/...、lib/utils/...、Pref。
/// 候选 host 列表由调用方传入。
class CdnRacer {
  /// 结果保质期（默认 5 分钟）
  final int ttlMs;

  /// 迟滞系数：新结果必须快 20% 以上才替换现役
  final double hysteresisFactor;

  /// 单次最多测几个候选（默认 6）
  final int maxCandidates;

  /// 每个候选探测拉取的字节数（默认 64KB）
  final int probeBytes;

  /// 整批竞速预算时长（默认 800ms）
  final int probeBudgetMs;

  /// 并行探测窗口大小（默认 2）
  final int maxParallel;

  /// 可注入的 HttpClient（未提供则内部自建并复用）
  final HttpClient? httpClient;

  /// 日志输出回调（默认输出到标准打印）
  void Function(String message) log;

  HttpClient? _internalHttpClient;

  CdnRaceResult? _cached;

  int _consecutiveFailures = 0;
  int _backoffUntilMs = 0;

  /// 连续未能测出/失败达到此门限触发退避（建议 N=2）
  static const int maxConsecutiveFailures = 2;

  /// 退避时长（建议 M=60s）
  static const Duration raceBackoffDuration = Duration(seconds: 60);

  /// 是否处于退避静默期
  bool get isBackoffActive =>
      DateTime.now().millisecondsSinceEpoch < _backoffUntilMs;

  int get consecutiveFailures => _consecutiveFailures;

  /// 期间有请求成功则重置退避状态
  void resetFailureBackoff() {
    _consecutiveFailures = 0;
    _backoffUntilMs = 0;
  }

  void _recordFailure() {
    _consecutiveFailures++;
    if (_consecutiveFailures >= maxConsecutiveFailures) {
      _backoffUntilMs = DateTime.now().millisecondsSinceEpoch +
          raceBackoffDuration.inMilliseconds;
      log('[BTR] 竞速退避: 连续 $_consecutiveFailures 次未能测出 → 暂停 ${raceBackoffDuration.inSeconds}s');
    }
  }

  /// 最近一次竞速整批下载的总字节数
  int lastTotalSampleBytes = 0;

  /// 官方大陆节点集合
  static const Set<String> mainlandHosts = {
    'upos-sz-mirrorali.bilivideo.com',
    'upos-sz-mirrorhw.bilivideo.com',
    'upos-sz-mirrorbos.bilivideo.com',
    'upos-sz-mirror08c.bilivideo.com',
    'upos-sz-mirrorbd.bilivideo.com',
    'upos-sz-mirror14b.bilivideo.com',
    'upos-sz-estgoss.bilivideo.com',
    'upos-sz-mirrorcos.bilivideo.com',
    'upos-sz-mirroralib.bilivideo.com',
    'upos-sz-mirroralio1.bilivideo.com',
    'upos-sz-mirrorcosb.bilivideo.com',
    'upos-sz-mirrorcoso1.bilivideo.com',
    'upos-sz-mirrorhwb.bilivideo.com',
    'upos-sz-mirrorhwo1.bilivideo.com',
    'upos-sz-mirror08h.bilivideo.com',
    'upos-sz-mirror08ct.bilivideo.com',
    'upos-tf-all-hw.bilivideo.com',
    'upos-tf-all-tx.bilivideo.com',
  };

  /// 官方海外节点集合
  static const Set<String> overseasHosts = {
    'upos-sz-mirrorcosov.bilivideo.com',
    'upos-sz-mirroraliov.bilivideo.com',
    'cn-hk-eq-01-01.bilivideo.com',
    'cn-hk-eq-01-03.bilivideo.com',
    'upos-sz-mirrorhwov.bilivideo.com',
    'cn-hk-eq-bcache-01.bilivideo.com',
    'upos-hz-mirrorakam.akamaized.net',
  };

  CdnRacer({
    this.ttlMs = 300000,
    this.hysteresisFactor = 1.2,
    this.maxCandidates = 6,
    this.probeBytes = 65536,
    this.probeBudgetMs = 800,
    this.maxParallel = 2,
    this.httpClient,
    void Function(String message)? logger,
  }) : log = logger ?? BtrLog.log;

  HttpClient get _client =>
      httpClient ??
      (_internalHttpClient ??= HttpClient()
        ..idleTimeout = const Duration(seconds: 15)
        ..connectionTimeout = const Duration(seconds: 5));

  /// 当前缓存（若过期返回 null）
  CdnRaceResult? get cached {
    final cur = _cached;
    if (cur == null) return null;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - cur.measuredAtMs > ttlMs) {
      return null;
    }
    return cur;
  }

  set cached(CdnRaceResult? val) => _cached = val;

  /// 内部记录的最后一次竞速结果（即使过期也保留，便于 UI 查看）
  CdnRaceResult? get lastResult => _cached;

  /// 缓存是否在 TTL 内有效
  bool get isFresh => cached != null;

  /// 判断 host 是否为 Akamai 节点（替换 host 探测必然失败，白占探测位）
  static bool isAkamaiHost(String host) {
    final lower = host.contains(':')
        ? host.split(':').first.toLowerCase()
        : host.toLowerCase();
    return lower == 'akamaized.net' || lower.endsWith('.akamaized.net');
  }

  /// 裁剪候选节点：按 group 过滤、去拉黑、截取前 maxCandidates
  List<String> filterCandidates({
    required List<String> candidates,
    required String group,
    Iterable<String>? bannedHosts,
  }) {
    final banned = bannedHosts?.map((h) => h.toLowerCase()).toSet() ??
        const <String>{};

    final notBanned = candidates.where((c) {
      final host = c.contains(':')
          ? c.split(':').first.toLowerCase()
          : c.toLowerCase();
      return !banned.contains(host);
    }).toList();

    List<String> groupFiltered;
    if (group == 'overseas') {
      final nonAkamai = notBanned.where((c) => !isAkamaiHost(c)).toList();
      final overseasOnly = nonAkamai.where((c) {
        final host = c.contains(':')
            ? c.split(':').first.toLowerCase()
            : c.toLowerCase();
        return overseasHosts.contains(host);
      }).toList();
      groupFiltered = overseasOnly.isNotEmpty ? overseasOnly : nonAkamai;
    } else if (group == 'mainland') {
      final mainlandOnly = notBanned.where((c) {
        final host = c.contains(':')
            ? c.split(':').first.toLowerCase()
            : c.toLowerCase();
        return !overseasHosts.contains(host);
      }).toList();
      groupFiltered = mainlandOnly.isNotEmpty ? mainlandOnly : notBanned;
    } else {
      // auto 分支：跳过 Akamai，保证两组都有代表，按「海外组 1 个、大陆组 1 个」交替各取
      final nonAkamai = notBanned.where((c) => !isAkamaiHost(c)).toList();
      final overseas = <String>[];
      final mainland = <String>[];
      for (final c in nonAkamai) {
        final host = c.contains(':')
            ? c.split(':').first.toLowerCase()
            : c.toLowerCase();
        if (overseasHosts.contains(host)) {
          overseas.add(c);
        } else {
          mainland.add(c);
        }
      }

      if (overseas.isEmpty || mainland.isEmpty) {
        // 任一组为空时退化为原逻辑
        groupFiltered = nonAkamai;
      } else {
        final combined = <String>[];
        int oIdx = 0;
        int mIdx = 0;
        while (combined.length < maxCandidates &&
            (oIdx < overseas.length || mIdx < mainland.length)) {
          if (oIdx < overseas.length) {
            combined.add(overseas[oIdx++]);
            if (combined.length >= maxCandidates) break;
          }
          if (mIdx < mainland.length) {
            combined.add(mainland[mIdx++]);
          }
        }
        groupFiltered = combined;
      }
    }

    return groupFiltered.take(maxCandidates).toList();
  }

  /// 最小有效部分样本门限（16 KiB）：未收满但达到此门限记为下界估计
  static const int minPartialSampleBytes = 16 * 1024;

  /// 自适应降级更小探测样本（16 KiB）
  static const int smallProbeBytes = 16 * 1024;

  /// 提取用于测速简报的短节点名（如 upos-sz-mirrorcosov -> cosov）
  static String shortNodeName(String host) {
    try {
      final h = host.contains(':') ? host.split(':').first : host;
      final match = RegExp(r'mirror([a-zA-Z0-9_-]+)').firstMatch(h);
      if (match != null) return match.group(1)!;
      final parts = h.split('.');
      return parts.isNotEmpty ? parts.first : h;
    } catch (_) {
      return host;
    }
  }

  /// 执行单个区间的 Range 探测：
  /// - 收到首字节后才启动计时（排除建连与 TTFB 延迟对速度的稀释）
  /// - 支持读取超时与整体超时拦截
  Future<({double bps, int bytes, bool isFull})?> _probeRange({
    required Uri probeUri,
    required HttpClient client,
    required int targetBytes,
    required Duration timeout,
  }) async {
    if (timeout.inMilliseconds <= 50) return null;
    final probeSw = Stopwatch()..start();
    HttpClientRequest? req;
    try {
      req = await client.openUrl('GET', probeUri).timeout(timeout);
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-${targetBytes - 1}');
      req.headers.set(
        HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
      );
      req.headers.set(HttpHeaders.refererHeader, 'https://www.bilibili.com/');
      req.headers.set(HttpHeaders.acceptHeader, '*/*');

      final remainingAfterOpen = timeout - probeSw.elapsed;
      if (remainingAfterOpen <= Duration.zero) return null;

      final resp = await req.close().timeout(remainingAfterOpen);
      if (resp.statusCode != HttpStatus.ok &&
          resp.statusCode != HttpStatus.partialContent) {
        await resp
            .drain<void>()
            .timeout(const Duration(milliseconds: 100), onTimeout: () {});
        return null;
      }

      int receivedBytes = 0;
      final transferSw = Stopwatch();
      bool firstByteReceived = false;

      final remainingAfterHeaders = timeout - probeSw.elapsed;
      if (remainingAfterHeaders <= Duration.zero) return null;

      try {
        await for (final chunk in resp.timeout(remainingAfterHeaders)) {
          if (!firstByteReceived) {
            firstByteReceived = true;
            transferSw.start(); // 收到首字节后开始计时！
          }
          receivedBytes += chunk.length;
          if (receivedBytes >= targetBytes || probeSw.elapsed >= timeout) {
            break;
          }
        }
      } catch (_) {
        // 读取超时或中断：保留已接收到的有效字节与首字节以来的计时
      } finally {
        transferSw.stop();
        try {
          req.abort();
        } catch (_) {}
      }

      if (!firstByteReceived || receivedBytes <= 0) {
        return null;
      }

      final elapsedUs = max(100, transferSw.elapsedMicroseconds);
      final sec = elapsedUs / 1000000.0;
      final bps = receivedBytes / sec;
      final isFull = receivedBytes >= (targetBytes * 0.95).floor();

      return (bps: bps, bytes: receivedBytes, isFull: isFull);
    } catch (_) {
      return null;
    } finally {
      probeSw.stop();
      try {
        req?.abort();
      } catch (_) {}
    }
  }

  /// 探测单节点吞吐：
  /// 1. 先尝试 64KB 标准探测，收到首字节后开始计时；
  ///    - 收满（>= 95%）记为 measured 实测；
  ///    - 未收满但 >= 16KB 记为下界估计（isEstimated = true）；
  /// 2. 64KB 探测失败，自适应退一步尝试 16KB 重试一次；
  ///    - 重试收满记为下界估计；
  ///    - 仍失败则判定为「未能测出」（区别于速度为 0）。
  Future<CdnCandidateProbeResult> _probeSingleCandidate({
    required String host,
    required String sampleUrl,
    required HttpClient client,
    required Duration deadline,
  }) async {
    final candidateSw = Stopwatch()..start();
    try {
      final sampleUri = Uri.parse(sampleUrl);
      String targetHost = host;
      int? targetPort;
      if (host.contains(':')) {
        final parts = host.split(':');
        targetHost = parts[0];
        targetPort = int.tryParse(parts[1]);
      }
      final probeUri = sampleUri.replace(
        host: targetHost,
        port: targetPort ?? (sampleUri.hasPort ? sampleUri.port : null),
      );

      // 第 1 步：尝试 64KB 标准探测
      final firstRes = await _probeRange(
        probeUri: probeUri,
        client: client,
        targetBytes: probeBytes,
        timeout: deadline,
      );

      if (firstRes != null) {
        if (firstRes.isFull) {
          // 收满（>=95%）：标记为 measured 实测
          return CdnCandidateProbeResult(
            host: host,
            bps: firstRes.bps,
            bytes: firstRes.bytes,
            isEstimated: false,
          );
        } else if (firstRes.bytes >= minPartialSampleBytes) {
          // 未收满但收到可观样本（>=16KB）：记为下界估计
          return CdnCandidateProbeResult(
            host: host,
            bps: firstRes.bps,
            bytes: firstRes.bytes,
            isEstimated: true,
          );
        }
      }

      // 第 2 步：64KB 探测失败，自适应退一步尝试 16KB 重试一次
      final elapsedMs = candidateSw.elapsedMilliseconds;
      final remainingMs = deadline.inMilliseconds - elapsedMs;
      if (remainingMs >= 80) {
        final retryRes = await _probeRange(
          probeUri: probeUri,
          client: client,
          targetBytes: smallProbeBytes,
          timeout: Duration(milliseconds: remainingMs),
        );

        if (retryRes != null &&
            retryRes.bytes >= (smallProbeBytes * 0.95).floor()) {
          // 小样本重试收满：记为下界估计（小样本保守化）
          return CdnCandidateProbeResult(
            host: host,
            bps: retryRes.bps,
            bytes: retryRes.bytes,
            isEstimated: true,
          );
        }
      }

      // 仍失败：判定为「未能测出」（区别于速度为 0）
      return CdnCandidateProbeResult.unmeasured(host);
    } catch (_) {
      return CdnCandidateProbeResult.unmeasured(host);
    } finally {
      candidateSw.stop();
    }
  }

  /// 用真实播放地址替换 host 后拉 64KB 实测吞吐；返回最优。全失败 → 返回 null（绝不返回假结果）
  Future<CdnRaceResult?> raceThroughput({
    required List<String> candidates,
    required String sampleUrl,
    required String group,
    Iterable<String>? bannedHosts,
    bool ignoreHysteresis = false,
  }) async {
    if (isBackoffActive) {
      final remainingSec = max(
        1,
        (_backoffUntilMs - DateTime.now().millisecondsSinceEpoch) ~/ 1000,
      );
      log('[BTR] 竞速退避中: 连续 $_consecutiveFailures 次未能测出，剩余 ${remainingSec}s → 跳过本轮竞速');
      return null;
    }

    final toProbe = filterCandidates(
      candidates: candidates,
      group: group,
      bannedHosts: bannedHosts,
    );

    if (toProbe.isEmpty) {
      log('[BTR] CDN 竞速: 全部失败 → 不改变现役状态');
      _recordFailure();
      return null;
    }

    final client = _client;
    final batchSw = Stopwatch()..start();
    final allProbeResults = <String, CdnCandidateProbeResult>{};
    final results = <CdnCandidateProbeResult>[];
    int totalBytes = 0;
    int completedCount = 0;

    int nextIndex = 0;
    int runningCount = 0;
    final completer = Completer<void>();

    void scheduleWorkers() {
      while (runningCount < maxParallel && nextIndex < toProbe.length) {
        final elapsed = batchSw.elapsedMilliseconds;
        if (elapsed >= probeBudgetMs) {
          break;
        }
        final host = toProbe[nextIndex++];
        runningCount++;
        final remainingMs = max(80, probeBudgetMs - elapsed);
        final deadline = Duration(milliseconds: remainingMs);

        _probeSingleCandidate(
          host: host,
          sampleUrl: sampleUrl,
          client: client,
          deadline: deadline,
        ).then((res) {
          runningCount--;
          allProbeResults[host] = res;
          if (res.isSuccessful) {
            completedCount++;
            totalBytes += res.bytes;
            results.add(res);
          }
          scheduleWorkers();
        }).catchError((_) {
          runningCount--;
          allProbeResults[host] = CdnCandidateProbeResult.unmeasured(host);
          scheduleWorkers();
        });
      }

      if (runningCount == 0 &&
          (nextIndex >= toProbe.length ||
              batchSw.elapsedMilliseconds >= probeBudgetMs)) {
        if (!completer.isCompleted) {
          completer.complete();
        }
      }
    }

    scheduleWorkers();

    final budgetTimer = Timer(Duration(milliseconds: probeBudgetMs), () {
      if (!completer.isCompleted) {
        completer.complete();
      }
    });

    await completer.future;
    budgetTimer.cancel();
    batchSw.stop();

    lastTotalSampleBytes = totalBytes;

    // 候选详细测速汇总（明确区分未能测出与估算/实测）
    final candidateSummaries = <String>[];
    for (final host in toProbe) {
      final res = allProbeResults[host];
      final shortName = shortNodeName(host);
      if (res != null && res.isSuccessful) {
        final mbps = (res.bps / (1024 * 1024)).toStringAsFixed(2);
        candidateSummaries.add('$shortName=$mbps${res.isEstimated ? "(估算)" : ""}');
      } else {
        candidateSummaries.add('$shortName=0.00(未能测出)');
      }
    }

    if (results.isEmpty) {
      log(
        '[BTR] CDN 竞速: 所有候选均未能测出速度（当前网络到 B 站节点无响应） → 不改变现役状态 '
        '候选 ${candidateSummaries.join(' ')} 用时=${batchSw.elapsedMilliseconds}ms',
      );
      _recordFailure();
      return null;
    }

    resetFailureBackoff();

    // 按吞吐降序选出最快候选：
    // 下界估计取 0.6 倍保守折扣参与比较，避免把慢节点抬成最优；
    // 折扣后速度相同时实测收满优先
    results.sort((a, b) {
      final aSortBps = a.isEstimated ? a.bps * 0.6 : a.bps;
      final bSortBps = b.isEstimated ? b.bps * 0.6 : b.bps;
      final cmp = bSortBps.compareTo(aSortBps);
      if (cmp != 0) return cmp;
      if (a.isEstimated != b.isEstimated) {
        return a.isEstimated ? 1 : -1;
      }
      return b.bps.compareTo(a.bps);
    });
    final fastest = results.first;
    final now = DateTime.now().millisecondsSinceEpoch;

    // 迟滞判断：若 cached 仍在 TTL 内且 新的最快有效速度 < cached.bytesPerSec × hysteresisFactor
    final activeCached = cached;
    if (!ignoreHysteresis && activeCached != null) {
      final effectiveFastestBps =
          fastest.isEstimated ? fastest.bps * 0.6 : fastest.bps;
      if (effectiveFastestBps < activeCached.bytesPerSec * hysteresisFactor) {
        log(
          '[BTR] CDN 竞速: 保持现役 ${activeCached.host} (${_formatSpeed(activeCached.bytesPerSec)}) —— '
          '新最优 ${_formatSpeed(fastest.bps)}${fastest.isEstimated ? " (估算)" : ""} 未达迟滞 $hysteresisFactor×',
        );
        return activeCached;
      }
    }

    final newResult = CdnRaceResult(
      host: fastest.host,
      bytesPerSec: fastest.bps,
      measuredAtMs: now,
      candidateCount: toProbe.length,
      group: group,
      isEstimated: fastest.isEstimated,
    );
    _cached = newResult;

    final sampleKb = (totalBytes / 1024).round();
    log(
      '[BTR] CDN 竞速: 分组=$group 候选=${toProbe.length} 完成=$completedCount '
      '候选详情=[${candidateSummaries.join(' ')}] '
      '最优=${newResult.host} (${_formatSpeed(newResult.bytesPerSec)}${newResult.isEstimated ? " 估算" : ""}) '
      '用时=${batchSw.elapsedMilliseconds}ms 样本=${sampleKb}KB',
    );

    return newResult;
  }

  static String _formatSpeed(double bps) {
    return '${(bps / (1024 * 1024)).toStringAsFixed(2)} MB/s';
  }

  /// 重置状态与清理客户端
  void reset() {
    _cached = null;
    resetFailureBackoff();
    _internalHttpClient?.close(force: true);
    _internalHttpClient = null;
  }
}
