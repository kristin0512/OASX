part of 'websocket_service.dart';

typedef MessageListener = void Function(dynamic message);

enum WsStatus {
  /// prepare to connect ws
  connecting,

  /// ws connected
  connected,

  /// ws closed but try to connect
  reconnecting,

  /// ws closed
  closed,

  /// ws error but may also connected
  error,
}

class WebSocketClient {
  final String name;
  final String url;

  WebSocketChannel? _channel;
  final List<MessageListener> _listeners = [];
  final ChannelConnector _connector;
  Timer? _reconnectTimer;
  int _connectionGeneration = 0;
  bool _shouldReconnect = true;
  int _reconnectCount = 0;
  static const int maxReconnect = 5;
  final status = WsStatus.connecting.obs;

  WebSocketClient({
    required this.name,
    required this.url,
    ChannelConnector? connector,
  }) : _connector = connector ?? WebSocketChannel.connect;

  void send(String data) {
    if (status.value == WsStatus.connected) {
      _channel?.sink.add(data);
    } else {
      printInfo(info: "[$name] cannot send, status=${status.value}");
    }
  }

  /// 发送消息收到第一条消息就立马返回,超时返回null
  Future<T?> sendAndWaitOnce<T>(
    String data, {
    T Function(dynamic msg)? onResult,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    return sendAndWaitUntil(
      data,
      check: (msg) async => true,
      onResult: onResult,
      timeout: timeout,
    );
  }

  /// 发送消息等到check条件满足返回收到的消息,超时返回null
  /// [onResult] 自定义转换返回结果,默认直接返回收到消息
  Future<T?> sendAndWaitUntil<T>(
    String data, {
    required Future<bool> Function(dynamic msg) check,
    T Function(dynamic msg)? onResult,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final completer = Completer<T?>();

    late MessageListener tmpListener;
    tmpListener = (msg) async {
      try {
        if (await check(msg) && !completer.isCompleted) {
          if (onResult != null) {
            completer.complete(onResult(msg));
          } else {
            completer.complete(msg);
          }
          _removeListener(tmpListener);
        }
      } catch (e) {
        // check 抛错忽略
      }
    };

    _addListener(tmpListener);
    send(data);

    // 超时处理
    Future.delayed(timeout, () {
      if (!completer.isCompleted) {
        completer.complete(null);
        _removeListener(tmpListener);
      }
    });

    return completer.future;
  }

  /// process url and connect websocket
  Future<void> _connect() async {
    if (!_shouldReconnect) return;
    final generation = ++_connectionGeneration;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    try {
      status.value = WsStatus.connecting;
      var address = url;
      if (address.contains('http://')) {
        address = address.replaceAll('http://', '');
      }
      printInfo(info: "ws[$name] connecting to $address");
      final channel = _connector(Uri.parse(address));
      _channel = channel;
      await channel.ready;
      if (!_shouldReconnect || generation != _connectionGeneration) {
        await channel.sink.close(
          WebSocketStatus.normalClosure,
          'stale connection',
        );
        return;
      }

      status.value = WsStatus.connected;
      _reconnectCount = 0;
      printInfo(info: "ws[$name] connected!");

      channel.stream.listen(
        (msg) {
          if (!_shouldReconnect || generation != _connectionGeneration) return;
          for (final listener in List.from(_listeners)) {
            listener(msg);
          }
        },
        onDone: () {
          if (generation == _connectionGeneration) _reconnect();
        },
        onError: (e) {
          if (!_shouldReconnect || generation != _connectionGeneration) return;
          printError(info: "ws[$name] error: $e");
          status.value = WsStatus.error;
          _reconnect();
        },
      );
    } on SocketException {
      if (!_shouldReconnect || generation != _connectionGeneration) return;
      printError(info: "ws[$name] SocketException: $url");
      status.value = WsStatus.error;
      _reconnect();
    } on Exception catch (e) {
      if (!_shouldReconnect || generation != _connectionGeneration) return;
      printError(info: "ws[$name] Exception: $e");
      status.value = WsStatus.error;
      _reconnect();
    }
  }

  WebSocketClient _addListener(MessageListener? listener) {
    if (listener != null && !_listeners.contains(listener)) {
      _listeners.add(listener);
      printInfo(info: "ws[$name] listener added");
    }
    return this;
  }

  void _removeListener(MessageListener listener) {
    _listeners.remove(listener);
    printInfo(info: "ws[$name] listener removed");
  }

  /// close websocket and clear message listeners
  /// reconnect(optional): default false to stop reconnect websocket
  Future<void> _close(int code, String reason, {bool reconnect = false}) async {
    _shouldReconnect = reconnect;
    ++_connectionGeneration;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final channel = _channel;
    _channel = null;
    status.value = WsStatus.closed;
    _listeners.clear();
    try {
      await channel?.sink.close(code, reason);
    } catch (e) {
      printError(info: 'ws[$name] close error: $e');
    }
    printInfo(info: "ws[$name] closed: $reason");
  }

  /// reconnect webSocket when should reconnect. interval 2s
  void _reconnect() {
    if (!_shouldReconnect) {
      printInfo(info: "ws[$name] reconnect, but forbid to reconnect");
      status.value = WsStatus.closed;
      return;
    }
    if (_reconnectTimer?.isActive == true) return;
    _reconnectCount++;
    if (_reconnectCount > maxReconnect) {
      printInfo(
        info: "ws[$name] reconnect failed more than $maxReconnect times",
      );
      status.value = WsStatus.error;
      return;
    }
    printInfo(info: "ws[$name] reconnecting... ($_reconnectCount)");
    status.value = WsStatus.reconnecting;
    _reconnectTimer = Timer(const Duration(seconds: 2), () {
      _reconnectTimer = null;
      if (_shouldReconnect) _connect();
    });
  }
}
