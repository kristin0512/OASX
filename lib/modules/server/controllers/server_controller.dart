import 'dart:io';
import 'dart:convert';

import 'package:get/get.dart';
import 'package:get_storage/get_storage.dart';
import 'package:process_run/shell.dart';

import 'package:oasx/api/api_client.dart';
import 'package:oasx/modules/common/models/storage_key.dart';
import 'package:oasx/modules/home/controllers/dashboard_controller.dart';
import 'package:oasx/modules/log/log_mixin.dart';
import 'package:oasx/modules/settings/controllers/settings_controller.dart';
import 'package:oasx/service/locale_service.dart';
import 'package:oasx/service/script_service.dart';
import 'package:oasx/service/profile_service.dart';

class ServerController extends GetxController with LogMixin {
  final rootPathServer = ''.obs;
  final rootPathAuthenticated = true.obs;
  final showDeploy = true.obs;
  final deployContent = ''.obs;
  final autoLoginAfterDeploy = false.obs;
  final isDeployLoading = false.obs;
  final _storage = GetStorage();
  Shell? shell;
  var shellController = ShellLinesController();

  @override
  void onInit() {
    rootPathServer.value =
        _storage.read(StorageKey.rootPathServer.name) ??
        'Please set OAS root path';
    autoLoginAfterDeploy.value =
        _storage.read(StorageKey.autoLoginAfterDeploy.name) ?? false;
    if (!ProfileService.isPreview) shell = getShell;
    shellController.stream.listen(
      (event) => addLog(!event.contains('INFO') ? 'INFO: $event' : event),
    );
    rootPathAuthenticated.value = authenticatePath(rootPathServer.value);
    if (rootPathAuthenticated.value) {
      readDeploy();
    }
    super.onInit();
  }

  void updateRootPathServer(String value) {
    if (ProfileService.isPreview) return;
    rootPathAuthenticated.value = authenticatePath(value);
    rootPathServer.value = value;
    shell = getShell;
    Get.find<SettingsController>().storage.write(
      StorageKey.rootPathServer.name,
      rootPathServer.value,
    );
    if (rootPathAuthenticated.value) {
      readDeploy();
    }
  }

  bool authenticatePath(String root) {
    if (ProfileService.isPreview) return false;
    root = root.replaceAll('\\', '/');
    try {
      final rootDir = Directory(root);
      if (!rootDir.existsSync()) {
        return false;
      }
      final python = File('${rootDir.path}/toolkit/python.exe');
      if (!python.existsSync()) {
        return false;
      }
      final server = File('${rootDir.path}/server.py');
      if (!server.existsSync()) {
        return false;
      }
      final deploy = File('${rootDir.path}/config/deploy.yaml');
      if (!deploy.existsSync()) {
        return false;
      }
    } catch (e) {
      printError(info: e.toString());
      return false;
    }
    return true;
  }

  void readDeploy() {
    if (ProfileService.isPreview) return;
    final filePath = '${rootPathServer.value}\\config\\deploy.yaml';
    try {
      final file = File(filePath);
      if (file.existsSync()) {
        deployContent.value = file.readAsStringSync();
      } else {
        deployContent.value = 'File not found';
      }
    } catch (e) {
      deployContent.value = 'Error reading file: $e';
    }
  }

  void writeDeploy(String value) {
    if (ProfileService.isPreview) return;
    final filePath = '${rootPathServer.value}\\config\\deploy.yaml';
    deployContent.value = value;
    try {
      final file = File(filePath);
      if (file.existsSync()) {
        file.writeAsStringSync(deployContent.value);
      } else {
        deployContent.value = 'File not found';
      }
    } catch (e) {
      deployContent.value = 'Error writing file: $e';
    }
  }

  String get pathGit => '${rootPathServer.value}\\toolkit\\Git\\mingw64\\bin"';
  String get pathPython => '${rootPathServer.value}\\toolkit';
  String get pathAdb =>
      '${rootPathServer.value}\\toolkit\\Lib\\site-packages\\adbutils\\binaries';
  String get pathScripts => '${rootPathServer.value}\\toolkit\\Scripts';
  Map<String, String> get pathPATH => {
    'PATH':
        '${rootPathServer.value},$pathGit,$pathPython,$pathAdb,$pathScripts',
  };

  Shell get getShell => Shell(
    workingDirectory: rootPathServer.value,
    runInShell: true,
    environment: pathPATH,
    stdout: shellController.sink,
    verbose: false,
  );

  Future<void> runShell(String command) async {
    if (ProfileService.isPreview) return;
    try {
      final result = await shell!.run(command);
      printInfo(info: result.errText);
    } on ShellException catch (e) {
      addLog('ERROR: ${e.toString()}');
    }
  }

  Future<void> run() async {
    if (ProfileService.isPreview || isDeployLoading.value) return;
    if (!authenticatePath(rootPathServer.value)) return;
    isDeployLoading.value = true;
    try {
      clearLog();
      // Only start the selected checkout. Installers and global process kills
      // can affect another running account or overwrite local development.
      final root = Directory(rootPathServer.value).absolute;
      // pythonw also keeps multiprocessing task children from opening consoles.
      final executable = Platform.isWindows ? 'pythonw.exe' : 'python.exe';
      final process = await Process.start(
        File('${root.path}/toolkit/$executable').path,
        ['server.py'],
        workingDirectory: root.path,
        runInShell: false,
        mode: ProcessStartMode.detachedWithStdio,
      );
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => addLog(line));
      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => addLog(line));
      addLog('INFO: Started selected backend (PID ${process.pid}).');

      final shouldAutoLogin = _resolveAutoLoginAfterDeploy();
      if (!shouldAutoLogin) {
        return;
      }

      final address = _storage.read(StorageKey.address.name) ?? '';
      if (address.isEmpty) {
        return;
      }
      await Future.delayed(const Duration(seconds: 2));
      await _tryConnect(
        address,
        retries: 60,
        retryDelay: const Duration(milliseconds: 500),
      );
    } finally {
      isDeployLoading.value = false;
    }
  }

  bool _resolveAutoLoginAfterDeploy() {
    if (Get.isRegistered<SettingsController>()) {
      final value = Get.find<SettingsController>().autoLoginAfterDeploy.value;
      autoLoginAfterDeploy.value = value;
      return value;
    }
    final value = _storage.read(StorageKey.autoLoginAfterDeploy.name) ?? false;
    autoLoginAfterDeploy.value = value;
    return value;
  }

  Future<bool> _tryConnect(
    String rawAddress, {
    int retries = 1,
    Duration retryDelay = const Duration(milliseconds: 500),
  }) async {
    final address =
        rawAddress.startsWith('http://') || rawAddress.startsWith('https://')
        ? rawAddress
        : 'http://$rawAddress';
    if (ApiClient().address != address && Get.isRegistered<ScriptService>()) {
      await Get.find<ScriptService>().resetDashboardState();
    }
    ApiClient().setAddress(address);

    for (int i = 0; i < retries; i++) {
      final connected = await ApiClient().testAddress();
      if (connected) {
        try {
          if (Get.isRegistered<HomeDashboardController>()) {
            await Get.find<HomeDashboardController>()
                .refreshAfterExternalConnected();
          } else if (Get.isRegistered<ScriptService>()) {
            await Get.find<ScriptService>().reloadFromServer();
          }
        } catch (_) {
          // Keep navigation behavior even if dashboard refresh fails here.
        }
        await Get.find<LocaleService>().refreshTransFromRemote();
        Get.offAllNamed('/home');
        return true;
      }
      if (i < retries - 1) {
        await Future.delayed(retryDelay);
      }
    }
    return false;
  }
}
