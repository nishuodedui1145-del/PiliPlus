import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;

import 'package:PiliPlus/services/btr_proxy/cdn_pool.dart';
import 'package:PiliPlus/services/btr_proxy/range_core.dart';

/// 取消令牌，用于在客户端断开或切视频时立刻打断全部上游连接
class CancellationToken {
  bool _isCancelled = false;
  Object? _reason;
  final List<void Function()> _listeners = [];

  bool get isCancelled => _isCancelled;
  Object? get reason => _reason;

  void cancel([Object? reason]) {
    if (_isCancelled) return;
    _isCancelled = true;
    _reason = reason ?? 'Operation cancelled';
    for (final listener in List.of(_listeners)) {
      try {
        listener();
      } catch (_) {}
    }
    _listeners.clear();
  }

  void addListener(void Function() listener) {
    if (_isCancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }

  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  void throwIfCancelled() {
    if (_isCancelled) {
      throw CancellationException(_reason);
    }
  }
}

class CancellationException implements Exception {
  final Object? message;
  CancellationException([this.message]);

  @override
  String toString() => 'CancellationException: $message';
}

/// 优先级的信号量，用于并发限流
class PrioritySemaphore {
  int limit;
  int _active = 0;
  int _sequence = 0;
  final List<_SemaphoreEntry> _queue = [];

  PrioritySemaphore(this.limit);

  int get activeCount => _active;
  int get queueLength => _queue.length;
  bool get hasAvailableSlot => _active < limit;

  void setLimit(int newLimit) {
    limit = newLimit.clamp(1, 512);
    _drain();
  }

  Future<void Function()> acquire(
    CancellationToken? token, {
    int priority = 0,
    String? caller,
  }) {
    if (token?.isCancelled == true) {
      return Future.error(CancellationException(token?.reason));
    }

    if (_active >= limit) {
      BtrLog.rateLimitedLog(
        'budget_queued',
        '[BTR] 预算已满排队等待连接: 在途=$_active/上限=$limit, 队列=${_queue.length + 1}${caller != null ? ', 来源=$caller' : ''}',
      );
    }

    final completer = Completer<void Function()>();
    final entry = _SemaphoreEntry(
      completer: completer,
      priority: priority,
      sequence: _sequence++,
      token: token,
    );

    if (token != null) {
      void onCancel() {
        if (!entry.released && !completer.isCompleted) {
          _queue.remove(entry);
          completer.completeError(CancellationException(token.reason));
        }
      }

      token.addListener(onCancel);
      entry.cancelListener = onCancel;
    }

    _queue.add(entry);
    _queue.sort((a, b) {
      final p = b.priority.compareTo(a.priority);
      if (p != 0) return p;
      return a.sequence.compareTo(b.sequence);
    });

    _drain();
    return completer.future;
  }

  void _drain() {
    while (_active < limit && _queue.isNotEmpty) {
      final entry = _queue.removeAt(0);
      if (entry.token?.isCancelled == true) {
        if (!entry.completer.isCompleted) {
          entry.completer.completeError(CancellationException(entry.token?.reason));
        }
        continue;
      }

      _active++;
      void release() {
        if (entry.released) return;
        entry.released = true;
        if (entry.token != null && entry.cancelListener != null) {
          entry.token!.removeListener(entry.cancelListener!);
        }
        _active = max(0, _active - 1);
        _drain();
      }

      entry.completer.complete(release);
    }
  }
}

class _SemaphoreEntry {
  final Completer<void Function()> completer;
  final int priority;
  final int sequence;
  final CancellationToken? token;
  void Function()? cancelListener;
  bool released = false;

  _SemaphoreEntry({
    required this.completer,
    required this.priority,
    required this.sequence,
    required this.token,
  });
}

class PieceResult {
  final Uint8List bytes;
  final int? total;
  final String url;
  final double bps;
  final int actualEnd;

  const PieceResult({
    required this.bytes,
    required this.total,
    required this.url,
    this.bps = 0.0,
    required this.actualEnd,
  });
}

/// 启动探测元数据结果
class StartupProbeResult {
  final Uint8List headBytes;
  final int? totalLength;
  final String winningUrl;
  final int headStart;
  final int headEnd;
  final double bps;

  const StartupProbeResult({
    required this.headBytes,
    required this.totalLength,
    required this.winningUrl,
    required this.headStart,
    required this.headEnd,
    this.bps = 0.0,
  });
}

/// 多 Range 并发下载调度核心（移植自 BTR 的 idm-downloader.js）
class MultiRangeDownloader {
  final HttpClient _httpClient;
  final PrioritySemaphore _semaphore;
  Map<String, String> defaultHeaders;
  int _concurrency;
  int _maxInFlightSockets;

  int get concurrency => _concurrency;
  int get maxInFlightSockets => _maxInFlightSockets;
  int get activeInFlightSockets => _semaphore.activeCount;

  /// 为降级、重试或外部路径申请 socket 预算槽位（必须计入全局在途预算）
  Future<void Function()> acquireSocket(
    CancellationToken? token, {
    int priority = 0,
    String? caller,
  }) =>
      _semaphore.acquire(token, priority: priority, caller: caller);

  MultiRangeDownloader({
    int concurrency = RangeCore.defaultConcurrency,
    int? maxInFlightSockets,
    HttpClient? httpClient,
    this.defaultHeaders = const {},
  })  : _concurrency = concurrency,
        _maxInFlightSockets = maxInFlightSockets ??
            (concurrency + RangeCore.defaultMaxInFlightExtra),
        _semaphore = PrioritySemaphore(
          maxInFlightSockets ??
              (concurrency + RangeCore.defaultMaxInFlightExtra),
        ),
        _httpClient = httpClient ??
            (HttpClient()
              ..idleTimeout = const Duration(seconds: 15)
              ..connectionTimeout = const Duration(seconds: 8));

  void setConcurrency(int concurrency, {int? maxInFlightSockets}) {
    _concurrency = concurrency.clamp(1, 512);
    _maxInFlightSockets = maxInFlightSockets ??
        (_concurrency + RangeCore.defaultMaxInFlightExtra);
    _semaphore.setLimit(_maxInFlightSockets);
  }

  /// 单次 piece 下载尝试（包含独立首字节超时 5.5s、停滞 4s、总计 15s）
  Future<PieceResult> attempt({
    required RangePiece piece,
    required String url,
    required CancellationToken token,
    required CdnPool pool,
    int priority = 0,
    void Function()? onFirstByteReceived,
  }) async {
    token.throwIfCancelled();
    final release = await _semaphore.acquire(
      token,
      priority: priority,
      caller: priority >= 200 ? 'probe' : (priority >= 25 ? 'hedge' : 'piece'),
    );

    final innerToken = CancellationToken();
    void onParentCancel() => innerToken.cancel(token.reason);
    token.addListener(onParentCancel);

    HttpClientRequest? currentRequest;
    Timer? firstByteTimer;
    Timer? stallTimer;
    Timer? totalTimer;

    int receivedBytes = 0;
    bool firstByteReceived = false;
    bool isFirstByteTimeout = false;
    final stopwatch = Stopwatch()..start();

    try {
      token.throwIfCancelled();

      // 独立首字节超时：若在 5.5s 内未收到任何数据字节，立即掐掉请求并记 0 字节 strike
      firstByteTimer = Timer(RangeCore.firstByteTimeout, () {
        if (!firstByteReceived) {
          isFirstByteTimeout = true;
          innerToken.cancel('CDN 首字节超时 (${RangeCore.firstByteTimeout.inMilliseconds}ms)');
          currentRequest?.abort();
        }
      });

      totalTimer = Timer(RangeCore.attemptTimeout, () {
        innerToken.cancel('CDN 子块总耗时超限 (${RangeCore.attemptTimeout.inMilliseconds}ms)');
        currentRequest?.abort();
      });

      final uri = Uri.parse(url);
      final req = await _httpClient.getUrl(uri);
      currentRequest = req;

      // 注册内层 token 中断
      innerToken.addListener(req.abort);

      if (innerToken.isCancelled) {
        req.abort();
        throw CancellationException(innerToken.reason);
      }

      // 设置请求头
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=${piece.start}-${piece.end}');
      defaultHeaders.forEach((k, v) {
        req.headers.set(k, v);
      });

      final resp = await req.close();
      // 注意：不能在收到响应头时取消首字节超时，必须在收到首个数据 chunk 时取消

      final contentRangeHeader = resp.headers.value(HttpHeaders.contentRangeHeader);
      final contentRange = RangeCore.parseContentRange(contentRangeHeader);

      // 上游不支持或忽略 Range（返回 200 OK 或无合法 Content-Range）
      if (resp.statusCode == HttpStatus.ok) {
        throw const RangeNotSupportedException(
          '上游返回 200 OK 而非 206 Partial Content，不支持或忽略了 Range 请求',
        );
      }

      if (resp.statusCode == HttpStatus.partialContent && contentRange == null) {
        throw RangeNotSupportedException(
          '上游返回 206 Partial Content 但缺少合法 Content-Range 响应头: $contentRangeHeader',
        );
      }

      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw UpstreamHttpException(
          resp.statusCode,
          '上游返回 HTTP ${resp.statusCode}: ${resp.reasonPhrase}',
          uri: uri,
        );
      }

      if (resp.statusCode != HttpStatus.partialContent) {
        throw HttpException(
          '上游状态码非 206: HTTP ${resp.statusCode}',
          uri: Uri(scheme: uri.scheme, host: uri.host, path: uri.path),
        );
      }

      if (contentRange == null ||
          contentRange.start != piece.start ||
          contentRange.end < piece.start) {
        throw HttpException(
          'Range 校验失败：HTTP ${resp.statusCode}, content-range: $contentRangeHeader, expect: ${piece.start}-${piece.end}',
          uri: Uri(scheme: uri.scheme, host: uri.host, path: uri.path),
        );
      }

      final actualEnd = contentRange.end;
      final actualLength = actualEnd - contentRange.start + 1;

      // 读取响应体并监控停滞超时（stall timeout）
      final chunks = <Uint8List>[];
      final completer = Completer<Uint8List>();

      void armStallTimer() {
        stallTimer?.cancel();
        stallTimer = Timer(RangeCore.stallTimeout, () {
          innerToken.cancel('CDN 子块停止传输 (${RangeCore.stallTimeout.inMilliseconds}ms)');
          currentRequest?.abort();
        });
      }

      armStallTimer();

      late final StreamSubscription<List<int>> subscription;
      subscription = resp.listen(
        (chunkData) {
          if (!firstByteReceived) {
            firstByteReceived = true;
            firstByteTimer?.cancel();
            firstByteTimer = null;
            onFirstByteReceived?.call();
          }
          armStallTimer();
          final bytes = chunkData is Uint8List
              ? chunkData
              : Uint8List.fromList(chunkData);
          chunks.add(bytes);
          receivedBytes += bytes.lengthInBytes;
        },
        onError: (err) {
          stallTimer?.cancel();
          if (!completer.isCompleted) {
            completer.completeError(err);
          }
        },
        onDone: () {
          stallTimer?.cancel();
          if (!completer.isCompleted) {
            try {
              final full = RangeCore.concatChunks(chunks, actualLength);
              completer.complete(full);
            } catch (e, st) {
              completer.completeError(e, st);
            }
          }
        },
        cancelOnError: true,
      );

      innerToken.addListener(() {
        subscription.cancel();
      });

      final bodyBytes = await completer.future;

      if (bodyBytes.lengthInBytes != actualLength) {
        throw HttpException(
          '子块长度不符：${bodyBytes.lengthInBytes}/$actualLength',
          uri: Uri(scheme: uri.scheme, host: uri.host, path: uri.path),
        );
      }

      // 使用微秒级计时计算 bps，提高小分片测速精度
      final durationSec = max(0.0001, stopwatch.elapsedMicroseconds / 1000000.0);
      final bps = bodyBytes.lengthInBytes / durationSec;
      pool.success(url, bps);

      void checkSemiDead(int bytesCount) {
        if (token.isCancelled) return;
        if (bytesCount <= 0) return;
        final elapsedMs = stopwatch.elapsedMilliseconds;
        final targetConcurrency = pool.adaptiveConcurrency ??
            min(_concurrency, RangeCore.maxRampConcurrency);
        final expectedMs = RangeCore.calculateExpectedPieceMs(
          pieceBytes: piece.length,
          targetBps: RangeCore.requiredThroughputBytesPerSec(pool.videoBitrateBytesPerSec),
          concurrency: targetConcurrency,
          bitrateBytesPerSec: pool.videoBitrateBytesPerSec,
        );
        final thresholdMs = max(3.0 * expectedMs, 4000.0);
        if (elapsedMs > thresholdMs) {
          final elapsedSec = elapsedMs / 1000.0;
          final expectedSec = expectedMs / 1000.0;
          final strikes = pool.recordSemiDead(url);
          if (kDebugMode) {
            debugPrint(
              '[BTR] 节点半死 piece#${piece.index} '
              '耗时 ${elapsedSec.toStringAsFixed(2)}s'
              '（期望 ${expectedSec.toStringAsFixed(2)}s）'
              '来源=${BtrLog.hostOf(url)}，'
              'strike=$strikes/${pool.banList.strikeLimit}',
            );
          }
        }
      }

      checkSemiDead(bodyBytes.lengthInBytes);

      return PieceResult(
        bytes: bodyBytes,
        total: contentRange.total,
        url: url,
        bps: bps,
        actualEnd: actualEnd,
      );
    } catch (error) {
      final isParentAbort = token.isCancelled;
      final isAbort = isParentAbort;
      final timeoutErr = isFirstByteTimeout
          ? TimeoutException('CDN 首字节超时 (${RangeCore.firstByteTimeout.inMilliseconds}ms)')
          : null;
      final effectiveError = timeoutErr ?? error;

      if (!isAbort && error is! RangeNotSupportedException && receivedBytes > 0) {
        final elapsedMs = stopwatch.elapsedMilliseconds;
        final targetConcurrency = pool.adaptiveConcurrency ??
            min(_concurrency, RangeCore.maxRampConcurrency);
        final expectedMs = RangeCore.calculateExpectedPieceMs(
          pieceBytes: piece.length,
          targetBps: RangeCore.requiredThroughputBytesPerSec(pool.videoBitrateBytesPerSec),
          concurrency: targetConcurrency,
          bitrateBytesPerSec: pool.videoBitrateBytesPerSec,
        );
        final thresholdMs = max(3.0 * expectedMs, 4000.0);
        if (elapsedMs > thresholdMs) {
          final elapsedSec = elapsedMs / 1000.0;
          final expectedSec = expectedMs / 1000.0;
          final strikes = pool.recordSemiDead(url);
          if (kDebugMode) {
            debugPrint(
              '[BTR] 节点半死 piece#${piece.index} '
              '耗时 ${elapsedSec.toStringAsFixed(2)}s'
              '（期望 ${expectedSec.toStringAsFixed(2)}s）'
              '来源=${BtrLog.hostOf(url)}，'
              'strike=$strikes/${pool.banList.strikeLimit}',
            );
          }
        }
      }

      if (error is! RangeNotSupportedException) {
        pool.failure(
          url,
          effectiveError,
          receivedBytes: receivedBytes,
          isAbort: isAbort,
        );
      }
      if (timeoutErr != null) {
        throw timeoutErr;
      }
      rethrow;
    } finally {
      firstByteTimer?.cancel();
      stallTimer?.cancel();
      totalTimer?.cancel();
      token.removeListener(onParentCancel);
      release();
    }
  }

  /// 下载单个 piece，带 Hedge 双路竞速与重试机制
  Future<PieceResult> downloadPiece({
    required RangePiece piece,
    required CdnPool pool,
    required CancellationToken token,
    List<String> preferredUrls = const [],
    bool startupMode = false,
    int priority = 0,
    bool Function()? isSlowPieceEligible,
    bool Function()? isHedgeAllowed,
    void Function(void Function() triggerHedge)? onHedgeReady,
  }) async {
    token.throwIfCancelled();

    final preferred = List.of(preferredUrls);
    final rescue = pool
        .rescueCandidates()
        .where((u) => !preferred.contains(u))
        .toList();

    final candidates = <String>[];
    for (final u in preferred) {
      if (!candidates.contains(u)) candidates.add(u);
    }
    for (final u in rescue) {
      if (!candidates.contains(u)) candidates.add(u);
    }
    for (final u in pool.ordered(piece.index)) {
      if (!candidates.contains(u)) candidates.add(u);
    }

    final candidatesList = List.of(candidates);
    Object? lastError;
    int attemptCount = 0;
    int prevReceivedBytes = 0;
    const minAttempts = RangeCore.minPieceRetries;

    while (attemptCount < minAttempts ||
        (attemptCount < 8 && candidatesList.any(pool.isUsable))) {
      token.throwIfCancelled();
      if (candidatesList.isEmpty) break;

      // 若非首轮尝试，进行指数退避
      if (attemptCount > 0) {
        final backoffMs = 150 * (1 << min(attemptCount - 1, 3));
        await Future.delayed(Duration(milliseconds: backoffMs));
        token.throwIfCancelled();
      }
      attemptCount++;

      final open = candidatesList.where(pool.isUsable).toList();
      final poolToUse = open.isNotEmpty ? open : candidatesList;
      if (poolToUse.isEmpty) break;
      final List<String> pair = poolToUse.length >= 2
          ? poolToUse.take(2).toList()
          : [poolToUse[0], poolToUse[0]];

      // 若为重试，打分块重试诊断日志
      if (attemptCount > 1) {
        BtrLog.rateLimitedLog(
          'piece_retry',
          '[BTR] 分块重试 piece#${piece.index} 第 $attemptCount 次（上一路 $prevReceivedBytes 字节，换 ${BtrLog.hostOf(pair[0])}）',
        );
      }

      // 轮换候选列表，下一次重试尝试其他 CDN 节点
      if (candidatesList.length > 1) {
        final first = candidatesList.removeAt(0);
        candidatesList.add(first);
      }

      final token0 = CancellationToken();
      final token1 = CancellationToken();
      void onParentCancel() {
        token0.cancel(token.reason);
        token1.cancel(token.reason);
      }

      token.addListener(onParentCancel);

      final slowThreshold = pool.slowPieceThreshold;
      final pieceMaxTimeout = slowThreshold * 3;
      Timer? pieceTimeoutTimer;
      Timer? hedgeTimer;

      try {
        final completer = Completer<PieceResult>();
        var activeCount = 0;
        final errors = <Object>[];
        bool road2Started = false;

        void checkAllDone() {
          if (activeCount == 0 && !completer.isCompleted) {
            completer.completeError(
              errors.isNotEmpty ? errors.last : Exception('没有可用 CDN 节点'),
            );
          }
        }

        void armPieceTimeout(Duration duration) {
          pieceTimeoutTimer?.cancel();
          pieceTimeoutTimer = Timer(duration, () {
            if (!completer.isCompleted) {
              token0.cancel('超过 ${(duration.inMilliseconds / 1000).toStringAsFixed(1)}s 未完成');
              token1.cancel('超过 ${(duration.inMilliseconds / 1000).toStringAsFixed(1)}s 未完成');
              completer.completeError(
                TimeoutException(
                  'piece #${piece.index} 超过 ${(duration.inMilliseconds / 1000).toStringAsFixed(1)}s 仍未完成',
                ),
              );
            }
          });
        }

        // 首字节前独立首字节超时生效（5.5s）；收到首字节后约束传输总耗时在自适应阈值内
        armPieceTimeout(RangeCore.firstByteTimeout + slowThreshold);

        void launchRoad2() {
          if (road2Started || completer.isCompleted || token.isCancelled) return;
          if (pair.length < 2) return;
          road2Started = true;

          // 任务 A：只有当前聚合吞吐 < 目标吞吐（即真的喂不动）时，才允许对慢块发起第二路（hedge）；
          // 聚合已达标时，慢块只记日志、不抢路。
          final isAllowed = isHedgeAllowed?.call() ?? true;
          if (!isAllowed) {
            BtrLog.rateLimitedLog(
              'hedge_skip_${piece.index}',
              '[BTR] 慢块但聚合已达标，不抢第二路 piece#${piece.index}',
            );
            return;
          }

          activeCount++;

          final isSameHost = pair[0] == pair[1];
          BtrLog.rateLimitedLog(
            isSameHost ? 'slow_rescue_single' : 'slow_rescue',
            isSameHost
                ? '[BTR] 慢块补救 piece#${piece.index} 仅有单可用节点，同节点并发第二路竞速 → ${BtrLog.hostOf(pair[1])}'
                : '[BTR] 慢块补救 piece#${piece.index} 未在 ${(slowThreshold.inMilliseconds / 1000).toStringAsFixed(2)}s 内到达，已并发第二路 → ${BtrLog.hostOf(pair[1])}',
          );

          final sw1 = Stopwatch()..start();
          attempt(
            piece: piece,
            url: pair[1],
            token: token1,
            pool: pool,
            priority: priority + 25,
            onFirstByteReceived: () => armPieceTimeout(pieceMaxTimeout),
          ).then((res) {
            if (!completer.isCompleted) {
              sw1.stop();
              final sec = sw1.elapsedMicroseconds / 1000000.0;
              if (sec >= slowThreshold.inMilliseconds / 1000.0) {
                BtrLog.rateLimitedLog(
                  'slow_piece',
                  '[BTR] 慢块 piece#${piece.index} ${piece.start}-${piece.end} 耗时 ${sec.toStringAsFixed(2)}s（阈值 ${(slowThreshold.inMilliseconds / 1000).toStringAsFixed(2)}s）来源=${BtrLog.hostOf(pair[1])}',
                );
              }
              completer.complete(res);
              token0.cancel('并发竞速已决出胜者');
            }
          }).catchError((err) {
            if (err is RangeNotSupportedException || err is UpstreamHttpException) {
              if (!completer.isCompleted) {
                token0.cancel(err.toString());
                token1.cancel(err.toString());
                completer.completeError(err);
              }
              return;
            }
            errors.add(err);
          }).whenComplete(() {
            activeCount--;
            checkAllDone();
          });
        }

        // 启动第一路
        activeCount++;
        final sw0 = Stopwatch()..start();
        attempt(
          piece: piece,
          url: pair[0],
          token: token0,
          pool: pool,
          priority: priority,
          onFirstByteReceived: () => armPieceTimeout(pieceMaxTimeout),
        ).then((res) {
          if (!completer.isCompleted) {
            sw0.stop();
            final durationSec = sw0.elapsedMicroseconds / 1000000.0;
            if (durationSec >= slowThreshold.inMilliseconds / 1000.0) {
              BtrLog.rateLimitedLog(
                'slow_piece',
                '[BTR] 慢块 piece#${piece.index} ${piece.start}-${piece.end} 耗时 ${durationSec.toStringAsFixed(2)}s（阈值 ${(slowThreshold.inMilliseconds / 1000).toStringAsFixed(2)}s）来源=${BtrLog.hostOf(pair[0])}',
              );
            }
            completer.complete(res);
            token1.cancel('并发竞速已决出胜者');
          }
        }).catchError((err) {
          if (err is RangeNotSupportedException || err is UpstreamHttpException) {
            if (!completer.isCompleted) {
              token0.cancel(err.toString());
              token1.cancel(err.toString());
              completer.completeError(err);
            }
            return;
          }
          errors.add(err);
        }).whenComplete(() {
          activeCount--;
          checkAllDone();
        });

        // 第二路（慢块立刻补救，而不是干等）
        if (pair.length > 1) {
          if (startupMode) {
            hedgeTimer = Timer(const Duration(milliseconds: 250), launchRoad2);
          } else {
            onHedgeReady?.call(launchRoad2);
            hedgeTimer = Timer(slowThreshold, () {
              if (isSlowPieceEligible?.call() == true) {
                launchRoad2();
              }
            });
          }
        }

        try {
          final winner = await completer.future;
          pieceTimeoutTimer?.cancel();
          hedgeTimer?.cancel();
          token0.cancel('任务已完成');
          token1.cancel('任务已完成');
          return winner;
        } catch (e) {
          pieceTimeoutTimer?.cancel();
          hedgeTimer?.cancel();
          if (e is RangeNotSupportedException || e is UpstreamHttpException) {
            rethrow;
          }
          lastError = e;
          prevReceivedBytes = 0;
        }
      } finally {
        pieceTimeoutTimer?.cancel();
        hedgeTimer?.cancel();
        token.removeListener(onParentCancel);
      }
    }

    throw lastError ?? Exception('所有候选 CDN 尝试均失败');
  }

  /// 向上游发送真正的 HEAD 请求探测元数据，只读响应头中的 Content-Range / Content-Length
  /// 成功时返回文件总大小 totalLength，不读任何 body 数据；若失败或拿不到总长度则返回 null
  Future<int?> probeHeadFast({
    required CdnPool pool,
    required CancellationToken token,
    String? rangeHeader,
  }) async {
    token.throwIfCancelled();
    final candidates = pool.rangeCandidates();
    if (candidates.isEmpty) return null;

    final targetUrls = candidates.take(2).toList();
    for (final url in targetUrls) {
      if (token.isCancelled) return null;
      HttpClientRequest? req;
      void onCancel() {
        try {
          req?.abort();
        } catch (_) {}
      }

      token.addListener(onCancel);
      final release = await acquireSocket(token, priority: 200, caller: 'probe_head_fast');
      try {
        final uri = Uri.parse(url);
        req = (await _httpClient.openUrl('HEAD', uri))
          ..followRedirects = true
          ..maxRedirects = 5;
        defaultHeaders.forEach((k, v) {
          req!.headers.set(k, v);
        });
        if (rangeHeader != null) {
          req.headers.set(HttpHeaders.rangeHeader, rangeHeader);
        }

        final resp =
            await req.close().timeout(const Duration(milliseconds: 3000));
        await resp.drain<void>().catchError((_) {});

        if (resp.statusCode == HttpStatus.ok) {
          final cl = resp.headers.contentLength;
          if (cl > 0) {
            pool.success(url, 0.0);
            return cl;
          }
        } else if (resp.statusCode == HttpStatus.partialContent) {
          final crHeader = resp.headers.value(HttpHeaders.contentRangeHeader);
          final cr = RangeCore.parseContentRange(crHeader);
          if (cr?.total != null && cr!.total! > 0) {
            pool.success(url, 0.0);
            return cr.total;
          }
        } else if (resp.statusCode >= 400) {
          throw UpstreamHttpException(
            resp.statusCode,
            'HEAD 探测上游返回 HTTP ${resp.statusCode}',
            uri: uri,
          );
        }
      } catch (e) {
        if (e is UpstreamHttpException) rethrow;
        if (kDebugMode) {
          debugPrint('[BTR] HEAD probe failed on ${BtrLog.hostOf(url)}: $e');
        }
      } finally {
        token.removeListener(onCancel);
        release();
      }
    }
    return null;
  }

  /// 针对首块 Range 进行探测，获得首块数据、文件总大小、最快节点以及单连接实测速度
  /// 包含启动测速：对候选节点（分批覆盖最多 12 个，每批最多 4 路并发）各发小 Range 请求（64KB）并发测速
  Future<StartupProbeResult> probeHead({
    required int start,
    int? end,
    required CdnPool pool,
    required CancellationToken token,
    int minChunkBytes = RangeCore.defaultMinChunkBytes,
  }) async {
    token.throwIfCancelled();

    final candidateUrls = pool.rangeCandidates();
    const probeChunkSize = RangeCore.defaultStartupProbeChunkBytes; // 64 KiB
    final requestedLength = end != null ? (end - start + 1) : null;
    final headLength = requestedLength != null
        ? min(requestedLength, probeChunkSize)
        : probeChunkSize;

    final headPiece = RangePiece(
      index: 0,
      start: start,
      end: start + headLength - 1,
      length: headLength,
    );

    // 若已经测速过，或候选池只有 1 个，直接走单节点探测
    if (pool.hasSpeedTested || candidateUrls.length <= 1) {
      final preferred = pool.isAnchorEligible() && pool.anchorUrl != null
          ? [pool.anchorUrl!]
          : (pool.stickyUrl != null ? [pool.stickyUrl!] : candidateUrls);
      final headResult = await downloadPiece(
        piece: headPiece,
        pool: pool,
        token: token,
        preferredUrls: preferred,
        startupMode: true,
        priority: 200,
      );

      pool
        ..hasSpeedTested = true
        ..setStickyUrl(headResult.url);

      return StartupProbeResult(
        headBytes: headResult.bytes,
        totalLength: headResult.total,
        winningUrl: headResult.url,
        headStart: headPiece.start,
        headEnd: headResult.actualEnd,
        bps: headResult.bps,
      );
    }

    // 启动测速：大陆组与海外组各测一批（每组最多 4 个候选、样本 64KB，整体时间上限约 1.5 秒）
    final mainlandCandidates = pool.mainlandProbeCandidates;
    final overseasCandidates = pool.overseasProbeCandidates;

    final batches = <({CdnGroup group, List<String> urls})>[];
    if (mainlandCandidates.isNotEmpty) {
      batches.add((group: CdnGroup.mainland, urls: mainlandCandidates));
    }
    if (overseasCandidates.isNotEmpty) {
      batches.add((group: CdnGroup.overseas, urls: overseasCandidates));
    }

    final probeStopwatch = Stopwatch()..start();
    final results = <String, double>{};
    final triedCandidates = <String>[];
    PieceResult? bestResult;
    PieceResult? anchorResult;
    double mainlandMaxBps = 0.0;
    double overseasMaxBps = 0.0;

    for (var batchIndex = 0; batchIndex < batches.length; batchIndex++) {
      final elapsedMs = probeStopwatch.elapsedMilliseconds;
      final remainingMs = RangeCore.startupProbeTotalTimeout.inMilliseconds - elapsedMs;
      if (remainingMs <= 0) {
        // 整体时间已达上限，超时的批次直接放弃并把该批视为未知，不阻塞起播
        break;
      }

      final batch = batches[batchIndex];
      final batchTimeoutMs = min(remainingMs, RangeCore.startupProbeBatchTimeout.inMilliseconds);
      final batchCompleter = Completer<void>();
      final batchToken = CancellationToken();
      void onParentCancel() => batchToken.cancel(token.reason);
      token.addListener(onParentCancel);

      var activeInBatch = batch.urls.length;
      bool batchTimedOut = false;
      final batchTimer = Timer(Duration(milliseconds: batchTimeoutMs), () {
        batchTimedOut = true;
        batchToken.cancel('启动测速批次超时');
        if (!batchCompleter.isCompleted) {
          batchCompleter.complete();
        }
      });

      for (final url in batch.urls) {
        triedCandidates.add(url);
        final childToken = CancellationToken();
        void onBatchCancel() => childToken.cancel(batchToken.reason);
        batchToken.addListener(onBatchCancel);

        attempt(
          piece: headPiece,
          url: url,
          token: childToken,
          pool: pool,
          priority: 200,
        ).then((res) {
          batchToken.removeListener(onBatchCancel);
          if (res.bytes.isEmpty || res.bps <= 0.0) {
            // 判定：测速拿到 0 字节 -> 加入不可用集合
            pool
              ..markUnusable(url)
              ..failure(url, Exception('测速拿到 0 字节'), receivedBytes: res.bytes.length, isAbort: false);
            results[url] = 0.0;
          } else {
            results[url] = res.bps;
            if (batch.group == CdnGroup.mainland) {
              if (res.bps > mainlandMaxBps) mainlandMaxBps = res.bps;
            } else {
              if (res.bps > overseasMaxBps) overseasMaxBps = res.bps;
            }
            if (pool.anchorUrl != null && CdnBanList.hostOf(url) == pool.anchorHost) {
              anchorResult = res;
            }
            if (bestResult == null || res.bps > (bestResult?.bps ?? 0.0)) {
              bestResult = res;
            }
          }
        }).catchError((err) {
          batchToken.removeListener(onBatchCancel);
          results[url] = 0.0;
          if (batchTimedOut && childToken.isCancelled) {
            // 因整体/批次超时被放弃的批次：视为未知，不加入不可用集合，不阻塞起播
          } else {
            // 判定：测速超时或返回错误 -> 加入不可用集合
            pool.markUnusable(url);
            if (err is! RangeNotSupportedException) {
              pool.failure(url, err, isAbort: false);
            }
          }
        }).whenComplete(() {
          activeInBatch--;
          if (activeInBatch == 0 && !batchCompleter.isCompleted) {
            batchTimer.cancel();
            batchCompleter.complete();
          }
        });
      }

      await batchCompleter.future;
      batchTimer.cancel();
      token.removeListener(onParentCancel);

      // 若已有成功结果且总耗时已满，不再开启下一批
      if (bestResult != null &&
          probeStopwatch.elapsedMilliseconds >= RangeCore.startupProbeTotalTimeout.inMilliseconds) {
        break;
      }
    }

    // 按两组最快节点实测速度决策主候选池与兜底池
    // 按两组最快节点实测速度决策主候选池与兜底池。
    // 若用户在设置里手动指定了分组（对应官方「CDN 模式」），优先服从用户。
    final pinned = pool.preferredGroup;
    if (pinned != null) {
      pool.selectGroup(pinned);
      BtrLog.rateLimitedLog(
        'group_pinned',
        '[BTR] 节点分组（用户在设置里指定）: ${pinned == CdnGroup.mainland ? "大陆组" : "海外组"}',
      );
    } else if (overseasMaxBps > mainlandMaxBps) {
      pool.selectGroup(CdnGroup.overseas);
    } else {
      pool.selectGroup(CdnGroup.mainland);
    }

    // 兜底：若所有测速候选均未拿到成功数据，回退到主池首个可用候选单连接获取
    if (bestResult == null) {
      final availableUrls = pool.urls();
      final fallbackUrl = availableUrls.isNotEmpty
          ? availableUrls.first
          : (candidateUrls.isNotEmpty ? candidateUrls.first : '');
      final headResult = await downloadPiece(
        piece: headPiece,
        pool: pool,
        token: token,
        preferredUrls: [fallbackUrl],
        startupMode: true,
        priority: 200,
      );
      bestResult = headResult;
    }

    // 尊重用户指定的锚点节点：只要它没被拉黑、且实测速度不低于"码率 × 1.2"，就优先分派给它
    final PieceResult finalWinningResult;
    final String chosenWinningUrl;
    if (anchorResult != null && pool.isAnchorEligible()) {
      finalWinningResult = anchorResult!;
      chosenWinningUrl = anchorResult!.url;
    } else {
      finalWinningResult = bestResult!;
      chosenWinningUrl = bestResult!.url;
    }

    pool
      ..hasSpeedTested = true
      ..setStickyUrl(chosenWinningUrl);

    // 格式化打印测速日志（候选测速结果汇总与优选组）
    final summary = <String>[];
    for (final u in triedCandidates) {
      final bps = results[u] ?? pool.getSpeed(u) ?? 0.0;
      final mbps = (bps / (1024 * 1024)).toStringAsFixed(2);
      final isDead = pool.isDead(u);
      summary.add('${BtrLog.shortNodeName(u)}=$mbps${isDead ? '(dead)' : ''}');
    }
    BtrLog.rateLimitedLog(
      'speed_test',
      '[BTR] 节点测速 候选 ${summary.join(' ')}（MB/s，样本 ${(headLength / 1024).round()}KB/节点，'
      '优选=${pool.activeGroup == CdnGroup.overseas ? "海外组" : "大陆组"}，'
      '胜出=${BtrLog.hostOf(chosenWinningUrl)}）',
    );

    return StartupProbeResult(
      headBytes: finalWinningResult.bytes,
      totalLength: finalWinningResult.total,
      winningUrl: chosenWinningUrl,
      headStart: headPiece.start,
      headEnd: finalWinningResult.actualEnd,
      bps: finalWinningResult.bps,
    );
  }

  /// 滑动窗口流式下载分块：
  ///
  /// 【滑动窗口调度规则】：
  /// 1. 同一时刻在途的 piece 不超过 [concurrency] 个。
  /// 2. 只有当 nextFlushIndex 那一块到齐、写出、从缓冲区移除置 null 之后，才发起 nextFlushIndex + concurrency 那一块。
  /// 3. 写出即释放：分块写入 Socket 响应流后立刻从 completedPieces 移除，切断引用供 GC 回收。
  /// 4. 峰值内存上限严格受控于 concurrency × maxPieceBytes（例如 8 × 512 KiB ≈ 4 MiB，快节点 2 × 512 KiB ≈ 1 MiB）。
  /// 5. 异常路径保护：任一分块下载失败或 Socket 写出失败，均触发 CancellationToken 级联打断全部在途连接，
  ///    Completer 向上抛出异常，确保外层 HttpResponse 一定被 close()。
  Future<void> streamPieces({
    required List<RangePiece> pieces,
    required CdnPool pool,
    required CancellationToken token,
    required String winningUrl,
    required int concurrency,
    double v1Bps = 0.0,
    int? originalThreads,
    required Future<void> Function(Uint8List chunk) onOrderedChunk,
  }) async {
    final streamer = _SlidingWindowStreamer(
      downloader: this,
      pieces: pieces,
      pool: pool,
      token: token,
      winningUrl: winningUrl,
      concurrency: concurrency,
      v1Bps: v1Bps,
      originalThreads: originalThreads,
      onOrderedChunk: onOrderedChunk,
    );
    await streamer.stream();
  }

  /// 流式下载完整区间，严格按照 piece 索引顺序通过 onOrderedChunk 吐回
  Future<void> streamRange({
    required int start,
    required int end,
    required CdnPool pool,
    required CancellationToken token,
    required Future<void> Function(Uint8List chunk) onOrderedChunk,
    int? concurrency,
    int minChunkBytes = RangeCore.defaultMinChunkBytes,
    int maxPieceBytes = RangeCore.defaultMaxPieceBytes,
  }) async {
    token.throwIfCancelled();

    final totalLength = end - start + 1;
    if (totalLength <= 0) return;

    final effConcurrency = concurrency ?? RangeCore.defaultConcurrency;

    // 1. 优先下载 Head 片段（探测首块）
    final probe = await probeHead(
      start: start,
      end: end,
      pool: pool,
      token: token,
      minChunkBytes: minChunkBytes,
    );

    // 立即输出首块
    await onOrderedChunk(probe.headBytes);

    // 若首块已覆盖全部请求范围，直接返回
    if (probe.headEnd >= end) {
      return;
    }

    // 2. 切分剩余区间并采用滑动窗口调度（块大小与并发数解耦）
    final remainingStart = probe.headEnd + 1;
    final remainingPieces = RangeCore.splitRange(
      remainingStart,
      end,
      maxPieceBytes: maxPieceBytes,
    );

    if (remainingPieces.isEmpty) return;

    final initialConcurrency = pool.adaptiveConcurrency ?? effConcurrency;

    await streamPieces(
      pieces: remainingPieces,
      pool: pool,
      token: token,
      winningUrl: probe.winningUrl,
      concurrency: initialConcurrency,
      v1Bps: probe.bps,
      originalThreads: effConcurrency,
      onOrderedChunk: onOrderedChunk,
    );
  }
}

/// 滑动窗口流式下载分块执行器：
///
/// 【滑动窗口调度规则】：
/// 1. 同一时刻在途的 piece 不超过 [limit] 个；全局在途上游连接不超过 maxInFlightSockets (limit + 2)。
/// 2. 只有当 nextFlushIndex 那一块到齐、写出、从缓冲区移除置 null 之后，才发起下一块。
/// 3. 写出即释放：分块写入 Socket 响应流后立刻从 completedPieces 移除，切断引用供 GC 回收。
/// 4. 峰值内存上限严格受控于 concurrency × maxPieceBytes（例如 8 × 512 KiB ≈ 4 MiB，快节点 2 × 512 KiB ≈ 1 MiB）。
/// 5. 容灾降级：单个分块重试失败后绝不断流，安全降级为单连接顺序透传，把剩下的字节完整写下去。
/// 6. 自适应决策：基于同一视频区间首批分块并发聚合吞吐与 v1 比较，判断并发收益是否达到 1.2x，若未达标则在 pool 中降低并发。
class _SlidingWindowStreamer {
  final MultiRangeDownloader downloader;
  final List<RangePiece> pieces;
  final CdnPool pool;
  final CancellationToken token;
  final String winningUrl;
  final double v1Bps;
  final int originalThreads;
  int limit;
  final Future<void> Function(Uint8List chunk) onOrderedChunk;

  final Map<int, Uint8List> _completedPieces = {};
  final Map<int, Object> _failedPieces = {};
  final Map<int, CancellationToken> _inFlightTokens = {};
  final Map<int, int> _inFlightStartTimes = {};
  final Map<int, void Function()> _inFlightHedgeLaunchers = {};
  final Map<int, int> _headOfLineStartTimes = {};
  final Completer<void> _completer = Completer<void>();
  Future<void> _flushChain = Future.value();
  int _nextFlushIndex = 0;
  int _nextLaunchIndex = 0;
  bool _isDegraded = false;
  bool _eofReached = false;
  int _eofIndex = -1;

  // 自适应并发评估状态
  final Stopwatch _sampleSw = Stopwatch();
  int _sampleBytes = 0;
  int _sampleCompleted = 0;
  final int _sampleTarget;
  bool _evaluated = false;

  // 聚合吞吐实时追踪（用于判定 hedge 是否允许，任务 A）
  final List<({int timeMs, int bytes})> _recentTransfers = [];
  int _streamTotalBytes = 0;
  final Stopwatch _streamSw = Stopwatch();
  double _lastEvaluatedAggBps = 0.0;

  bool get isAggregateBelowTarget {
    final targetBps =
        RangeCore.requiredThroughputBytesPerSec(pool.videoBitrateBytesPerSec);
    if (targetBps <= 0) return true;
    final currentBps = getCurrentAggregatedBps();
    return currentBps < targetBps;
  }

  double getCurrentAggregatedBps() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _recentTransfers.removeWhere((t) => now - t.timeMs > 3000);
    if (_recentTransfers.length >= 2) {
      final spanMs = now - _recentTransfers.first.timeMs;
      if (spanMs >= 400) {
        final totalBytes =
            _recentTransfers.fold<int>(0, (sum, t) => sum + t.bytes);
        return totalBytes / (spanMs / 1000.0);
      }
    }
    if (_streamSw.isRunning &&
        _streamSw.elapsedMilliseconds >= 500 &&
        _streamTotalBytes > 0) {
      return _streamTotalBytes / (_streamSw.elapsedMicroseconds / 1000000.0);
    }
    if (_evaluated && _lastEvaluatedAggBps > 0) {
      return _lastEvaluatedAggBps;
    }
    return 0.0;
  }

  _SlidingWindowStreamer({
    required this.downloader,
    required this.pieces,
    required this.pool,
    required this.token,
    required this.winningUrl,
    required int concurrency,
    this.v1Bps = 0.0,
    int? originalThreads,
    required this.onOrderedChunk,
  })  : originalThreads = originalThreads ?? concurrency,
        limit = (pool.adaptiveConcurrency ??
                min(concurrency, RangeCore.maxRampConcurrency))
            .clamp(1, 512),
        _sampleTarget = min(pieces.length, min(concurrency.clamp(1, 512), 4)) {
    if (pool.adaptiveConcurrency != null) {
      limit = pool.adaptiveConcurrency!.clamp(1, 512);
      _evaluated = true;
    }
  }

  bool _switchToSingleConnection = false;

  Future<void> stream() async {
    token.throwIfCancelled();
    if (pieces.isEmpty) return;

    if (pool.isSingleConnectionMode) {
      if (kDebugMode) {
        debugPrint(
          '[BTR] 沿用单连接顺序透传模式: 节点=${BtrLog.hostOf(winningUrl)}, '
          '区间=bytes=${pieces.first.start}-${pieces.last.end}',
        );
      }
      _isDegraded = true;
      await _sequentialPassthrough(
        start: pieces.first.start,
        end: pieces.last.end,
      );
      if (!_completer.isCompleted) {
        _nextFlushIndex = pieces.length;
        _completer.complete();
      }
      return;
    }

    _streamSw.start();
    downloader.setConcurrency(limit);
    if (!_evaluated && _sampleTarget > 0) {
      _sampleSw.start();
    }

    void onCancel() {
      if (!_completer.isCompleted) {
        _abortInFlight();
        _completer.completeError(CancellationException(token.reason));
      }
    }

    token.addListener(onCancel);
    try {
      // 初始发起首批至多 limit 个分块
      _launchNext();

      await _completer.future;
    } finally {
      token.removeListener(onCancel);
      _abortInFlight();
    }
  }

  void _abortInFlight() {
    for (final t in _inFlightTokens.values) {
      t.cancel('Aborted due to fallback degradation');
    }
    _inFlightTokens.clear();
    _inFlightStartTimes.clear();
    _inFlightHedgeLaunchers.clear();
    _headOfLineStartTimes.clear();
  }

  void _abortInFlightAfter(int afterIndex) {
    final toRemove = <int>[];
    for (final entry in _inFlightTokens.entries) {
      if (entry.key > afterIndex) {
        entry.value.cancel('Cancelled due to upstream EOF clipping at piece #$afterIndex');
        toRemove.add(entry.key);
      }
    }
    for (final k in toRemove) {
      _inFlightTokens.remove(k);
      _inFlightStartTimes.remove(k);
      _inFlightHedgeLaunchers.remove(k);
      _headOfLineStartTimes.remove(k);
    }
  }

  void _triggerFlush() {
    if (_completer.isCompleted || token.isCancelled || _isDegraded) return;
    _flushChain = _flushChain.then((_) async {
      if (_completer.isCompleted || token.isCancelled || _isDegraded) return;

      while (!_completer.isCompleted &&
          !_isDegraded &&
          _completedPieces.containsKey(_nextFlushIndex)) {
        token.throwIfCancelled();
        // 写出即释放：从 map 中移除，不再持有强引用供 GC 回收
        final chunk = _completedPieces.remove(_nextFlushIndex)!;
        final flushedIndex = _nextFlushIndex;
        _nextFlushIndex++;

        // 清理已写出块的状态
        _headOfLineStartTimes.remove(flushedIndex);

        // 按序写入下游
        await onOrderedChunk(chunk);

        if (_eofReached && flushedIndex >= _eofIndex) {
          if (!_completer.isCompleted) {
            _completer.complete();
          }
          return;
        }

        // 只有当 _nextFlushIndex 到齐、写出、释放之后，才发起下一块
        _launchNext();
      }

      // 推进完已完成块后，检查新队头块是否需要启动慢块补救
      if (_nextFlushIndex < pieces.length && !_completer.isCompleted && !_isDegraded) {
        _checkHeadOfLineHedge();
      }

      if (_nextFlushIndex >= pieces.length && !_completer.isCompleted) {
        _completer.complete();
        return;
      }

      // 任务 C：并发无收益切换单连接：等待已在途分块写出完毕后，平滑无缝切换单连接顺序透传
      if (_switchToSingleConnection &&
          _inFlightTokens.isEmpty &&
          !_isDegraded &&
          !_completer.isCompleted) {
        _isDegraded = true;
        if (_nextFlushIndex < pieces.length) {
          final remainingStart = pieces[_nextFlushIndex].start;
          final remainingEnd = pieces.last.end;
          if (kDebugMode) {
            debugPrint(
              '[BTR] 并发无收益，平滑无缝切换单连接顺序透传: bytes=$remainingStart-$remainingEnd',
            );
          }
          await _sequentialPassthrough(
            start: remainingStart,
            end: remainingEnd,
          );
        }
        if (!_completer.isCompleted) {
          _nextFlushIndex = pieces.length;
          _completer.complete();
        }
        return;
      }

      // 队头阻塞诊断埋点
      if (!_completer.isCompleted &&
          !_isDegraded &&
          !_completedPieces.containsKey(_nextFlushIndex) &&
          !_failedPieces.containsKey(_nextFlushIndex)) {
        final holStartTime = _headOfLineStartTimes.putIfAbsent(
          _nextFlushIndex,
          () => DateTime.now().millisecondsSinceEpoch,
        );
        final stallMs = DateTime.now().millisecondsSinceEpoch - holStartTime;
        if (stallMs >= pool.slowPieceThreshold.inMilliseconds &&
            _completedPieces.isNotEmpty) {
          BtrLog.rateLimitedLog(
            'head_of_line',
            '[BTR] 队头阻塞 piece#$_nextFlushIndex 停顿 ${(stallMs / 1000).toStringAsFixed(2)}s（在途 ${_inFlightTokens.length} 块，已完成的块数=${_completedPieces.length}）',
          );
        }
      }

      // 关键：若当前等待写出的分块在重试后彻底失败，绝不断流，降级为单连接顺序透传
      if (!_completer.isCompleted &&
          !_isDegraded &&
          _failedPieces.containsKey(_nextFlushIndex)) {
        _isDegraded = true;
        _abortInFlight();

        final failedPiece = pieces[_nextFlushIndex];
        final remainingEnd = pieces.last.end;
        final cause = _failedPieces[_nextFlushIndex];

        pool.singleConnectionSwitchCount++;
        if (kDebugMode) {
          debugPrint(
            '[BTR] 分块 #${failedPiece.index} 重试失败 ($cause)，'
            '降级为对该区间 bytes=${failedPiece.start}-$remainingEnd 的单连接顺序透传'
            '（本视频第 ${pool.singleConnectionSwitchCount} 次切单连接）',
          );
        }

        await _sequentialPassthrough(
          start: failedPiece.start,
          end: remainingEnd,
        );

        if (!_completer.isCompleted) {
          _nextFlushIndex = pieces.length;
          _completer.complete();
        }
      }
    }).catchError((Object err, StackTrace stackTrace) {
      if (!_completer.isCompleted) {
        token.cancel(err);
        _completer.completeError(err, stackTrace);
      }
    });
  }

  void _checkHeadOfLineHedge() {
    if (_completer.isCompleted || token.isCancelled || _isDegraded) return;
    final index = _nextFlushIndex;
    final startTime = _inFlightStartTimes[index];
    if (startTime == null) return;
    final elapsedMs = DateTime.now().millisecondsSinceEpoch - startTime;
    final thresholdMs = pool.slowPieceThreshold.inMilliseconds;
    if (elapsedMs >= thresholdMs) {
      _inFlightHedgeLaunchers[index]?.call();
    } else {
      Timer(Duration(milliseconds: thresholdMs - elapsedMs), () {
        if (_nextFlushIndex == index && !_completedPieces.containsKey(index)) {
          _inFlightHedgeLaunchers[index]?.call();
        }
      });
    }
  }

  void _launchNext() {
    if (token.isCancelled ||
        _completer.isCompleted ||
        _isDegraded ||
        _eofReached ||
        _switchToSingleConnection) {
      return;
    }

    final maxInFlight = limit + RangeCore.defaultMaxInFlightExtra;
    while (_nextLaunchIndex < pieces.length &&
        _nextLaunchIndex < _nextFlushIndex + limit &&
        _inFlightTokens.length < maxInFlight) {
      final index = _nextLaunchIndex++;
      final piece = pieces[index];
      final pieceToken = CancellationToken();
      void onParentCancel() => pieceToken.cancel(token.reason);
      token.addListener(onParentCancel);
      _inFlightTokens[index] = pieceToken;
      _inFlightStartTimes[index] = DateTime.now().millisecondsSinceEpoch;

      downloader.downloadPiece(
        piece: piece,
        pool: pool,
        token: pieceToken,
        preferredUrls: pool.ordered(index),
        startupMode: false,
        // 距离当前 flush 游标越近的分块优先级越高
        priority: max(10, 100 - (index - _nextFlushIndex) * 5),
        isSlowPieceEligible: () => _nextFlushIndex == index,
        isHedgeAllowed: () => isAggregateBelowTarget,
        onHedgeReady: (launcher) {
          _inFlightHedgeLaunchers[index] = launcher;
          if (_nextFlushIndex == index) {
            _checkHeadOfLineHedge();
          }
        },
      ).then((res) {
        token.removeListener(onParentCancel);
        _inFlightTokens.remove(index);
        _inFlightStartTimes.remove(index);
        _inFlightHedgeLaunchers.remove(index);
        if (token.isCancelled || _completer.isCompleted || _isDegraded) return;

        _completedPieces[index] = res.bytes;
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        _recentTransfers.add((timeMs: nowMs, bytes: res.bytes.lengthInBytes));
        _streamTotalBytes += res.bytes.lengthInBytes;

        if (res.actualEnd < piece.end) {
          _eofReached = true;
          _eofIndex = index;
          _abortInFlightAfter(index);
        }

        // 自适应并发评估：在同一区间的首批并发分块完成时计算实际聚合吞吐
        if (!_evaluated && _sampleTarget > 0 && index < _sampleTarget) {
          _sampleBytes += res.bytes.lengthInBytes;
          _sampleCompleted++;
          if (_sampleCompleted >= _sampleTarget) {
            _evaluated = true;
            _sampleSw.stop();
            final durationSec =
                max(0.001, _sampleSw.elapsedMicroseconds / 1000000.0);
            final aggBps = _sampleBytes / durationSec;
            _lastEvaluatedAggBps = aggBps;
            final v1 = v1Bps > 0 ? v1Bps : (pool.getSpeed(winningUrl) ?? 0.0);
            final multiMbps = aggBps / (1024 * 1024);
            final singleMbps = v1 / (1024 * 1024);
            final hasBenefit =
                v1 <= 0 || aggBps >= RangeCore.adaptiveGainThreshold * v1;

            // ⚠️ 切单连接的额外前提（否则在网络抽风/样本过短时按噪声切换，
            //    会把多连接的聚合能力白白丢掉，导致视频流停住、音画不同步）：
            //   ① 单连接自己"够用"（≥ 目标吞吐 = 码率×1.2，或 0.4 MB/s 下限）；
            //      **必须与"切回多连接"用同一个函数取值**，否则门限倒挂会反复横跳。
            //   ② 样本足够可信（时长与字节数都够）。
            final targetBps =
                RangeCore.requiredThroughputBytesPerSec(pool.videoBitrateBytesPerSec);
            final bitrateKnown = pool.videoBitrateBytesPerSec != null &&
                pool.videoBitrateBytesPerSec! > 0;
            final targetMbps = (targetBps / (1024 * 1024)).toStringAsFixed(2);
            BtrLog.rateLimitedLog(
              'mode_criteria',
              '[BTR] 模式判据: 码率已知=$bitrateKnown target=$targetMbps MB/s',
            );

            final singleAdequate = v1 >= targetBps;
            final sampleTrustworthy = durationSec >=
                    RangeCore.minAdaptiveSampleSeconds &&
                _sampleBytes >= RangeCore.minAdaptiveSampleBytes;
            // 任务 A：只有"单连接确实不慢于多连接"才值得切（容差 5%）
            final singleNotWorse =
                v1 >= aggBps * RangeCore.singleNotWorseFactor;

            final canSwitchToSingle = v1 > 0 &&
                !hasBenefit &&
                singleNotWorse &&
                singleAdequate &&
                sampleTrustworthy;

            if (canSwitchToSingle && pool.tryRecordModeSwitch('多连接')) {
              // 任务 A、B、C、D：并发无收益且单连接不慢于多连接，在满足驻留与频率上限前提下切单连接并启用粘性偏好
              pool.singleConnectionSwitchCount++;
              BtrLog.rateLimitedLog(
                'concurrency_no_benefit',
                '[BTR] 并发无收益 → 切单连接（多连接=${multiMbps.toStringAsFixed(2)} MB/s vs 单连接=${singleMbps.toStringAsFixed(2)} MB/s，单连接不慢于多连接=true，单连接够用=true，样本可信=true，本视频第 ${pool.singleConnectionSwitchCount} 次）',
              );
              pool
                ..enableStickySingleConnection(multiBpsAtSwitch: aggBps)
                ..updateSlowPieceThreshold(
                  concurrency: 1,
                  targetBps: targetBps,
                )
                ..lastSingleConnectionSpeedBps = v1;
              _switchToSingleConnection = true;
            } else {
              // ── 并发数反推（小步爬升版，2026-09-20）─────────────────────
              // 旧逻辑「有收益 → 直接开满 limit」会让单连接只有 0.85 MB/s 的节点也开 32 条。
              // 新逻辑：按**实测每条连接吞吐**反推"够用就好"的条数，并且**一次最多爬到
              // maxRampConcurrency（8）**，避免在坏网络里按公式一步顶到配置上限。
              final sampleConcurrency = max(1, _sampleTarget);
              final perConnBps = max(
                aggBps / sampleConcurrency,
                RangeCore.minPerConnectionBps,
              );
              final rampCap = max(
                sampleConcurrency,
                min(RangeCore.maxRampConcurrency, sampleConcurrency * 2),
              );
              final neededForTarget =
                  (targetBps / perConnBps).ceil().clamp(1, rampCap);

              final decidedConcurrency = hasBenefit
                  ? neededForTarget
                  : min(RangeCore.fastNodeConcurrency, limit);

              pool.adaptiveConcurrency = decidedConcurrency;
              if (decidedConcurrency != limit) {
                limit = decidedConcurrency;
                downloader.setConcurrency(decidedConcurrency);
              }

              pool.updateSlowPieceThreshold(
                concurrency: decidedConcurrency,
                targetBps: targetBps,
              );

              final hedgeAllowed = aggBps < targetBps;
              BtrLog.rateLimitedLog(
                'adaptive_concurrency',
                '[BTR] 自适应并发决策: 节点=${BtrLog.hostOf(winningUrl)}, '
                'v1=${singleMbps.toStringAsFixed(2)} MB/s, '
                '并发聚合速度=${multiMbps.toStringAsFixed(2)} MB/s, '
                '每连接=${(perConnBps / (1024 * 1024)).toStringAsFixed(2)} MB/s, '
                '目标=${(targetBps / (1024 * 1024)).toStringAsFixed(2)} MB/s, '
                '目标并发=$decidedConcurrency, '
                '在途=${_inFlightTokens.length}, '
                'hedge=${hedgeAllowed ? "允许" : "跳过"}, '
                '最终并发=$decidedConcurrency, '
                '慢块阈值=${pool.slowPieceThreshold.inMilliseconds}ms '
                '(配置上限=$originalThreads)',
              );
            }
          }
        }

        _triggerFlush();
      }).catchError((Object err, StackTrace stackTrace) {
        token.removeListener(onParentCancel);
        _inFlightTokens.remove(index);
        _inFlightStartTimes.remove(index);
        _inFlightHedgeLaunchers.remove(index);
        if (token.isCancelled || _completer.isCompleted || _isDegraded) return;

        if (err is RangeNotSupportedException || err is UpstreamHttpException) {
          token.cancel(err);
          _completer.completeError(err, stackTrace);
          return;
        }

        // 单个分块重试失败：记录错误，交由 _triggerFlush 在流到该位置时降级为单连接顺序透传
        _failedPieces[index] = err;
        _triggerFlush();
      });
    }
  }

  /// 单连接顺序透传：对指定区间直接拉取上游数据流并按原序写出，绝不跳过任何字节
  Future<void> _sequentialPassthrough({
    required int start,
    required int end,
  }) async {
    token.throwIfCancelled();
    if (start > end) return;

    final candidates = pool.rangeCandidates();
    final urlsToTry = <String>[
      winningUrl,
      ...candidates.where((u) => u != winningUrl),
    ];

    Object? lastError;
    const maxPassthroughRetries = RangeCore.minPieceRetries;
    var currentStart = start;

    for (var attempt = 0; attempt < maxPassthroughRetries; attempt++) {
      token.throwIfCancelled();
      if (currentStart > end) return;
      final url = urlsToTry[attempt % urlsToTry.length];

      if (attempt > 0) {
        await Future.delayed(
          Duration(milliseconds: 150 * (1 << min(attempt - 1, 3))),
        );
        token.throwIfCancelled();
      }

      HttpClientRequest? req;
      void onCancel() {
        try {
          req?.abort();
        } catch (_) {}
      }
      token.addListener(onCancel);

      final release = await downloader.acquireSocket(
        token,
        priority: 150,
        caller: 'passthrough',
      );
      try {
        if (kDebugMode) {
          debugPrint(
            '[BTR] 降级单连接顺序透传启动 (尝试 ${attempt + 1}/$maxPassthroughRetries): '
            'url=${BtrLog.hostOf(url)}, range=bytes=$currentStart-$end'
            '（本视频第 ${pool.singleConnectionSwitchCount} 次切单连接）',
          );
        }

        final uri = Uri.parse(url);
        final cleanUri = Uri(scheme: uri.scheme, host: uri.host, path: uri.path);
        req = await downloader._httpClient.getUrl(uri);
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=$currentStart-$end');
        downloader.defaultHeaders.forEach((k, v) {
          req!.headers.set(k, v);
        });

        final resp = await req.close();
        if (resp.statusCode != HttpStatus.partialContent &&
            resp.statusCode != HttpStatus.ok) {
          if (resp.statusCode >= 400) {
            throw UpstreamHttpException(
              resp.statusCode,
              '降级单连接顺序透传上游返回异常状态码: HTTP ${resp.statusCode}',
              uri: cleanUri,
            );
          }
          throw HttpException(
            '降级单连接顺序透传上游返回异常状态码: HTTP ${resp.statusCode}',
            uri: cleanUri,
          );
        }

        if (resp.statusCode == HttpStatus.ok && currentStart > 0) {
          throw const RangeNotSupportedException(
            '上游不支持 Range 请求 (返回 200 OK 但请求子区间)',
          );
        }

        int intervalBytes = 0;
        final speedSw = Stopwatch()..start();
        // 注：切回多连接的门限已迁移到"粘性单连接"的解除判据里
        // （见本文件粘性单连接解除分支：连续 3 个区间未达 目标×switchBackMargin 才解粘），
        // 这里的局部门限变量已无用途，删除以免误导。
        bool switchedBack = false;

        final completer = Completer<void>();
        StreamSubscription<List<int>>? subscription;
        try {
          subscription = resp.listen(
            (chunk) async {
              if (completer.isCompleted) return;
              subscription?.pause();
              try {
                token.throwIfCancelled();
                final bytes = chunk is Uint8List
                    ? chunk
                    : Uint8List.fromList(chunk);
                final remaining = end - currentStart + 1;
                if (remaining <= 0) {
                  await subscription?.cancel();
                  if (!completer.isCompleted) {
                    completer.complete();
                  }
                  return;
                }
                final toSend = bytes.lengthInBytes <= remaining
                    ? bytes
                    : bytes.sublist(0, remaining);
                currentStart += toSend.lengthInBytes;
                intervalBytes += toSend.lengthInBytes;
                await onOrderedChunk(toSend);

                if (currentStart > end) {
                  await subscription?.cancel();
                  if (!completer.isCompleted) {
                    completer.complete();
                  }
                  return;
                }

                // 每接收约 1MB 或超过 2 秒，评估一次单连接速度
                if (intervalBytes >= 1024 * 1024 ||
                    speedSw.elapsedMilliseconds >= 2000) {
                  final sec =
                      max(0.001, speedSw.elapsedMicroseconds / 1000000.0);
                  final currentBps = intervalBytes / sec;
                  speedSw.reset();
                  intervalBytes = 0;
                  pool.lastSingleConnectionSpeedBps = currentBps;

                  // 任务 B & C：对比式解粘条件（连续 3 个区间满足 currentSingleBps < targetBps × 0.8 且 multiBpsAtSwitch > currentSingleBps × 1.1）
                  final targetBps =
                      RangeCore.requiredThroughputBytesPerSec(pool.videoBitrateBytesPerSec);
                  final bitrateKnown = pool.videoBitrateBytesPerSec != null &&
                      pool.videoBitrateBytesPerSec! > 0;
                  final targetMbps = (targetBps / (1024 * 1024)).toStringAsFixed(2);
                  BtrLog.rateLimitedLog(
                    'mode_criteria',
                    '[BTR] 模式判据: 码率已知=$bitrateKnown target=$targetMbps MB/s',
                  );

                  final unhooked = pool.recordSingleConnectionIntervalThroughput(
                    currentBps,
                    targetBps,
                  );
                  if (unhooked) {
                    final curMbps =
                        (currentBps / (1024 * 1024)).toStringAsFixed(2);
                    final reqMbps =
                        ((targetBps * RangeCore.switchBackMargin) / (1024 * 1024))
                            .toStringAsFixed(2);
                    final multiAtSwitchMbps =
                        (pool.lastMultiBpsAtSwitch / (1024 * 1024))
                            .toStringAsFixed(2);
                    BtrLog.rateLimitedLog(
                      'single_slow_switch_back',
                      '[BTR] 粘性单连接解除（单连接=$curMbps MB/s < 目标×0.8=$reqMbps MB/s 且 切入时多连接=$multiAtSwitchMbps MB/s > 1.1×Z=true，本视频第 ${pool.stickyReleaseCount} 次）',
                    );
                    pool.clearStickySingleConnection();
                    switchedBack = true;
                    await subscription?.cancel();
                    if (!completer.isCompleted) {
                      completer.complete();
                    }
                    return;
                  }
                }
              } catch (e, st) {
                if (!completer.isCompleted) {
                  completer.completeError(e, st);
                }
              } finally {
                if (!switchedBack && !completer.isCompleted) {
                  subscription?.resume();
                }
              }
            },
            onError: (err, st) {
              if (!completer.isCompleted) {
                completer.completeError(err, st);
              }
            },
            onDone: () {
              if (!completer.isCompleted) {
                completer.complete();
              }
            },
            cancelOnError: true,
          );

          await completer.future;
        } finally {
          await subscription?.cancel().catchError((_) {});
        }

        if (switchedBack) {
          final nextStart = currentStart;
          if (nextStart <= end) {
            if (kDebugMode) {
              debugPrint(
                '[BTR] 单连接降速切回多并发: 剩余 bytes=$nextStart-$end',
              );
            }
            final remPieces = RangeCore.splitRange(
              nextStart,
              end,
              maxPieceBytes: RangeCore.defaultMaxPieceBytes,
            );
            if (remPieces.isNotEmpty) {
              final subStreamer = _SlidingWindowStreamer(
                downloader: downloader,
                pieces: remPieces,
                pool: pool,
                token: token,
                winningUrl: winningUrl,
                concurrency: originalThreads,
                v1Bps: 0.0,
                originalThreads: originalThreads,
                onOrderedChunk: onOrderedChunk,
              );
              await subStreamer.stream();
            }
          }
          return;
        }

        if (currentStart > end || resp.statusCode == HttpStatus.ok) {
          if (kDebugMode) {
            debugPrint(
              '[BTR] 降级单连接顺序透传成功完成: 传输 ${currentStart - start} 字节, '
              '区间=bytes=$start-$end',
            );
          }
          return;
        }

        // 若流提前关闭且尚未读完区间，抛出异常触发重试剩余区间
        throw HttpException(
          '降级单连接顺序透传连接过早关闭: 仅收到 ${currentStart - start}/${end - start + 1} 字节',
          uri: cleanUri,
        );
      } catch (e) {
        lastError = e;
        if (token.isCancelled || e is UpstreamHttpException) rethrow;
        if (kDebugMode) {
          debugPrint('[BTR] 降级单连接顺序透传尝试 ${attempt + 1} 失败: $e');
        }
      } finally {
        token.removeListener(onCancel);
        release();
      }
    }

    if (kDebugMode) {
      debugPrint(
        '[BTR] 降级单连接顺序透传所有重试均失败: $lastError, 原因: 上游彻底不可用',
      );
    }
    throw lastError ?? Exception('降级单连接顺序透传失败：上游彻底不可用');
  }
}
