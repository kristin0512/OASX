import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_nb_net/flutter_net.dart';
import 'package:get/get.dart';
import 'package:get_storage/get_storage.dart';
import 'package:oasx/api/api_interceptor.dart';
import 'package:oasx/modules/home/models/config_model.dart';
import 'package:oasx/modules/server/controllers/server_controller.dart';
import 'package:oasx/service/app_update_service.dart';
import 'package:oasx/service/autostart_service.dart';
import 'package:oasx/service/profile_service.dart';
import 'package:oasx/service/script_service.dart';
import 'package:oasx/service/websocket_service.dart';

class OfflineScriptService extends ScriptService {
  @override
  // ignore: must_call_super
  Future<void> onInit() async {}
}

class RecordingSockets extends WebSocketService {
  final commands = <String>[];
  int closeAllCount = 0;

  @override
  Future<void> closeAll() async => closeAllCount++;

  @override
  Future<void> send(String name, String message) async {
    commands.add('$name:$message');
  }

  @override
  Future<WebSocketClient> connect({
    required String name,
    String? url,
    MessageListener? listener,
    bool force = false,
  }) async => WebSocketClient(name: name, url: 'ws://example.invalid');
}

class OfflineHttpAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      'true',
      200,
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
  setUp(() => Get.testMode = true);
  tearDown(() async => Get.reset());

  test(
    'portable profile initializes the default box and isolated directories',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'oasx-azurtian-profile-test-',
      );
      // GetStorage queries path_provider even when an explicit path is given.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => root.path,
          );
      await ProfileService.initialize(projectDirectory: root);
      final box = GetStorage();
      expect(box.read('address'), ProfileService.defaultAddress);
      expect(box.read('autoDeploy'), false);
      expect(box.read('launchAtStartup'), false);
      expect(box.read('autoScriptList'), isEmpty);
      const expected = ProfileService.isPreview
          ? 'profile-preview'
          : 'profile-oasx';
      expect((await ProfileService.cacheDirectory()).path, contains(expected));
      expect(
        (await ProfileService.temporaryDirectory()).path,
        startsWith(root.path),
      );
      expect(
        box.read('temporaryDirectory'),
        (await ProfileService.temporaryDirectory()).path,
      );
      await box.save();
      expect(File('${root.path}/$expected/GetStorage.gs').existsSync(), true);
    },
  );

  test('preview allowlist rejects alternate hosts, ports and redirects', () {
    expect(
      ProfileService.permitsPreviewUri(
        Uri.parse('http://127.0.0.1:22391/test'),
      ),
      true,
    );
    expect(
      ProfileService.permitsPreviewUri(
        Uri.parse('ws://127.0.0.1:22391/ws/preview'),
        websocket: true,
      ),
      true,
    );
    for (final value in [
      'http://127.0.0.1:22288/test',
      'http://127.0.0.1:22289/test',
      'http://localhost:22391/test',
      'https://127.0.0.1:22391/test',
      'http://user@127.0.0.1:22391/test',
      'http://example.com:22391/test',
    ]) {
      expect(
        ProfileService.permitsPreviewUri(Uri.parse(value)),
        false,
        reason: value,
      );
    }
  });

  test(
    'closing detaches observers without stop commands or late resurrection',
    () async {
      final sockets =
          Get.put<WebSocketService>(RecordingSockets()) as RecordingSockets;
      final scripts = ScriptService();
      scripts.addScriptModel('running');
      scripts.scriptModelMap['running']!.update(state: ScriptState.running);
      await scripts.onClose();
      expect(sockets.closeAllCount, 1);
      expect(sockets.commands, isEmpty);
      await scripts.startScript('running');
      await scripts.stopScript('running');
      scripts.wsListener('{"state":1}', 'running');
      expect(scripts.scriptModelMap, isEmpty);
      expect(sockets.commands, isEmpty);
    },
  );

  test(
    'explicit controls retain mainline plaintext websocket commands',
    () async {
      final sockets =
          Get.put<WebSocketService>(RecordingSockets()) as RecordingSockets;
      final scripts = Get.put<ScriptService>(OfflineScriptService());
      scripts.addScriptModel('account');
      await scripts.startScript('account');
      await scripts.stopScript('account');
      expect(sockets.commands, ['account:start', 'account:stop']);
      scripts.wsListener('{"state":1}', 'account');
      expect(
        scripts.scriptModelMap['account']!.state.value,
        ScriptState.running,
      );
      final reset = scripts.resetDashboardState();
      expect(scripts.scriptModelMap, isEmpty);
      await reset;
    },
  );

  test(
    'pinned application never checks or installs automatic updates',
    () async {
      final updater = AppUpdateService();
      await updater.checkForUpdates();
      expect(updater.isCheckingForUpdates.value, false);
      expect(updater.isInstalling.value, false);
    },
  );

  test(
    'preview HTTP rejects live before transport and forbids redirects',
    () async {
      final adapter = OfflineHttpAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      dio.interceptors.add(ApiInterceptor());
      await expectLater(
        dio.get('http://127.0.0.1:22289/test'),
        throwsA(isA<DioException>()),
      );
      expect(adapter.requests, isEmpty);
      await dio.get('http://127.0.0.1:22391/test');
      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.single.followRedirects, false);
      dio.close();
    },
    skip: !ProfileService.isPreview,
  );

  test(
    'preview cannot deploy, edit real files, or enable autostart',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'oasx-preview-deploy-test-',
      );
      final config = Directory('${root.path}/config')..createSync();
      final deploy = File('${config.path}/deploy.yaml')
        ..writeAsStringSync('unchanged');
      final server = ServerController();
      server.rootPathServer.value = root.path;
      server.writeDeploy('changed');
      await server.runShell('this-command-must-never-run');
      await server.run();
      expect(deploy.readAsStringSync(), 'unchanged');
      expect(server.isDeployLoading.value, false);
      final autostart = AutoStartService();
      await autostart.onInit();
      await autostart.updateLaunchAtStartupEnable(true);
      expect(autostart.enableLaunchAtStartup.value, false);
      await root.delete(recursive: true);
    },
    skip: !ProfileService.isPreview,
  );
}
