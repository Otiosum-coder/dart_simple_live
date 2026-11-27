import 'dart:async';

import 'package:simple_live_core/src/common/core_log.dart';
import 'package:simple_live_core/src/common/log_sanitizer.dart';
import 'package:web_socket_channel/io.dart';

typedef WebSocketChannelFactory =
    IOWebSocketChannel Function(
      String url, {
      Duration? connectTimeout,
      Map<String, dynamic>? headers,
    });

enum SocketStatus { connected, failed, closed }

class WebScoketUtils {
  SocketStatus status = SocketStatus.closed;

  /// 链接
  final String url;

  /// 备用链接
  final String? backupUrl;

  /// 心跳时间
  final int heartBeatTime;

  /// 接收到信息
  final Function(dynamic)? onMessage;

  /// 连接关闭
  final Function(String msg)? onClose;

  /// 尝试重连
  final Function()? onReconnect;

  /// 准备就绪
  final Function()? onReady;

  /// 心跳
  final Function()? onHeartBeat;

  /// 请求头
  Map<String, dynamic>? headers;
  final WebSocketChannelFactory _channelFactory;
  final Duration reconnectDelay;

  WebScoketUtils({
    required this.url,
    required this.heartBeatTime,
    this.onMessage,
    this.onClose,
    this.onReconnect,
    this.onReady,
    this.onHeartBeat,
    this.headers,
    this.backupUrl,
    WebSocketChannelFactory? channelFactory,
    this.reconnectDelay = const Duration(seconds: 5),
  }) : _channelFactory = channelFactory ?? IOWebSocketChannel.connect;

  IOWebSocketChannel? webSocket;
  Timer? heartBeatTimer;

  /// 重连次数（收到消息后复位，显式 connect 开始新的重连预算）
  int reconnectTime = 0;
  Timer? reconnectTimer;

  /// 最大重连次数；0 用于由平台自己控制重试的发送连接。
  int maxReconnectTime = 5;

  StreamSubscription<dynamic>? streamSubscription;
  bool _closed = true;
  int _generation = 0;
  bool _usingBackup = false;

  bool _isCurrent(int generation) => !_closed && generation == _generation;

  bool _owns(int generation, IOWebSocketChannel? channel) =>
      _isCurrent(generation) && identical(webSocket, channel);

  /// An explicit request may reopen a closed wrapper. Automatic retries only
  /// enter through the generation-guarded, one-shot reconnect timer below.
  void connect({bool retry = false}) {
    reconnectTime = 0;
    _closed = false;
    _beginAttempt(retry: retry);
  }

  void _beginAttempt({bool retry = false}) {
    final generation = ++_generation;
    _clearTransport();
    _usingBackup = retry && backupUrl != null && backupUrl!.isNotEmpty;
    final wsurl = _usingBackup ? backupUrl! : url;
    unawaited(_connect(generation, wsurl));
  }

  Future<void> _connect(int generation, String wsurl) async {
    IOWebSocketChannel? channel;
    try {
      channel = _channelFactory(
        wsurl,
        connectTimeout: const Duration(seconds: 10),
        headers: headers,
      );
      if (!_isCurrent(generation)) {
        _closeChannel(channel);
        return;
      }
      webSocket = channel;
      final current = channel;
      // A failed handshake also emits a stream error. Listen before awaiting
      // ready so that error is observed, then deduplicate both failure paths.
      streamSubscription = current.stream.listen(
        (data) {
          if (_owns(generation, current)) receiveMessage(data);
        },
        onError: (Object error, StackTrace stack) {
          if (_owns(generation, current)) {
            _handleError(generation, current, error);
          }
        },
        onDone: () {
          if (_owns(generation, current)) _handleDone(generation, current);
        },
      );
      CoreLog.d("WS连接中：${LogSanitizer.url(wsurl)}");
      await current.ready;
      if (!_owns(generation, current)) return;
      CoreLog.d("WS已连接：${LogSanitizer.url(wsurl)}");
      ready();
    } catch (error) {
      if (_owns(generation, channel)) {
        _handleError(generation, channel, error);
      }
    }
  }

  /// 连接完成
  void ready() {
    final generation = _generation;
    final channel = webSocket;
    if (channel == null ||
        !_owns(generation, channel) ||
        status == SocketStatus.connected) {
      return;
    }
    status = SocketStatus.connected;
    _invokeCallback(() => onReady?.call());
    // onReady may synchronously stop this socket or start another attempt.
    if (_owns(generation, channel)) initHeartBeat();
  }

  void initHeartBeat() {
    final generation = _generation;
    final channel = webSocket;
    if (channel == null ||
        !_owns(generation, channel) ||
        status != SocketStatus.connected) {
      return;
    }
    heartBeatTimer?.cancel();
    heartBeatTimer = Timer.periodic(Duration(milliseconds: heartBeatTime), (
      timer,
    ) {
      if (!_owns(generation, channel)) {
        timer.cancel();
        return;
      }
      _invokeCallback(() => onHeartBeat?.call());
    });
  }

  void receiveMessage(dynamic data) {
    if (_closed) return;
    // 接受到一条信息才算重连成功。
    reconnectTime = 0;
    _invokeCallback(() => onMessage?.call(data));
  }

  void onError(dynamic error, dynamic stack) {
    if (!_closed) _handleError(_generation, webSocket, error);
  }

  void _handleError(int generation, IOWebSocketChannel? channel, Object error) {
    if (!_owns(generation, channel)) return;
    final retryBackup = !_usingBackup;
    final nextGeneration = ++_generation;
    _clearTransport();
    status = SocketStatus.failed;
    CoreLog.d("WS错误：${LogSanitizer.text(error)}");
    _invokeCallback(() => onClose?.call(error.toString()));
    if (_isCurrent(nextGeneration)) {
      _scheduleReconnect(retry: retryBackup);
    }
  }

  void onDone() {
    final channel = webSocket;
    if (channel != null && !_closed) _handleDone(_generation, channel);
  }

  void _handleDone(int generation, IOWebSocketChannel channel) {
    if (!_owns(generation, channel)) return;
    final nextGeneration = ++_generation;
    _clearTransport();
    _invokeCallback(() => onReconnect?.call());
    if (_isCurrent(nextGeneration)) _scheduleReconnect();
  }

  void sendMessage(dynamic message) {
    final channel = webSocket;
    if (_closed || status != SocketStatus.connected || channel == null) return;
    final generation = _generation;
    try {
      channel.sink.add(message);
    } catch (error) {
      _handleError(generation, channel, error);
    }
  }

  void close() {
    _closed = true;
    _generation++;
    _clearTransport();
  }

  /// Detach identities before calling channel code: cancellation and close may
  /// synchronously complete a stream or fail asynchronously.
  void _clearTransport() {
    status = SocketStatus.closed;
    final subscription = streamSubscription;
    final channel = webSocket;
    streamSubscription = null;
    webSocket = null;
    reconnectTimer?.cancel();
    reconnectTimer = null;
    heartBeatTimer?.cancel();
    heartBeatTimer = null;
    if (subscription != null) {
      try {
        _observe(subscription.cancel());
      } catch (error) {
        _logBoundaryError(error);
      }
    }
    if (channel != null) _closeChannel(channel);
  }

  void _closeChannel(IOWebSocketChannel channel) {
    try {
      _observe(channel.sink.close());
    } catch (error) {
      _logBoundaryError(error);
    }
  }

  void reconnect() {
    if (_closed || reconnectTimer != null) return;
    _generation++;
    _clearTransport();
    _scheduleReconnect();
  }

  void _scheduleReconnect({bool retry = false}) {
    if (_closed || reconnectTimer != null) return;
    if (reconnectTime >= maxReconnectTime) {
      CoreLog.d("WS重连超过最大次数，断开：${LogSanitizer.url(url)}");
      close();
      _invokeCallback(() => onClose?.call("重连超过最大次数，与服务器断开连接"));
      return;
    }
    reconnectTime++;
    final generation = _generation;
    reconnectTimer = Timer(reconnectDelay, () {
      if (!_isCurrent(generation)) return;
      reconnectTimer = null;
      _beginAttempt(retry: retry);
    });
  }

  void _invokeCallback(dynamic Function() callback) {
    try {
      final result = callback();
      if (result is Future) _observe(result);
    } catch (error) {
      _logBoundaryError(error);
    }
  }

  void _observe(Future<dynamic> future) {
    unawaited(
      future.then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {
          _logBoundaryError(error);
        },
      ),
    );
  }

  void _logBoundaryError(Object error) {
    CoreLog.d("WS回调/清理失败：${LogSanitizer.text(error)}");
  }
}
