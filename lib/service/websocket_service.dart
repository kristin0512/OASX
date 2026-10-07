import 'dart:async';
import 'dart:io';
import 'package:get/get.dart';
import 'package:oasx/api/api_client.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:oasx/service/profile_service.dart';

part 'websocket_client.dart';

typedef ChannelConnector = WebSocketChannel Function(Uri uri);

class WebSocketService extends GetxService {
  final Map<String, WebSocketClient> _clients = {};
  final ChannelConnector _connector;
  int _lifecycleGeneration = 0;

  WebSocketService({ChannelConnector? connector})
    : _connector = connector ?? WebSocketChannel.connect;

  /// connect to webSocket
  /// name: scriptName
  /// url(optional): webSocket url, if it is null, it will change to 'ws://${ApiClient().address}/ws/$name'
  /// listener(optional): webSocket message listener. it will add to ws listeners, message broadcast to all listeners
  /// force(optional): Although ws already opened, it will force connect to ws.Deal some ws problems(opened, but error)
  /// return: WebSocketClient. can send message
  Future<WebSocketClient> connect({
    required String name,
    String? url,
    MessageListener? listener,
    bool force = false,
  }) async {
    final generation = _lifecycleGeneration;
    if (url == null) {
      final backend = Uri.parse(ApiClient().address);
      final normalized = backend.hasScheme
          ? backend
          : Uri.parse('http://${ApiClient().address}');
      url = normalized
          .replace(
            scheme: normalized.scheme == 'https' ? 'wss' : 'ws',
            path: '/ws/$name',
            query: '',
          )
          .toString();
    }
    if (ProfileService.isPreview) {
      url = 'ws://${ProfileService.previewAddress}/ws/$name';
    }
    final existing = _clients[name];
    if (!force &&
        existing != null &&
        existing.url == url &&
        existing.status.value != WsStatus.closed &&
        existing.status.value != WsStatus.error) {
      return existing._addListener(listener);
    }
    if (existing != null) {
      await close(name, reconnect: false);
    }
    final client = WebSocketClient(
      name: name,
      url: url,
      connector: _connector,
    )._addListener(listener);
    if (generation != _lifecycleGeneration) {
      await client._close(WebSocketStatus.normalClosure, 'service detached');
      return client;
    }
    _clients[name] = client;
    await client._connect();
    return client;
  }

  /// use manager sends message to script socket
  Future<void> send(String name, String message) async {
    final client = _clients[name];
    if (client != null) {
      client.send(message);
    } else {
      printInfo(info: "ws[$name] want to send, but not connected");
    }
  }

  /// use WebSocketClient to close webSocket and remove this client
  Future<void> close(
    String name, {
    int code = WebSocketStatus.normalClosure,
    String reason = "normal close",
    bool reconnect = false,
  }) async {
    final client = _clients.remove(name);
    if (client != null) {
      await client._close(code, reason, reconnect: reconnect);
    }
    printInfo(info: "ws[$name] closed");
  }

  Future<void> closeAll() async {
    ++_lifecycleGeneration;
    final clients = _clients.values.toList();
    _clients.clear();
    await Future.wait(
      clients.map(
        (client) =>
            client._close(WebSocketStatus.normalClosure, "global close"),
      ),
    );
    printInfo(info: "ws all closed");
  }

  @override
  void onClose() {
    unawaited(closeAll());
    super.onClose();
  }

  void removeAllListeners(String name) {
    final client = _clients[name];
    if (client != null) {
      client._listeners.clear();
    }
    printInfo(info: "ws[$name] listeners removed");
  }
}
