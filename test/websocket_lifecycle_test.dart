import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:oasx/service/profile_service.dart';
import 'package:oasx/service/websocket_service.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class MemorySink implements WebSocketSink {
  final sent = <dynamic>[];
  int closeCount = 0;
  Completer<void>? closeGate;

  @override
  void add(dynamic data) => sent.add(data);

  @override
  Future<void> close([int? code, String? reason]) async {
    closeCount++;
    await closeGate?.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MemoryChannel implements WebSocketChannel {
  final incoming = StreamController<dynamic>();
  final readyGate = Completer<void>();
  @override
  final MemorySink sink = MemorySink();

  MemoryChannel({bool ready = true}) {
    if (ready) readyGate.complete();
  }

  @override
  Future<void> get ready => readyGate.future;
  @override
  Stream<dynamic> get stream => incoming.stream;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() => Get.testMode = true);
  tearDown(() async => Get.reset());

  test(
    'preview replaces arbitrary websocket endpoints with the fixture',
    () async {
      final addresses = <Uri>[];
      final sockets = WebSocketService(
        connector: (uri) {
          addresses.add(uri);
          return MemoryChannel();
        },
      );
      await sockets.connect(
        name: 'account',
        url: 'ws://127.0.0.1:22288/ws/account',
      );
      expect(addresses.single.host, '127.0.0.1');
      expect(addresses.single.port, 22391);
      await sockets.closeAll();
    },
    skip: !ProfileService.isPreview,
  );

  testWidgets('closing after disconnect cancels pending reconnect', (
    tester,
  ) async {
    final channels = <MemoryChannel>[];
    final sockets = WebSocketService(
      connector: (_) {
        final channel = MemoryChannel();
        channels.add(channel);
        return channel;
      },
    );
    final client = await sockets.connect(
      name: 'account',
      url: 'ws://example.invalid/ws/account',
    );
    await channels.single.incoming.close();
    await tester.pump();
    expect(client.status.value, WsStatus.reconnecting);
    await sockets.close('account');
    await tester.pump(const Duration(seconds: 3));
    expect(channels, hasLength(1));
    expect(client.status.value, WsStatus.closed);
  });

  testWidgets('late handshake cannot revive a detached socket', (tester) async {
    final channel = MemoryChannel(ready: false);
    final sockets = WebSocketService(connector: (_) => channel);
    final connecting = sockets.connect(
      name: 'account',
      url: 'ws://example.invalid/ws/account',
    );
    await sockets.closeAll();
    channel.readyGate.complete();
    final client = await connecting;
    await tester.pump(const Duration(seconds: 3));
    expect(client.status.value, WsStatus.closed);
    expect(channel.sink.closeCount, greaterThanOrEqualTo(1));
    await sockets.send('account', 'start');
    expect(channel.sink.sent, isEmpty);
  });

  testWidgets(
    'same account on another port cannot reuse the old socket',
    (tester) async {
      final addresses = <Uri>[];
      final channels = <MemoryChannel>[];
      final sockets = WebSocketService(
        connector: (uri) {
          addresses.add(uri);
          final channel = MemoryChannel();
          channels.add(channel);
          return channel;
        },
      );
      await sockets.connect(
        name: 'account',
        url: 'ws://127.0.0.1:22288/ws/account',
      );
      await sockets.send('account', 'get_state');
      await sockets.connect(
        name: 'account',
        url: 'ws://127.0.0.1:22289/ws/account',
      );
      await sockets.send('account', 'start');
      expect(addresses.map((uri) => uri.port), [22288, 22289]);
      expect(channels.first.sink.closeCount, 1);
      expect(channels.first.sink.sent, ['get_state']);
      expect(channels.last.sink.sent, ['start']);
      await sockets.closeAll();
    },
    skip: ProfileService.isPreview,
  );

  testWidgets('detach during replacement does not open a new connection', (
    tester,
  ) async {
    final channels = <MemoryChannel>[];
    final sockets = WebSocketService(
      connector: (_) {
        final channel = MemoryChannel();
        channels.add(channel);
        return channel;
      },
    );
    await sockets.connect(
      name: 'account',
      url: 'ws://example.invalid/ws/account',
    );
    final gate = Completer<void>();
    channels.single.sink.closeGate = gate;
    final replacing = sockets.connect(
      name: 'account',
      url: 'ws://example.invalid/ws/account',
      force: true,
    );
    await sockets.closeAll();
    gate.complete();
    final client = await replacing;
    expect(channels, hasLength(1));
    expect(client.status.value, WsStatus.closed);
    await tester.pump(const Duration(seconds: 3));
    expect(channels, hasLength(1));
  });
}
