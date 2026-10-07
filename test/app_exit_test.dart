import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_nb_net/flutter_net.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oasx/api/backend_exit_client.dart';
import 'package:oasx/service/app_exit_service.dart';

class ExitHarness {
  ExitHarness({bool preview = false, Duration? timeout}) {
    service = AppExitService(
      minimizeToTray: () => minimize,
      trayAvailable: () => trayReady,
      stopBackendOnExit: () => stopOnExit,
      backendAddress: () => address,
      hideWindow: () async => events.add('hide'),
      closeFrontend: () async => events.add('close'),
      stopBackend: (target) async {
        events.add('stop:$target');
        await stop?.call();
      },
      resolveStopFailure: (target, error) async {
        events.add('failure:$target');
        lastError = error;
        return await decision?.call() ?? choice;
      },
      preview: preview,
      shutdownTimeout: timeout ?? const Duration(seconds: 1),
    );
  }

  late AppExitService service;
  bool minimize = false;
  bool trayReady = false;
  bool stopOnExit = false;
  String address = 'http://127.0.0.1:22392';
  final events = <String>[];
  Future<void> Function()? stop;
  Future<ExitFailureChoice> Function()? decision;
  ExitFailureChoice choice = ExitFailureChoice.keepOpen;
  Object? lastError;
}

class ExitHttpAdapter implements HttpClientAdapter {
  ExitHttpAdapter({this.body = '"success"', this.status = 200});
  final String body;
  final int status;
  final requests = <RequestOptions>[];
  bool closed = false;
  bool canceled = false;
  Completer<ResponseBody>? gate;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    cancelFuture?.then((_) => canceled = true);
    if (gate != null) return gate!.future;
    return ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
        if (status == 302)
          'location': ['http://127.0.0.1:22288/home/kill_server'],
      },
    );
  }

  @override
  void close({bool force = false}) => closed = true;
}

void main() {
  group('explicit app exit lifecycle', () {
    test('off closes frontend without touching a backend', () async {
      final h = ExitHarness();
      expect(await h.service.requestExit(), AppExitResult.exited);
      expect(h.events, ['close']);
    });

    test('on awaits shutdown acknowledgment before frontend exit', () async {
      final h = ExitHarness()..stopOnExit = true;
      final gate = Completer<void>();
      h.stop = () => gate.future;
      final exit = h.service.requestExit();
      expect(h.events, ['stop:${h.address}']);
      gate.complete();
      expect(await exit, AppExitResult.exited);
      expect(h.events, ['stop:${h.address}', 'close']);
    });

    test(
      'window close only hides when the tray is actually available',
      () async {
        final h = ExitHarness()
          ..minimize = true
          ..trayReady = true
          ..stopOnExit = true;
        expect(await h.service.requestExit(), AppExitResult.hiddenToTray);
        expect(h.events, ['hide']);
      },
    );

    test(
      'tray unavailable falls back to actual exit with the toggle',
      () async {
        final h = ExitHarness()
          ..minimize = true
          ..stopOnExit = true;
        expect(await h.service.requestExit(), AppExitResult.exited);
        expect(h.events, ['stop:${h.address}', 'close']);
      },
    );

    test('tray disabled ignores a stale visible icon', () async {
      final h = ExitHarness()..trayReady = true;
      expect(await h.service.requestExit(), AppExitResult.exited);
      expect(h.events, ['close']);
    });

    test('tray Exit bypasses hide and uses the same shutdown toggle', () async {
      final h = ExitHarness()
        ..minimize = true
        ..trayReady = true
        ..stopOnExit = true;
      expect(await h.service.requestExit(fromTray: true), AppExitResult.exited);
      expect(h.events, ['stop:${h.address}', 'close']);
    });

    test('tray Exit with toggle off leaves backend alone', () async {
      final h = ExitHarness()
        ..minimize = true
        ..trayReady = true;
      await h.service.requestExit(fromTray: true);
      expect(h.events, ['close']);
    });

    test('duplicate close events join one pending shutdown', () async {
      final h = ExitHarness()..stopOnExit = true;
      final gate = Completer<void>();
      h.stop = () => gate.future;
      final first = h.service.requestExit();
      final second = h.service.requestExit(fromTray: true);
      expect(identical(first, second), true);
      gate.complete();
      await Future.wait([first, second]);
      await h.service.requestExit();
      expect(h.events, ['stop:${h.address}', 'close']);
    });

    test(
      'failure retains frontend until the user explicitly chooses',
      () async {
        final h = ExitHarness()..stopOnExit = true;
        h.stop = () async => throw StateError('offline');
        final gate = Completer<ExitFailureChoice>();
        final shown = Completer<void>();
        h.decision = () {
          shown.complete();
          return gate.future;
        };
        final first = h.service.requestExit();
        await shown.future;
        final second = h.service.requestExit(fromTray: true);
        expect(identical(first, second), true);
        expect(h.events, ['stop:${h.address}', 'failure:${h.address}']);
        gate.complete(ExitFailureChoice.keepOpen);
        expect(await first, AppExitResult.keptOpen);
      },
    );

    test('keep-open failure can be retried with a new snapshot', () async {
      final h = ExitHarness()..stopOnExit = true;
      h.stop = () async => throw StateError('offline');
      expect(await h.service.requestExit(), AppExitResult.keptOpen);
      h.address = 'http://127.0.0.1:22400';
      h.stop = null;
      expect(await h.service.requestExit(), AppExitResult.exited);
      expect(h.events, [
        'stop:http://127.0.0.1:22392',
        'failure:http://127.0.0.1:22392',
        'stop:http://127.0.0.1:22400',
        'close',
      ]);
    });

    test(
      'front-only failure choice closes without a second stop request',
      () async {
        final h = ExitHarness()
          ..stopOnExit = true
          ..choice = ExitFailureChoice.exitFrontendOnly;
        h.stop = () async => throw StateError('offline');
        expect(await h.service.requestExit(), AppExitResult.exited);
        expect(h.events, [
          'stop:${h.address}',
          'failure:${h.address}',
          'close',
        ]);
      },
    );

    test(
      'timeout offers failure choice and late completion cannot close UI',
      () async {
        final h = ExitHarness(timeout: const Duration(milliseconds: 10))
          ..stopOnExit = true;
        final gate = Completer<void>();
        h.stop = () => gate.future;
        expect(await h.service.requestExit(), AppExitResult.keptOpen);
        expect(h.lastError, isA<TimeoutException>());
        gate.complete();
        await Future<void>.delayed(Duration.zero);
        expect(h.events, ['stop:${h.address}', 'failure:${h.address}']);
      },
    );

    test(
      'snapshot preserves the chosen target if settings change mid-exit',
      () async {
        final h = ExitHarness()..stopOnExit = true;
        final gate = Completer<void>();
        h.stop = () => gate.future;
        final exit = h.service.requestExit();
        h.address = 'http://127.0.0.1:22288';
        h.stopOnExit = false;
        gate.completeError(StateError('offline'));
        expect(await exit, AppExitResult.keptOpen);
        expect(h.events, [
          'stop:http://127.0.0.1:22392',
          'failure:http://127.0.0.1:22392',
        ]);
      },
    );

    test(
      'preview never stops any backend even when the toggle is on',
      () async {
        for (final target in [
          'http://127.0.0.1:22289',
          'http://127.0.0.1:22391',
        ]) {
          final h = ExitHarness(preview: true)
            ..stopOnExit = true
            ..address = target;
          await h.service.requestExit(fromTray: true);
          expect(h.events, ['close']);
        }
      },
    );

    test('creating the coordinator does not implicitly stop anything', () {
      final h = ExitHarness()..stopOnExit = true;
      expect(h.events, isEmpty);
    });
  });

  group('isolated shutdown transport (no live network)', () {
    test(
      'uses exact snapshot target, no redirects or global client base URL',
      () async {
        final adapter = ExitHttpAdapter();
        final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:22288'))
          ..httpClientAdapter = adapter;
        await BackendExitClient(
          dio: dio,
          preview: false,
        ).stop('127.0.0.1:22392');
        expect(adapter.requests, hasLength(1));
        final request = adapter.requests.single;
        expect(
          request.uri.toString(),
          'http://127.0.0.1:22392/home/kill_server',
        );
        expect(request.method, 'GET');
        expect(request.followRedirects, false);
        expect(adapter.closed, true);
      },
    );

    test(
      'preview guard blocks all requests including fixture shutdown',
      () async {
        final adapter = ExitHttpAdapter();
        final dio = Dio()..httpClientAdapter = adapter;
        await BackendExitClient(
          dio: dio,
          preview: true,
        ).stop('127.0.0.1:22391');
        expect(adapter.requests, isEmpty);
      },
    );

    test(
      'rejects HTTP 200 without the mainline success acknowledgment',
      () async {
        final adapter = ExitHttpAdapter(body: '{"detail":"login required"}');
        final dio = Dio()..httpClientAdapter = adapter;
        await expectLater(
          BackendExitClient(dio: dio, preview: false).stop('127.0.0.1:22392'),
          throwsStateError,
        );
        expect(adapter.closed, true);
      },
    );

    test('a redirect cannot forward shutdown to another backend', () async {
      final adapter = ExitHttpAdapter(status: 302);
      final dio = Dio()..httpClientAdapter = adapter;
      await expectLater(
        BackendExitClient(dio: dio, preview: false).stop('127.0.0.1:22392'),
        throwsA(isA<DioException>()),
      );
      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.single.followRedirects, false);
    });

    test('transport timeout cancels and closes its dedicated client', () async {
      final adapter = ExitHttpAdapter()..gate = Completer<ResponseBody>();
      final dio = Dio()..httpClientAdapter = adapter;
      await expectLater(
        BackendExitClient(
          dio: dio,
          preview: false,
          timeout: const Duration(milliseconds: 10),
        ).stop('127.0.0.1:22392'),
        throwsA(isA<TimeoutException>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(adapter.closed, true);
      expect(adapter.canceled, true);
      adapter.gate!.complete(ResponseBody.fromString('"success"', 200));
    });

    test('validates addresses without falling back to a default backend', () {
      for (final target in [
        '',
        'file:///server',
        'http://user@127.0.0.1:22392',
        'http://127.0.0.1:22392?forward=other',
        'http://127.0.0.1:22392#other',
      ]) {
        expect(
          () => BackendExitClient.shutdownUri(target),
          throwsFormatException,
        );
      }
      expect(
        BackendExitClient.shutdownUri(
          'https://example.invalid/oas/',
        ).toString(),
        'https://example.invalid/oas/home/kill_server',
      );
    });
  });
}
