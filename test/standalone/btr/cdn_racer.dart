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

  const CdnRaceResult({
    required this.host,
    required this.bytesPerSec,
    required this.measuredAtMs,
    required this.candidateCount,
    required this.group,
  });

  @override
  String toString() =>
      'CdnRaceResult(host: $host, speed: ${(bytesPerSec / (1024 * 1024)).toStringAsFixed(2)} MB/s, group: $group)';
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

  /// 探测单节点吞吐（Range 0..probeBytes-1），测首字节到收满的速率
  Future<({double bps, int bytes})?> _probeSingleCandidate({
    required String host,
    required String sampleUrl,
    required HttpClient client,
    required Duration deadline,
  }) async {
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

      final req = await client.openUrl('GET', probeUri).timeout(deadline);
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-${probeBytes - 1}');
      req.headers.set(
        HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
      );
      req.headers.set(HttpHeaders.refererHeader, 'https://www.bilibili.com/');
      req.headers.set(HttpHeaders.acceptHeader, '*/*');

      final resp = await req.close().timeout(deadline);
      if (resp.statusCode != HttpStatus.ok &&
          resp.statusCode != HttpStatus.partialContent) {
        await resp
            .drain<void>()
            .timeout(const Duration(milliseconds: 100), onTimeout: () {});
        return null;
      }

      int receivedBytes = 0;
      final sw = Stopwatch()..start();
      await for (final chunk in resp.timeout(deadline)) {
        receivedBytes += chunk.length;
        if (receivedBytes >= probeBytes) {
          break;
        }
      }
      sw.stop();

      // 只有收满（或至少 >= probeBytes * 0.95）才算有效样本；未收满直接判为失败返回 null
      final minValidBytes = (probeBytes * 0.95).floor();
      if (receivedBytes < minValidBytes) {
        return null;
      }

      final elapsedUs = max(100, sw.elapsedMicroseconds);
      final sec = elapsedUs / 1000000.0;
      final bps = receivedBytes / sec;

      return (bps: bps, bytes: receivedBytes);
    } catch (_) {
      return null;
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
    final toProbe = filterCandidates(
      candidates: candidates,
      group: group,
      bannedHosts: bannedHosts,
    );

    if (toProbe.isEmpty) {
      log('[BTR] CDN 竞速: 全部失败 → 不改变现役状态');
      return null;
    }

    final client = _client;
    final batchSw = Stopwatch()..start();
    final results = <({String host, double bps, int bytes})>[];
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
        final remainingMs = max(50, probeBudgetMs - elapsed);
        final deadline = Duration(milliseconds: remainingMs);

        _probeSingleCandidate(
          host: host,
          sampleUrl: sampleUrl,
          client: client,
          deadline: deadline,
        ).then((res) {
          runningCount--;
          if (res != null) {
            completedCount++;
            totalBytes += res.bytes;
            results.add((host: host, bps: res.bps, bytes: res.bytes));
          }
          scheduleWorkers();
        }).catchError((_) {
          runningCount--;
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

    if (results.isEmpty) {
      log('[BTR] CDN 竞速: 全部失败 → 不改变现役状态');
      return null;
    }

    // 按吞吐降序选出最快候选
    results.sort((a, b) => b.bps.compareTo(a.bps));
    final fastest = results.first;
    final now = DateTime.now().millisecondsSinceEpoch;

    // 迟滞判断：若 cached 仍在 TTL 内且 新的最快 < cached.bytesPerSec × hysteresisFactor
    final activeCached = cached;
    if (!ignoreHysteresis && activeCached != null) {
      if (fastest.bps < activeCached.bytesPerSec * hysteresisFactor) {
        log(
          '[BTR] CDN 竞速: 保持现役 ${activeCached.host} (${_formatSpeed(activeCached.bytesPerSec)}) —— '
          '新最优 ${_formatSpeed(fastest.bps)} 未达迟滞 $hysteresisFactor×',
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
    );
    _cached = newResult;

    final sampleKb = (totalBytes / 1024).round();
    log(
      '[BTR] CDN 竞速: 分组=$group 候选=${toProbe.length} 完成=$completedCount '
      '最优=${newResult.host} (${_formatSpeed(newResult.bytesPerSec)}) '
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
    _internalHttpClient?.close(force: true);
    _internalHttpClient = null;
  }
}
