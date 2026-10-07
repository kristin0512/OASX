import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_nb_net/flutter_net.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oasx/api/api_client.dart';
import 'package:oasx/api/config_transfer_models.dart';
import 'package:oasx/service/profile_service.dart';

class _NoNetwork extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      throw StateError('No backend may be contacted');
}

class _TransferAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  int exportStatus = 200;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final capability = options.path.endsWith('capabilities');
    return ResponseBody.fromString(
      jsonEncode(
        capability
            ? {
                'version': 1,
                'max_bytes': configTransferMaxBytes,
                'modes': ['backup', 'share'],
                'config_import': true,
                'task_import': true,
              }
            : exportStatus == 200
            ? {
                'chess': {
                  'scheduler': {'enable': false},
                },
              }
            : {
                'detail': {
                  'message': '参数不合法',
                  'fields': ['chess.scheduler.enable'],
                },
              },
      ),
      capability ? 200 : exportStatus,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ApiClient api;
  late _TransferAdapter adapter;
  setUpAll(() async {
    HttpOverrides.global = _NoNetwork();
    root = await Directory.systemTemp.createTemp('oasx-transfer-transport-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    await ProfileService.initialize(projectDirectory: root);
    api = ApiClient();
    adapter = _TransferAdapter();
    NetOptions.instance.dio.httpClientAdapter = adapter;
  });
  tearDownAll(() async {
    NetOptions.instance.dio.close(force: true);
    HttpOverrides.global = null;
    // GetStorage keeps its portable file lock open until the test isolate exits.
    // This directory is disposable test data, never the real portable profile.
  });
  setUp(() {
    adapter.requests.clear();
    adapter.exportStatus = 200;
  });

  test(
    'binary JSON survives actual interceptor and bypasses response cache',
    () async {
      final result = await api.configTransfers().export(
        'demo',
        ConfigExportMode.backup,
      );
      expect(jsonDecode(utf8.decode(result.bytes)), contains('chess'));
      expect(adapter.requests, hasLength(2));
      expect(adapter.requests.last.queryParameters['mode'], 'backup');
      expect(adapter.requests.every((r) => r.followRedirects == false), isTrue);
      expect(adapter.requests.last.headers['Cache-Control'], 'no-store');
      if (ProfileService.isPreview) {
        expect(
          adapter.requests.every(
            (r) => ProfileService.permitsPreviewUri(r.uri),
          ),
          isTrue,
        );
      }
    },
  );

  test('binary error response is decoded into field messages', () async {
    adapter.exportStatus = 400;
    await expectLater(
      api.configTransfers().export('demo', ConfigExportMode.share),
      throwsA(
        isA<ConfigTransferException>().having(
          (e) => e.message,
          'message',
          contains('chess.scheduler.enable'),
        ),
      ),
    );
  });

  test(
    'changing backend address closes a dialog transport before any upload',
    () async {
      final transfer = api.configTransfers();
      api.setAddress(ProfileService.isPreview ? '' : '127.0.0.1:22290');
      if (ProfileService.isPreview) {
        // Preview addresses are pinned even when callers try to change them.
        expect(api.address, 'http://127.0.0.1:22391');
      } else {
        await expectLater(
          transfer.export('demo', ConfigExportMode.backup),
          throwsA(isA<ConfigTransferException>()),
        );
        expect(adapter.requests, isEmpty);
      }
      api.resetAddress();
    },
  );
}
