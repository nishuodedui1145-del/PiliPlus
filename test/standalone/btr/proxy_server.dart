import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'stubs.dart';
import 'stubs.dart';
import 'cdn_pool.dart';
import 'cdn_racer.dart';
import 'multi_range_downloader.dart';
import 'range_core.dart';
import 'sidx_parser.dart';
import 'stubs.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;

/// 全局在途 Socket 预算协调器（对齐官方 idm-downloader.js:402-407）
///
/// 画面与声音分开预算，并设置跨请求的全局在途硬上限，避免画面把声音的连接占满。
class GlobalSocketBudget {
  int _videoActive = 0;
  int _audioActive = 0;
  int _rescueActive = 0;

  int _videoLimit = 8;
  int _audioLimit = 2;
  int _rescueLimit = 1;

  int get videoActive => _videoActive;
  int get audioActive => _audioActive;
  int get rescueActive => _rescueActive;
  int get totalActive => _videoActive + _audioActive + _rescueActive;

  int get videoLimit => _videoLimit;
  int get audioLimit => _audioLimit;
  int get rescueLimit => _rescueLimit;
  int get globalLimit => _videoLimit + _audioLimit + _rescueLimit;

  void updateBudget(int concurrency) {
    final b = RangeCore.calculateBudget(concurrency);
    _videoLimit = b.videoBudget;
    _audioLimit = b.audioBudget;
    _rescueLimit = b.rescueReserve;
  }

  void reset() {
    _videoActive = 0;
    _audioActive = 0;
    _rescueActive = 0;
  }
}

/// 本地 BTR HTTP 代理服务器
class BtrProxyServer {
  static final BtrProxyServer instance = BtrProxyServer._();

  HttpServer? _server;
  HttpClient? _httpClient;
  Future<void>? _stopping;
  Future<int>? _starting;
  final Set<CancellationToken> _activeTokens = {};
  final Map<String, CdnPool> _cdnPoolCache = {};
  final Set<String> _rangeUnsupportedUrls = {};
  final Map<String, MultiRangeDownloader> _downloaderCache = {};
  final Map<String, int> _totalLengthCache = {};
  int? _lastConfiguredConcurrency;
  Timer? _scheduledStopTimer;
  final GlobalSocketBudget socketBudget = GlobalSocketBudget();
  final Set<String> _inFlightSidxPrefetches = {};
  int _lastRequestTimestamp = 0;

  final CdnRacer racer = CdnRacer();
  List<String> cdnCandidates = const [];
  bool cdnRaceEnabled = true;
  String? lastSampleUrl;
  String? lastGroup;
  Future<CdnRaceResult?>? _inFlightRace;

  BtrProxyServer._();

  int? get port => _server?.port;
  bool get isRunning => _server != null;

  HttpClient _getOrCreateHttpClient() {
    return _httpClient ??= HttpClient()
      ..idleTimeout = const Duration(seconds: 15)
      ..connectionTimeout = const Duration(seconds: 8);
  }

  /// 延迟停止代理服务器（默认 5 秒）
  ///
  /// 用于页面销毁（如 onClose）时避免立即掐断端口，导致新打开的视频在路由切换期间因旧端口失效而失败；
  /// 期间若收到新的 ensureStarted() 或新的客户端请求，将立即取消定时器。若已有待执行停止，只刷新定时器。
  void scheduleStop({Duration delay = const Duration(seconds: 5)}) {
    _scheduledStopTimer?.cancel();
    if (kDebugMode) {
      debugPrint(
        '[BTR] 代理生命周期: 事件=scheduleStop 端口=${_server?.port ?? 0} 在途=${_activeTokens.length}',
      );
    }
    _scheduledStopTimer = Timer(delay, () {
      _scheduledStopTimer = null;
      stop(force: false);
    });
  }

  /// 取消待执行的延迟停止定时器
  bool _cancelScheduledStop(String reason) {
    if (_scheduledStopTimer != null) {
      _scheduledStopTimer?.cancel();
      _scheduledStopTimer = null;
      if (kDebugMode) {
        debugPrint('[BTR] 代理停止已被新视频取消（延迟停止已撤销）');
        debugPrint(
          '[BTR] 代理生命周期: 事件=cancelStop 端口=${_server?.port ?? 0} 在途=${_activeTokens.length}',
        );
      }
      return true;
    }
    return false;
  }

  /// 确保代理服务已启动，返回监听端口
  Future<int> ensureStarted() async {
    _cancelScheduledStop('ensureStarted');

    if (_stopping != null) {
      await _stopping;
    }

    if (_server != null) {
      return _server!.port;
    }

    if (_starting != null) {
      return _starting!;
    }

    final starting = () async {
      try {
        if (_server != null) {
          return _server!.port;
        }

        // 绑定 127.0.0.1 随机可用端口（port 0 由操作系统自动分配）
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        _server = server;
        server.listen(
          _handleRequest,
          onError: (err) {
            if (kDebugMode) {
              debugPrint('BtrProxyServer error: $err');
            }
          },
        );

        if (kDebugMode) {
          debugPrint('BtrProxyServer started on 127.0.0.1:${server.port}');
          debugPrint(
            '[BTR] 代理生命周期: 事件=start 端口=${server.port} 在途=${_activeTokens.length}',
          );
        }

        return server.port;
      } finally {
        _starting = null;
      }
    }();

    _starting = starting;
    return await starting;
  }

  /// 停止代理服务器并取消所有上游活跃连接
  ///
  /// [force] 为 false 时（默认），若仍有活跃请求或最近 3 秒内有客户端请求，则跳过停止以保护正在播放的新视频；
  /// 优雅收尾时先用 force: false 配合 1 秒超时，超时才回退到 force: true 强掐，避免客户端出现 End of file。
  Future<void> stop({bool force = false}) async {
    _scheduledStopTimer?.cancel();
    _scheduledStopTimer = null;

    if (!force) {
      if (_activeTokens.isNotEmpty) {
        if (kDebugMode) {
          debugPrint(
            '[BTR] 代理停止跳过: 仍有在途请求 (${_activeTokens.length} 个)',
          );
        }
        return;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      if (_lastRequestTimestamp > 0 && now - _lastRequestTimestamp < 3000) {
        if (kDebugMode) {
          debugPrint(
            '[BTR] 代理停止跳过: 最近 ${(now - _lastRequestTimestamp)}ms 内有活跃请求',
          );
        }
        return;
      }
    }

    if (_stopping != null) {
      return _stopping!;
    }
    if (_starting != null) {
      try {
        await _starting;
      } catch (_) {}
    }
    final server = _server;
    if (server == null) {
      resetForNewVideo();
      return;
    }
    _server = null;

    final port = server.port;
    final inFlight = _activeTokens.length;

    final stopping = () async {
      bool forced = false;
      try {
        // 先尝试优雅关闭，给正在传输的响应 1 秒时间正常写完，避免客户端 End of file
        await server.close(force: false).timeout(const Duration(seconds: 1));
      } catch (_) {
        forced = true;
        try {
          await server.close(force: true);
        } catch (e) {
          if (kDebugMode) {
            debugPrint('BtrProxyServer close error: $e');
          }
        }
      } finally {
        resetForNewVideo();
        _stopping = null;
        if (kDebugMode) {
          debugPrint(
            '[BTR] 代理停止: 端口=$port 在途响应=$inFlight 强制=${forced ? '是' : '否'}',
          );
          debugPrint(
            '[BTR] 代理生命周期: 事件=stop 端口=$port 在途=$inFlight',
          );
        }
      }
    }();

    _stopping = stopping;
    return stopping;
  }

  /// 切视频或退出时重置所有活跃请求与缓存，释放复用的 HttpClient 连接池
  void resetForNewVideo() {
    if (kDebugMode) {
      debugPrint(
        '[BTR] 代理生命周期: 事件=reset 端口=${_server?.port ?? 0} 在途=${_activeTokens.length}',
      );
    }
    for (final token in List.of(_activeTokens)) {
      token.cancel('Video reset / page closed');
    }
    _activeTokens.clear();
    for (final pool in _cdnPoolCache.values) {
      pool.clearRacerHint();
    }
    _cdnPoolCache.clear();
    _rangeUnsupportedUrls.clear();
    _downloaderCache.clear();
    _totalLengthCache.clear();
    _lastConfiguredConcurrency = null;
    socketBudget.reset();
    _inFlightSidxPrefetches.clear();
    _httpClient?.close(force: true);
    _httpClient = null;
    _lastRequestTimestamp = 0;
  }

  /// 生成供播放器（如 mpv）请求的本地 URL-safe 代理地址
  ///
  /// 原始目标地址使用 base64url 编码（去除末尾填充字符 '='），以保证其可以安全嵌入 edl:// 协议字符串中
  String buildProxyUrl(
    String originalUrl, {
    int threads = RangeCore.defaultConcurrency,
    String kind = 'video',
    String group = 'auto',
  }) {
    // 防御：非 http(s) 地址（如 edl://）直接放行，不包代理
    if (!originalUrl.startsWith('http://') &&
        !originalUrl.startsWith('https://')) {
      return originalUrl;
    }

    if (kind == 'video') {
      _lastConfiguredConcurrency = threads;
      lastSampleUrl = originalUrl;
      lastGroup = group;
    }

    final serverPort = _server?.port;
    if (serverPort == null) {
      throw StateError('BtrProxyServer is not running. Call ensureStarted() first.');
    }

    final bytes = utf8.encode(originalUrl);
    final encodedUrl = base64Url.encode(bytes).replaceAll('=', '');
    return 'http://127.0.0.1:$serverPort/media?u=$encodedUrl&th=$threads&k=$kind&g=$group';
  }

  /// 解码 base64url 目标地址
  static String _decodeTargetUrl(String encoded) {
    final normalized = base64.normalize(encoded);
    final bytes = base64Url.decode(normalized);
    return utf8.decode(bytes);
  }

  /// 获取当前登录账号的 Cookie 请求头（若已登录）
  static Future<String?> _getLoginCookie() async {
    try {
      final account = Accounts.video.isLogin ? Accounts.video : Accounts.main;
      if (account.isLogin) {
        final cookies = await account.cookieJar.loadForRequest(
          Uri.parse(HttpString.baseUrl),
        );
        if (cookies.isNotEmpty) {
          return cookies.map((c) => '${c.name}=${c.value}').join('; ');
        }
      }
    } catch (_) {}
    return null;
  }

  /// 处理客户端发来的 HTTP 请求（GET / HEAD）
  Future<void> _handleRequest(HttpRequest request) async {
    _cancelScheduledStop('client_request');
    _lastRequestTimestamp = DateTime.now().millisecondsSinceEpoch;

    if (_stopping != null) {
      if (kDebugMode) {
        debugPrint(
          '[BTR] 警告: 在代理停止中收到客户端请求，拒绝处理: path=${request.uri.path}',
        );
      }
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }

    if (request.uri.path != '/media') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    if (request.method != 'GET' && request.method != 'HEAD') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }

    final encodedUrl = request.uri.queryParameters['u'];
    if (encodedUrl == null || encodedUrl.isEmpty) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }

    String targetUrl;
    try {
      targetUrl = _decodeTargetUrl(encodedUrl);
    } catch (e) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }

    if (!targetUrl.startsWith('http://') && !targetUrl.startsWith('https://')) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }

    final threadsParam = int.tryParse(request.uri.queryParameters['th'] ?? '');
    final threads = threadsParam?.clamp(1, 64) ?? RangeCore.defaultConcurrency;
    final kind = request.uri.queryParameters['k'] ?? 'video';

    if (kind == 'video') {
      _lastConfiguredConcurrency = threads;
    }
    final baseC = (kind == 'audio' && _lastConfiguredConcurrency != null)
        ? _lastConfiguredConcurrency!
        : threads;
    final budget = RangeCore.calculateBudget(baseC);
    socketBudget.updateBudget(baseC);
    final allocatedThreads = (kind == 'audio')
        ? budget.audioBudget
        : budget.videoBudget;
    final maxSockets = (kind == 'video')
        ? (budget.videoBudget + budget.rescueReserve)
        : budget.audioBudget;
    BtrLog.rateLimitedLog(
      'budget_allocated_$baseC',
      '[BTR] 预算划分: 视频=${budget.videoBudget}, 音频=${budget.audioBudget}, 预留=${budget.rescueReserve}, 全局上限=${budget.videoBudget + budget.audioBudget + budget.rescueReserve}',
    );

    final token = CancellationToken();
    _activeTokens.add(token);
    bool bytesSent = false;
    Object? requestError;

    // 监听客户端连接是否中断
    request.response.done.then((_) {
      token.cancel('Client finished or closed socket');
      _activeTokens.remove(token);
    }, onError: (err) {
      token.cancel('Client connection closed with error: $err');
      _activeTokens.remove(token);
    });

    final groupParam = request.uri.queryParameters['g'];
    final group = groupParam ?? 'auto';
    if (kind == 'video') {
      lastSampleUrl = targetUrl;
      lastGroup = group;
    }

    final pool = _cdnPoolCache.putIfAbsent(
      targetUrl,
      () => CdnPool(
        originalUrls: [targetUrl],
        // 用户在设置里指定的节点分组偏好（对应官方「CDN 模式」）
        preferredGroup: switch (groupParam) {
          'mainland' => CdnGroup.mainland,
          'overseas' => CdnGroup.overseas,
          _ => null,
        },
      ),
    );

    // CDN 自动竞速调度（只在启用且为 GET 请求时触发；后台异步进行，绝不阻塞起播）
    if (cdnRaceEnabled && request.method == 'GET') {
      if (!pool.hasRacerHint) {
        if (racer.isFresh) {
          final cached = racer.cached!;
          final ageSec =
              (DateTime.now().millisecondsSinceEpoch - cached.measuredAtMs) ~/
                  1000;
          if (kDebugMode) {
            debugPrint(
              '[BTR] CDN 竞速: 复用缓存（测于 $ageSec 秒前）最优=${cached.host}',
            );
          }
          pool.applyRacerHint(cached.host, cached.bytesPerSec);
          if (kDebugMode) {
            debugPrint(
              '[BTR] CDN 竞速: 最优已应用于候选池 host=${cached.host} '
              '估计=${(cached.bytesPerSec / 1048576).toStringAsFixed(2)} MB/s',
            );
          }
        } else {
          // 缓存过期或首次竞速：后台跑竞速（绝不阻塞当前播放）
          _triggerBackgroundRace(
            sampleUrl: targetUrl,
            group: group,
            pool: pool,
          );
        }
      }
    }

    final cookie = await _getLoginCookie();
    final headers = <String, String>{
      HttpHeaders.userAgentHeader: BrowserUa.pc,
      HttpHeaders.refererHeader: '${HttpString.baseUrl}/',
      if (cookie != null && cookie.isNotEmpty) HttpHeaders.cookieHeader: cookie,
      HttpHeaders.acceptHeader: '*/*',
    };

    // E: 复用 HttpClient 与 MultiRangeDownloader 实例
    final client = _getOrCreateHttpClient();
    final initialConcurrency = pool.adaptiveConcurrency ?? allocatedThreads;
    final downloaderKey = '$targetUrl#$kind';
    final downloader = _downloaderCache.putIfAbsent(
      downloaderKey,
      () => MultiRangeDownloader(
        concurrency: initialConcurrency,
        maxInFlightSockets: maxSockets,
        httpClient: client,
        defaultHeaders: headers,
      ),
    )
      ..defaultHeaders = headers
      ..setConcurrency(initialConcurrency, maxInFlightSockets: maxSockets);

    try {
      // 检查是否处于降级直连状态（对齐官方 page-hook.js:140-158 / 1074-1081）
      if (pool.isDirectPassthrough && request.method == 'GET') {
        if (pool.checkRetakeoverEligible()) {
          BtrLog.rateLimitedLog(
            'retakeover_attempt',
            '[BTR] 尝试重接管: host=${BtrLog.hostOf(targetUrl)} 第${pool.retakeoverAttempts}次/${RangeCore.retakeoverMaxAttempts}',
          );
        } else {
          await _passthrough(
            clientRequest: request,
            targetUrl: targetUrl,
            token: token,
            defaultHeaders: headers,
            onByteSent: () => bytesSent = true,
            pool: pool,
            downloader: downloader,
          );
          return;
        }
      }

      // SIDX 缓存查询与后台预取（对齐官方 sidx.js / native-mse-player.js:214-216）
      final urlKey = SidxCache.urlToKey(targetUrl);
      if (request.method == 'GET') {
        final cachedSidx = SidxCache.get(urlKey);
        if (cachedSidx != null) {
          BtrLog.rateLimitedLog(
            'sidx_hit_$urlKey',
            '[BTR] sidx 缓存命中: host=${BtrLog.hostOf(targetUrl)}',
          );
        } else {
          // sidx 只对"可能走流式下载"的请求有用：无 Range，或开放式 Range（bytes=N-）。
          // 封闭 Range（bytes=N-M）由下载器内部等分切片，永远用不到 sidx ——
          // 给它预取就是白扣海外带宽，还会跟正在下载的请求抢连接。
          final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
          final isStreamLike = rangeHeader == null ||
              RegExp(r'^bytes=\d+-$').hasMatch(rangeHeader.trim());
          if (isStreamLike) {
            BtrLog.rateLimitedLog(
              'sidx_miss_$urlKey',
              '[BTR] sidx 缓存未命中: host=${BtrLog.hostOf(targetUrl)}',
            );
            _prefetchSidx(
              targetUrl: targetUrl,
              defaultHeaders: headers,
              pool: pool,
            );
          }
        }
      }

      // 任务 B：粘性单连接偏好命中（该视频多连接已判亏，直接单连接启动）
      if (pool.hasStickySingleConnection && request.method == 'GET') {
        if (kDebugMode) {
          debugPrint(
            '[BTR] 粘性单连接命中（该视频多连接已判亏，直接单连接启动）: '
            'host=${BtrLog.hostOf(targetUrl)}',
          );
        }
        await _passthrough(
          clientRequest: request,
          targetUrl: targetUrl,
          token: token,
          defaultHeaders: headers,
          onByteSent: () => bytesSent = true,
          pool: pool,
          downloader: downloader,
        );
        return;
      }

      // 若已知该 URL 的上游不支持 Range，直接走单连接顺序透传
      // B & C: 统一 close 责任，_passthrough 内不 close，由外层 finally 统一关闭
      if (_rangeUnsupportedUrls.contains(targetUrl)) {
        pool.singleConnectionSwitchCount++;
        if (kDebugMode) {
          debugPrint(
            '[BTR] 上游已确认不支持 Range，直接单连接顺序透传: ${BtrLog.hostOf(targetUrl)}'
            '（本视频第 ${pool.singleConnectionSwitchCount} 次切单连接）',
          );
        }
        await _passthrough(
          clientRequest: request,
          targetUrl: targetUrl,
          token: token,
          defaultHeaders: headers,
          onByteSent: () => bytesSent = true,
          pool: pool,
          downloader: downloader,
        );
        return;
      }

      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      final httpRange = RangeCore.parseRangeHeader(rangeHeader);

      // A & D：处理 HEAD 请求，优先发真正 upstream HEAD 探测且开放式 Range 保留 end 为 null
      if (request.method == 'HEAD') {
        int? totalLength = _totalLengthCache[targetUrl];
        int headEnd = 0;
        if (totalLength == null) {
          try {
            totalLength = await downloader.probeHeadFast(
              pool: pool,
              token: token,
              rangeHeader: rangeHeader,
            );
          } on UpstreamHttpException {
            rethrow;
          } catch (_) {}

          if (totalLength == null) {
            final probe = await downloader.probeHead(
              start: httpRange?.start ?? 0,
              end: httpRange?.end, // D: 保持可空，不写死为 start
              pool: pool,
              token: token,
            );
            totalLength = probe.totalLength;
            headEnd = probe.headEnd;
          }
          if (totalLength != null) {
            _totalLengthCache[targetUrl] = totalLength;
          }
        }

        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        request.response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');

        if (httpRange != null) {
          if (totalLength != null && httpRange.start >= totalLength) {
            request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
            request.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes */$totalLength',
            );
            return;
          }

          final requestedEnd = httpRange.end;
          final int effectiveEnd;
          if (requestedEnd != null) {
            effectiveEnd =
                totalLength != null ? min(requestedEnd, totalLength - 1) : requestedEnd;
          } else {
            effectiveEnd = totalLength != null ? totalLength - 1 : headEnd;
          }
          final contentLength = effectiveEnd - httpRange.start + 1;

          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes ${httpRange.start}-$effectiveEnd/${totalLength ?? '*'}',
          );
          request.response.headers.set(
            HttpHeaders.contentLengthHeader,
            contentLength,
          );
        } else {
          request.response.statusCode = HttpStatus.ok;
          if (totalLength != null) {
            request.response.headers.set(
              HttpHeaders.contentLengthHeader,
              totalLength,
            );
          }
        }
        return; // 由外层唯一 finally 统一关闭
      }

      // 处理 GET 请求（有 Range、开放式 Range 及全量无 Range 均统一调度）
      int? totalLength = _totalLengthCache[targetUrl];
      final start = httpRange?.start ?? 0;
      int? requestedEnd = httpRange?.end;

      // 若已有缓存 totalLength，提前做 416 校验与 end clamp
      if (totalLength != null && httpRange != null && start >= totalLength) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */$totalLength',
        );
        return;
      }
      if (totalLength != null && requestedEnd != null && requestedEnd >= totalLength) {
        requestedEnd = totalLength - 1;
      }

      // ⚠️ probeHead 内部要跑"启动测速 + 取首块"，慢网络下可能超过 4~5 秒，
      // 而 ffmpeg 读响应头的超时就在这个量级 —— 一旦超时客户端直接报
      // "Could not open source file"，表现为「加载卡死/失败」（真机 04:21 日志）。
      // 所以给它一个硬上限：超时就**先把响应头发出去**，再用纯数据透传补数据；
      // 只有拿到明确的上游错误状态（HttpException 等）才如实上报。
      StartupProbeResult? probeMaybe;
      try {
        probeMaybe = await downloader
            .probeHead(
              start: start,
              end: requestedEnd,
              pool: pool,
              token: token,
            )
            .timeout(RangeCore.firstResponseDeadline);
      } on TimeoutException {
        probeMaybe = null;
      }

      if (probeMaybe == null) {
        // 首响应超时，判定加速不可行，记录降级直连状态（对齐官方 page-hook.js:1074-1081 / 140-158）
        pool.markDirectFallback('首响应超时');

        // ⚠️ Dart HttpServer 的响应头**只有在写入至少 1 字节 body 时才会真正发出**
        // （PC 实测：只 flush() / bufferOutput=false + add(空) 都一个字节也发不出去）。
        // 所以这里用一个「1 字节 Range」把响应头顶出去：1 字节请求几乎只受 RTT 影响，
        // 慢节点也能在几百毫秒内返回；随后再继续补流。
        final primer = await _fetchPrimerByte(
          targetUrl: targetUrl,
          start: start,
          defaultHeaders: headers,
          token: token,
          pool: pool,
        );
        final primerBytes = primer.bytes;
        // 顶头响应里带 Content-Range: bytes N-N/总长度 —— 顺手把总长度拿回来。
        // 有总长度就能回**精确的 206**，播放器才不会因为"不知道文件多大"而 seek 失败
        // （真机 14:50 出现 Seek failed (to 3490, size -38) 的循环，就是因为 200 无长度）。
        final resolvedTotal =
            primer.total ?? totalLength ?? _totalLengthCache[targetUrl];
        if (resolvedTotal != null && resolvedTotal > 0) {
          _totalLengthCache[targetUrl] = resolvedTotal;
        }
        final nextOffset = start + primerBytes.length;

        if (resolvedTotal != null && resolvedTotal > 0) {
          // ── 知道总长度：回 206 + Content-Range + Content-Length（保住 seek）──
          final end = (requestedEnd ?? (resolvedTotal - 1)).clamp(
            start,
            resolvedTotal - 1,
          );
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
          request.response.headers.set(
            HttpHeaders.contentTypeHeader,
            'video/mp4',
          );
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/$resolvedTotal',
          );
          request.response.headers.set(
            HttpHeaders.contentLengthHeader,
            '${end - start + 1}',
          );
          if (primerBytes.isNotEmpty) {
            request.response.add(primerBytes);
          }
          await request.response.flush();
          bytesSent = true;
          if (kDebugMode) {
            debugPrint(
              '[BTR] 首响应超时（>${RangeCore.firstResponseDeadline.inMilliseconds}ms）'
              '→ 用 ${primerBytes.length} 字节顶出响应头（206 精确区间 '
              'bytes=$start-$end/$resolvedTotal）: 节点=${BtrLog.hostOf(targetUrl)}',
            );
          }
          await _streamDirect(
            clientRequest: request,
            targetUrl: targetUrl,
            token: token,
            defaultHeaders: headers,
            fromOffset: nextOffset,
            endOffset: end,
            onByteSent: () => bytesSent = true,
            downloader: downloader,
          );
          return; // 外层 finally 统一关闭
        }

        // ── 拿不到总长度：只能退化成 200（此时播放器的 seek 会受限）──
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        request.response.headers.set(
          HttpHeaders.contentTypeHeader,
          'video/mp4',
        );
        if (primerBytes.isNotEmpty) {
          request.response.add(primerBytes);
        }
        await request.response.flush();
        bytesSent = true;
        if (kDebugMode) {
          debugPrint(
            '[BTR] 首响应超时（>${RangeCore.firstResponseDeadline.inMilliseconds}ms）'
            '→ 用 ${primerBytes.length} 字节顶出响应头（总长度未知，退化为 200）: '
            '节点=${BtrLog.hostOf(targetUrl)}',
          );
          debugPrint(
            '[BTR] 顶头续流: start=$start 已写=${primerBytes.length} 续流起点=$nextOffset '
            '来源=${BtrLog.hostOf(targetUrl)}',
          );
        }
        await _streamDirect(
          clientRequest: request,
          targetUrl: targetUrl,
          token: token,
          defaultHeaders: headers,
          fromOffset: nextOffset,
          onByteSent: () => bytesSent = true,
          downloader: downloader,
        );
        return; // 外层 finally 统一关闭
      }
      final StartupProbeResult probe = probeMaybe;

      if (totalLength == null && probe.totalLength != null) {
        totalLength = probe.totalLength;
        _totalLengthCache[targetUrl] = probe.totalLength!;
      }

      if (totalLength != null && httpRange != null && start >= totalLength) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */$totalLength',
        );
        return;
      }

      final int effectiveEnd;
      if (requestedEnd != null) {
        effectiveEnd =
            totalLength != null ? min(requestedEnd, totalLength - 1) : requestedEnd;
      } else {
        effectiveEnd = totalLength != null ? totalLength - 1 : probe.headEnd;
      }
      final contentLength = effectiveEnd - start + 1;

      // 基于单连接实测速度与并发聚合吞吐进行自适应并发决策（已在 pool 记录则复用）
      final int adaptiveConcurrency;
      if (pool.isSingleConnectionMode) {
        adaptiveConcurrency = 1;
        if (kDebugMode) {
          debugPrint(
            '[BTR] 复用单连接模式: 节点=${BtrLog.hostOf(probe.winningUrl)} (并发无收益)',
          );
        }
      } else if (pool.adaptiveConcurrency != null) {
        adaptiveConcurrency = pool.adaptiveConcurrency!;
        if (kDebugMode) {
          debugPrint(
            '[BTR] 自适应并发复用: 节点=${BtrLog.hostOf(probe.winningUrl)}, '
            '已选并发=$adaptiveConcurrency (配置上限=$allocatedThreads)',
          );
        }
      } else {
        // 起播阶段：通过 startupConcurrencyTiers 决定起播并发起手值（对齐官方 native-mse-player.js:365-369）
        final requiredBps = RangeCore.requiredThroughputBytesPerSec(
            pool.videoBitrateBytesPerSec);
        final ratio = (requiredBps > 0 && probe.bps > 0)
            ? (probe.bps / requiredBps)
            : 0.0;
        int tierConcurrency = allocatedThreads;
        for (final tier in RangeCore.startupConcurrencyTiers) {
          if (ratio >= tier.$1) {
            tierConcurrency = min(tier.$2, allocatedThreads);
            break;
          }
        }
        adaptiveConcurrency = max(1, tierConcurrency);
        pool.adaptiveConcurrency = adaptiveConcurrency;
        BtrLog.rateLimitedLog(
          'startup_tier_${targetUrl.hashCode}',
          '[BTR] 起播并发起手值: ratio=${ratio.toStringAsFixed(2)} '
          '-> 并发=$adaptiveConcurrency (配置上限=$allocatedThreads)',
        );
      }

      // 设置客户端响应状态与头
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      request.response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');

      if (httpRange != null) {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$effectiveEnd/${totalLength ?? '*'}',
        );
        request.response.headers.set(
          HttpHeaders.contentLengthHeader,
          contentLength,
        );
      } else {
        request.response.statusCode = HttpStatus.ok;
        if (totalLength != null) {
          request.response.headers.set(
            HttpHeaders.contentLengthHeader,
            totalLength,
          );
        }
      }

      // 先把探测到的 head 数据按序写出给客户端
      request.response.add(probe.headBytes);
      await request.response.flush();
      bytesSent = true;

      // 若处于重接管中且成功发送数据，恢复加速状态
      if (pool.isDirectPassthrough) {
        pool.onRetakeoverSuccess(BtrLog.hostOf(targetUrl));
      }

      // 若 probe.headBytes 覆盖头部，且 sidx 尚未解析，解析并加入缓存
      if (SidxCache.get(urlKey) == null && probe.headStart == 0) {
        final parsed = SidxParser.parseSidx(probe.headBytes, 0);
        if (parsed != null && parsed.segments.isNotEmpty) {
          SidxCache.put(urlKey, parsed);
        }
      }

      // 无 Range 和开放式 Range 统一采用流式下载（按 sidx 分段边界或回退等分）
      if (probe.headEnd < effectiveEnd) {
        final remainingStart = probe.headEnd + 1;
        List<RangePiece>? pieces;
        final sidx = SidxCache.get(urlKey);
        if (sidx != null && sidx.segments.isNotEmpty) {
          final sidxPieces = SidxParser.planSegmentAlignedPieces(
            sidx.segments,
            remainingStart,
            effectiveEnd,
            maxPieceBytes: RangeCore.defaultMaxPieceBytes,
          );
          if (sidxPieces.isNotEmpty) {
            pieces = sidxPieces;
            BtrLog.rateLimitedLog(
              'sidx_plan_$urlKey',
              '[BTR] 按分段边界规划 ${pieces.length} 段: host=${BtrLog.hostOf(targetUrl)}',
            );
          }
        }
        if (pieces == null || pieces.isEmpty) {
          BtrLog.rateLimitedLog(
            'sidx_fallback_$urlKey',
            '[BTR] sidx 不可用 → 回退等分: host=${BtrLog.hostOf(targetUrl)}',
          );
          pieces = RangeCore.splitRange(
            remainingStart,
            effectiveEnd,
            maxPieceBytes: RangeCore.defaultMaxPieceBytes,
          );
        }

        if (pieces.isNotEmpty) {
          final effectiveV1 = probe.bps > 0
              ? probe.bps
              : (pool.getSpeed(probe.winningUrl) ?? 0.0);

          await downloader.streamPieces(
            pieces: pieces,
            pool: pool,
            token: token,
            winningUrl: probe.winningUrl,
            concurrency: adaptiveConcurrency,
            v1Bps: effectiveV1,
            originalThreads: allocatedThreads,
            onOrderedChunk: (chunk) async {
              request.response.add(chunk);
              await request.response.flush();
              bytesSent = true;
            },
          );
        }
      }
    } on RangeNotSupportedException catch (e) {
      if (bytesSent) {
        requestError = e;
        token.cancel(e);
        if (kDebugMode) {
          debugPrint('[BTR] 响应已发送部分数据后检测到不支持 Range ($e)，中止连接');
        }
      } else {
        // 识别上游不支持/忽略 Range，标记降级直连（对齐官方 page-hook.js:1074-1081）
        // ⚠️ 官方那个 3500ms 宽限期必须做成"时间戳"，**不能在这里 await**：
        //    本函数在请求路径里，任何延迟都会直接变成播放器侧 3.5 秒的卡顿。
        //    宽限期已计入 CdnPool.markDirectFallback 的首个重接管延迟。
        pool.markDirectFallback('上游不支持或忽略Range');
        _rangeUnsupportedUrls.add(targetUrl);
        pool.singleConnectionSwitchCount++;
        if (kDebugMode) {
          debugPrint(
            '[BTR] 上游不支持或忽略 Range ($e)，降级为单连接顺序透传: ${BtrLog.hostOf(targetUrl)}'
            '（本视频第 ${pool.singleConnectionSwitchCount} 次切单连接）',
          );
        }
        try {
          await _passthrough(
            clientRequest: request,
            targetUrl: targetUrl,
            token: token,
            defaultHeaders: headers,
            onByteSent: () => bytesSent = true,
            pool: pool,
            downloader: downloader,
          );
        } catch (pe) {
          requestError = pe;
          token.cancel(pe);
          if (!bytesSent) {
            final statusCode = _extractStatusCode(pe);
            try {
              request.response.statusCode = statusCode;
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      requestError = e;
      token.cancel(e);
      if (kDebugMode) {
        debugPrint('BtrProxyServer request error: $e');
      }
      if (!bytesSent) {
        final statusCode = _extractStatusCode(e);
        try {
          request.response.statusCode = statusCode;
        } catch (_) {}
      }
    } finally {
      // 统一唯一 close 责任处，彻底消除 double-close
      _activeTokens.remove(token);
      if (requestError != null && bytesSent) {
        if (kDebugMode) {
          debugPrint('[BTR] 传输过程中出错，中止连接: $requestError');
        }
        try {
          final socket = await request.response.detachSocket(writeHeaders: false);
          socket.destroy();
        } catch (_) {
          try {
            await request.response.close();
          } catch (_) {}
        }
      } else {
        try {
          await request.response.close();
        } catch (_) {}
      }
    }
  }

  void _triggerBackgroundRace({
    required String sampleUrl,
    required String group,
    required CdnPool pool,
  }) {
    if (_inFlightRace != null) return;
    final candidates = cdnCandidates.isNotEmpty
        ? cdnCandidates
        : (group == 'overseas' ? CdnPool.overseasHosts : CdnPool.mainlandHosts);

    final future = racer.raceThroughput(
      candidates: candidates,
      sampleUrl: sampleUrl,
      group: group,
      bannedHosts: pool.banList.bannedHosts,
    );
    _inFlightRace = future;

    unawaited(() async {
      try {
        final result = await future;
        if (result != null) {
          pool.applyRacerHint(result.host, result.bytesPerSec);
          if (kDebugMode) {
            debugPrint(
              '[BTR] CDN 竞速: 最优已应用于候选池 host=${result.host} '
              '估计=${(result.bytesPerSec / 1048576).toStringAsFixed(2)} MB/s',
            );
          }
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[BTR] CDN 竞速后台异常: $e');
        }
      } finally {
        _inFlightRace = null;
      }
    }());
  }

  void _prefetchSidx({
    required String targetUrl,
    required Map<String, String> defaultHeaders,
    required CdnPool pool,
  }) {
    final urlKey = SidxCache.urlToKey(targetUrl);
    if (SidxCache.get(urlKey) != null || _inFlightSidxPrefetches.contains(urlKey)) {
      return;
    }
    _inFlightSidxPrefetches.add(urlKey);

    unawaited(() async {
      try {
        final client = _getOrCreateHttpClient();
        final uri = Uri.parse(targetUrl);
        final req = await client.openUrl('GET', uri);
        req
          ..followRedirects = true
          ..maxRedirects = 5;
        defaultHeaders.forEach((k, v) {
          req.headers.set(k, v);
        });
        // 预取前 256 KiB（足够覆盖 ftyp + moov + sidx；官方在 MSE 层也只取 init+sidx，
        // 这里从 2 MiB 收窄：预取同样要走海外链路，多取的每一个字节都在跟播放抢带宽）
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-262143');

        final resp =
            await req.close().timeout(const Duration(milliseconds: 4000));
        if (resp.statusCode == HttpStatus.partialContent ||
            resp.statusCode == HttpStatus.ok) {
          final builder = BytesBuilder(copy: false);
          await for (final chunk in resp) {
            builder.add(chunk);
            if (builder.length >= 256 * 1024) break;
          }
          final bytes = builder.takeBytes();
          if (bytes.isNotEmpty) {
            final sidx = SidxParser.parseSidx(bytes, 0);
            if (sidx != null && sidx.segments.isNotEmpty) {
              SidxCache.put(urlKey, sidx);
              BtrLog.log(
                '[BTR] sidx 预取解析成功: host=${BtrLog.hostOf(targetUrl)}, 分段数=${sidx.segments.length}',
              );
            }
          }
        } else {
          await resp.drain<void>().catchError((_) {});
        }
      } catch (e) {
        // 预取失败绝不影响正常播放
        BtrLog.rateLimitedLog(
          'sidx_prefetch_err',
          '[BTR] sidx 后台预取跳过: host=${BtrLog.hostOf(targetUrl)} ($e)',
        );
      } finally {
        _inFlightSidxPrefetches.remove(urlKey);
      }
    }());
  }

  /// 清除所有当前池的 racerHint（当用户关闭竞速设置时调用）
  void clearAllRacerHints() {
    for (final pool in _cdnPoolCache.values) {
      pool.clearRacerHint();
    }
  }

  /// 立即手动重新竞速（快设面板「立即重新竞速」按钮调用）
  Future<CdnRaceResult?> rerace() async {
    final sample = lastSampleUrl;
    if (sample == null || sample.isEmpty) {
      return null;
    }
    final group = lastGroup ?? 'auto';
    final candidates = cdnCandidates.isNotEmpty
        ? cdnCandidates
        : (group == 'overseas' ? CdnPool.overseasHosts : CdnPool.mainlandHosts);

    try {
      final res = await racer.raceThroughput(
        candidates: candidates,
        sampleUrl: sample,
        group: group,
        ignoreHysteresis: true,
      );
      if (res != null) {
        for (final pool in _cdnPoolCache.values) {
          pool.applyRacerHint(res.host, res.bytesPerSec);
        }
        if (kDebugMode) {
          debugPrint(
            '[BTR] CDN 竞速: 最优已应用于候选池 host=${res.host} '
            '估计=${(res.bytesPerSec / 1048576).toStringAsFixed(2)} MB/s',
          );
        }
      }
      return res;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[BTR] 手动重新竞速失败: $e');
      }
      return null;
    }
  }

  static int _extractStatusCode(Object error) {
    if (error is UpstreamHttpException) {
      return error.statusCode;
    }
    if (error is HttpException) {
      final match = RegExp(r'HTTP\s+(\d{3})').firstMatch(error.message);
      if (match != null) {
        final code = int.tryParse(match.group(1)!);
        if (code != null && code >= 400 && code <= 599) {
          return code;
        }
      }
    }
    return 502;
  }

  /// 单连接顺序透传降级：直接将原始 URL 的响应流按原样转发给客户端（不带并发）
  /// 注意：内部不调用 clientRequest.response.close()，由外层 finally 统一负责关闭
  Future<void> _passthrough({
    required HttpRequest clientRequest,
    required String targetUrl,
    required CancellationToken token,
    required Map<String, String> defaultHeaders,
    void Function()? onByteSent,
    CdnPool? pool,
    MultiRangeDownloader? downloader,
  }) async {
    token.throwIfCancelled();
    final release = downloader != null
        ? await downloader.acquireSocket(token, priority: 150, caller: 'proxy_passthrough')
        : null;
    final uri = Uri.parse(targetUrl);
    final client = _getOrCreateHttpClient();

    HttpClientRequest? upstreamReq;
    void onCancel() {
      try {
        upstreamReq?.abort();
      } catch (_) {}
    }
    token.addListener(onCancel);

    try {
      upstreamReq = await client.openUrl(clientRequest.method, uri);
      defaultHeaders.forEach((k, v) {
        upstreamReq!.headers.set(k, v);
      });

      final clientRange = clientRequest.headers.value(HttpHeaders.rangeHeader);
      if (clientRange != null) {
        upstreamReq.headers.set(HttpHeaders.rangeHeader, clientRange);
      }

      final upstreamResp = await upstreamReq.close();
      clientRequest.response.statusCode = upstreamResp.statusCode;

      for (final headerName in [
        HttpHeaders.contentTypeHeader,
        HttpHeaders.contentLengthHeader,
        HttpHeaders.contentRangeHeader,
        HttpHeaders.acceptRangesHeader,
        HttpHeaders.cacheControlHeader,
        'etag',
        HttpHeaders.lastModifiedHeader,
      ]) {
        final val = upstreamResp.headers.value(headerName);
        if (val != null) {
          clientRequest.response.headers.set(headerName, val);
        }
      }

      if (clientRequest.method == 'HEAD') {
        return;
      }

      int intervalBytes = 0;
      final speedSw = Stopwatch()..start();
      final targetBps = RangeCore.requiredThroughputBytesPerSec(
        pool?.videoBitrateBytesPerSec,
      );
      if (pool != null) {
        final bitrateKnown = pool.videoBitrateBytesPerSec != null &&
            pool.videoBitrateBytesPerSec! > 0;
        final targetMbps = (targetBps / (1024 * 1024)).toStringAsFixed(2);
        BtrLog.rateLimitedLog(
          'mode_criteria',
          '[BTR] 模式判据: 码率已知=$bitrateKnown target=$targetMbps MB/s',
        );
      }

      await for (final chunk in upstreamResp) {
        token.throwIfCancelled();
        clientRequest.response.add(chunk);
        await clientRequest.response.flush();
        onByteSent?.call();
        intervalBytes += chunk.length;

        if (intervalBytes >= 1024 * 1024 ||
            speedSw.elapsedMilliseconds >= 2000) {
          final sec = max(0.001, speedSw.elapsedMicroseconds / 1000000.0);
          final currentBps = intervalBytes / sec;
          speedSw.reset();
          intervalBytes = 0;
          if (pool != null) {
            pool.lastSingleConnectionSpeedBps = currentBps;
            final unhooked = pool.recordSingleConnectionIntervalThroughput(
              currentBps,
              targetBps,
            );
            if (unhooked) {
              final curMbps = (currentBps / (1024 * 1024)).toStringAsFixed(2);
              final reqMbps =
                  ((targetBps * RangeCore.switchBackMargin) / (1024 * 1024))
                      .toStringAsFixed(2);
              final multiAtSwitchMbps =
                  (pool.lastMultiBpsAtSwitch / (1024 * 1024))
                      .toStringAsFixed(2);
              BtrLog.rateLimitedLog(
                'proxy_single_slow_switch_back',
                '[BTR] 粘性单连接解除（单连接=$curMbps MB/s < 目标×0.8=$reqMbps MB/s 且 切入时多连接=$multiAtSwitchMbps MB/s > 1.1×Z=true，本视频第 ${pool.stickyReleaseCount} 次）',
              );
            }
          }
        }
      }
    } catch (e) {
      token.cancel(e);
      rethrow;
    } finally {
      token.removeListener(onCancel);
      release?.call();
    }
  }

  /// 只取 1 个字节（`Range: bytes=N-N`）用于"顶出响应头"：
  /// 1 字节请求几乎只受 RTT 影响，慢节点也能很快返回；拿不到就抛异常，
  /// 由外层按上游错误处理（如实回错误状态，不退化成假 200）。
  Future<({Uint8List bytes, int? total})> _fetchPrimerByte({
    required String targetUrl,
    required int start,
    required Map<String, String> defaultHeaders,
    required CancellationToken token,
    CdnPool? pool,
  }) async {
    token.throwIfCancelled();
    final client = _getOrCreateHttpClient();
    final req = await client.openUrl('GET', Uri.parse(targetUrl));
    defaultHeaders.forEach((k, v) {
      req.headers.set(k, v);
    });
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$start');
    final resp = await req.close().timeout(RangeCore.primerFetchTimeout);
    if (resp.statusCode >= 400) {
      throw UpstreamHttpException(resp.statusCode, '首字节探测请求失败');
    }
    // 顺手把总长度捞回来（Content-Range: bytes N-N/总长度）：
    // 有它才能给播放器回精确的 206，否则 mpv 会 Seek failed（size 未知）。
    int? total;
    final contentRange = resp.headers.value(HttpHeaders.contentRangeHeader);
    if (contentRange != null) {
      final slash = contentRange.lastIndexOf('/');
      if (slash > 0) {
        final tail = contentRange.substring(slash + 1).trim();
        if (tail.isNotEmpty && tail != '*') {
          final parsed = int.tryParse(tail);
          if (parsed != null && parsed > 0) {
            total = parsed;
            pool?.checkTotalLengthConsistency(total, BtrLog.hostOf(targetUrl));
          }
        }
      }
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in resp) {
      builder.add(chunk);
    }
    return (bytes: builder.takeBytes(), total: total);
  }

  /// 已发送响应头之后的"纯数据"透传（probeHead 超时兜底路径专用）：
  /// 只把上游 body 原样写出，**不再动响应头**（头已经 flush 出去了，
  /// 再设一次会抛 StateError）。
  Future<void> _streamDirect({
    required HttpRequest clientRequest,
    required String targetUrl,
    required CancellationToken token,
    required Map<String, String> defaultHeaders,
    int? fromOffset,
    int? endOffset,
    void Function()? onByteSent,
    MultiRangeDownloader? downloader,
  }) async {
    token.throwIfCancelled();
    final release = downloader != null
        ? await downloader.acquireSocket(token, priority: 150, caller: 'stream_direct')
        : null;
    final uri = Uri.parse(targetUrl);
    final client = _getOrCreateHttpClient();

    HttpClientRequest? upstreamReq;
    void onCancel() {
      try {
        upstreamReq?.abort();
      } catch (_) {}
    }
    token.addListener(onCancel);

    // 已经给客户端声明了 Content-Length 时，**绝不能多写一个字节**
    // （上游有时不严格按 Range 裁剪，会多给数据 → 写成超出长度会破坏响应）
    final maxBytes = (endOffset != null && fromOffset != null)
        ? (endOffset - fromOffset + 1)
        : null;
    var written = 0;

    try {
      upstreamReq = await client.openUrl(clientRequest.method, uri);
      defaultHeaders.forEach((k, v) {
        upstreamReq!.headers.set(k, v);
      });
      if (fromOffset != null) {
        upstreamReq.headers.set(HttpHeaders.rangeHeader, 'bytes=$fromOffset-');
      } else {
        final clientRange = clientRequest.headers.value(HttpHeaders.rangeHeader);
        if (clientRange != null) {
          upstreamReq.headers.set(HttpHeaders.rangeHeader, clientRange);
        }
      }
      final upstreamResp = await upstreamReq.close();
      if (upstreamResp.statusCode >= 400) {
        throw UpstreamHttpException(
          upstreamResp.statusCode,
          '已发送响应头后上游仍返回错误',
        );
      }
      await for (final chunk in upstreamResp) {
        token.throwIfCancelled();
        var data = chunk;
        if (maxBytes != null) {
          final remaining = maxBytes - written;
          if (remaining <= 0) break;
          if (data.length > remaining) {
            data = data.sublist(0, remaining);
          }
        }
        clientRequest.response.add(data);
        await clientRequest.response.flush();
        written += data.length;
        onByteSent?.call();
      }
    } finally {
      token.removeListener(onCancel);
      release?.call();
    }
  }
}
