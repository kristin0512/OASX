import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'package:get_storage/get_storage.dart';
import 'package:oasx/api/api_client.dart';
import 'package:oasx/api/backend_exit_client.dart';
import 'package:oasx/service/app_exit_service.dart';
import 'package:oasx/service/profile_service.dart';
import 'package:oasx/modules/common/models/storage_key.dart';
import 'package:oasx/modules/common/models/window_state.dart';
import 'package:oasx/service/system_tray_service.dart';
import 'package:oasx/translation/i18n_content.dart';
import 'package:oasx/utils/platform_utils.dart';
import 'package:window_manager/window_manager.dart';

const Size _defaultDesktopWindowSize = Size(1200, 800);
const Size _minimumWindowsWindowSize = Size(260, 420);

class WindowService extends GetxService with WindowListener {
  // ignore: unused_field
  final _storage = GetStorage();
  final Completer<void> _readyCompleter = Completer<void>();
  Future<void> get ready => _readyCompleter.future;

  bool _didInitDesktop = false;
  int _trayInitToken = 0;

  Timer? _debounceTimer;
  DateTime? _lastSaveTime;
  final enableWindowState = false.obs;
  final enableSystemTray = false.obs;
  final stopBackendOnExit = false.obs;

  late final AppExitService _exitService = AppExitService(
    minimizeToTray: () => enableSystemTray.value,
    trayAvailable: () =>
        Get.isRegistered<SystemTrayService>() &&
        Get.find<SystemTrayService>().isTrayVisible,
    stopBackendOnExit: () => stopBackendOnExit.value,
    backendAddress: () => ApiClient().address,
    hideWindow: _hideToTray,
    closeFrontend: _closeFrontend,
    stopBackend: (address) => BackendExitClient().stop(address),
    resolveStopFailure: _resolveStopFailure,
    preview: ProfileService.isPreview,
  );

  @override
  Future<void> onInit() async {
    try {
      await _initDesktopIfNeeded();
    } catch (e) {
      printError(info: 'window init failed: $e');
    } finally {
      if (!_readyCompleter.isCompleted) {
        _readyCompleter.complete();
      }
    }
    super.onInit();
  }

  Future<void> _initDesktopIfNeeded() async {
    if (_didInitDesktop || !PlatformUtils.isDesktop) return;
    _didInitDesktop = true;

    await windowManager.ensureInitialized();

    enableWindowState.value =
        _storage.read(StorageKey.enableWindowState.name) ?? false;
    enableSystemTray.value =
        _storage.read(StorageKey.enableSystemTray.name) ?? false;
    stopBackendOnExit.value =
        _storage.read(StorageKey.stopBackendOnExit.name) ?? false;

    // WM_CLOSE must already be intercepted when the window becomes visible.
    // Tray readiness only changes hide-vs-exit, never close interception.
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);

    final lastState = await initWindowState();

    await windowManager.waitUntilReadyToShow(buildWindowOptions(lastState));

    _kickoffSystemTrayInit();
  }

  void _kickoffSystemTrayInit() {
    if (!PlatformUtils.isDesktop) return;

    if (!enableSystemTray.value) return;

    final token = ++_trayInitToken;
    unawaited(_ensureSystemTrayReady(token));
  }

  Future<void> _ensureSystemTrayReady(int token) async {
    const maxAttempts = 30;
    const retryDelay = Duration(seconds: 1);

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (!PlatformUtils.isDesktop) return;
      if (!enableSystemTray.value) return;
      if (token != _trayInitToken) return;
      if (!Get.isRegistered<SystemTrayService>()) return;

      final ok = await Get.find<SystemTrayService>().showTray();
      if (token != _trayInitToken || !enableSystemTray.value) {
        if (!enableSystemTray.value) {
          await Get.find<SystemTrayService>().hideTray();
        }
        return;
      }
      if (ok) {
        return;
      }

      await Future.delayed(retryDelay);
    }

    printInfo(info: 'system tray init failed, close will exit the app.');
  }

  WindowOptions buildWindowOptions(WindowStateModel? lastState) {
    final minimumSize = PlatformUtils.isWindows
        ? _minimumWindowsWindowSize
        : null;
    final initialSize = _resolveInitialWindowSize(
      lastState,
      minimumSize: minimumSize,
    );
    return WindowOptions(
      title: ProfileService.isPreview
          ? 'OASX AzurTian Preview - 22391'
          : 'OASX AzurTian Runhey - 22289',
      size: initialSize,
      center: lastState == null,
      minimumSize: minimumSize,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.hidden,
    );
  }

  Size _resolveInitialWindowSize(
    WindowStateModel? lastState, {
    Size? minimumSize,
  }) {
    if (lastState == null) {
      return _defaultDesktopWindowSize;
    }
    if (minimumSize == null) {
      return Size(lastState.width, lastState.height);
    }
    return Size(
      lastState.width < minimumSize.width ? minimumSize.width : lastState.width,
      lastState.height < minimumSize.height
          ? minimumSize.height
          : lastState.height,
    );
  }

  Future<WindowStateModel?> initWindowState() async {
    if (!enableWindowState.value) return null;
    final jsonStr = _storage.read(StorageKey.windowState.name);
    if (jsonStr == null) return null;
    WindowStateModel? lastState = WindowStateModel.fromJson(
      json.decode(jsonStr) as Map<String, dynamic>,
    );
    await windowManager.setBounds(
      Rect.fromLTWH(
        lastState.x,
        lastState.y,
        lastState.width,
        lastState.height,
      ),
    );
    return lastState;
  }

  Future<void> _saveWindowState() async {
    if (!PlatformUtils.isDesktop || !enableWindowState.value) return;
    final size = await windowManager.getSize();
    final pos = await windowManager.getPosition();
    final state = WindowStateModel(
      x: pos.dx,
      y: pos.dy,
      width: size.width,
      height: size.height,
    );
    _storage.write(StorageKey.windowState.name, json.encode(state.toJson()));
    printInfo(info: 'save window state:${state.toJson()}');
  }

  void _scheduleSave() {
    if (!PlatformUtils.isDesktop || !enableWindowState.value) return;
    final now = DateTime.now();
    if (_lastSaveTime == null ||
        now.difference(_lastSaveTime!) > const Duration(seconds: 2)) {
      _lastSaveTime = now;
      _saveWindowState();
    }
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), () async {
      _lastSaveTime = DateTime.now();
      await _saveWindowState();
    });
  }

  @override
  void onWindowMove() => _scheduleSave();
  @override
  void onWindowResize() => _scheduleSave();

  @override
  void onWindowClose() {
    unawaited(
      requestExit().catchError((Object error) {
        printError(info: 'window exit failed: $error');
        return AppExitResult.keptOpen;
      }),
    );
  }

  Future<AppExitResult> requestExit({bool fromTray = false}) =>
      _exitService.requestExit(fromTray: fromTray);

  Future<void> _hideToTray() async {
    _debounceTimer?.cancel();
    await _saveWindowState();
    await windowManager.hide();
  }

  Future<void> _closeFrontend() async {
    _debounceTimer?.cancel();
    try {
      await _saveWindowState();
      await _storage.save();
      if (Get.isRegistered<SystemTrayService>()) {
        await Get.find<SystemTrayService>().hideTray();
      }
    } catch (error) {
      printError(info: 'window exit cleanup failed: $error');
    }
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  Future<ExitFailureChoice> _resolveStopFailure(
    String address,
    Object error,
  ) async {
    // A tray-menu exit may start with a hidden window. Always expose its
    // failure choice instead of leaving an invisible modal behind the tray.
    await windowManager.show();
    await windowManager.focus();
    if (Get.overlayContext == null) return ExitFailureChoice.keepOpen;
    final uri = Uri.tryParse(address);
    final displayAddress = uri == null
        ? address
        : uri.replace(userInfo: '', query: '', fragment: '').toString();
    final result = await Get.dialog<ExitFailureChoice>(
      AlertDialog(
        title: Text(I18n.exitBackendStopFailed.tr),
        content: Text(
          I18n.exitBackendStopFailedHelp.trParams({'address': displayAddress}),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: ExitFailureChoice.keepOpen),
            child: Text(I18n.exitKeepOpen.tr),
          ),
          TextButton(
            onPressed: () =>
                Get.back(result: ExitFailureChoice.exitFrontendOnly),
            child: Text(I18n.exitFrontendOnly.tr),
          ),
        ],
      ),
      barrierDismissible: false,
    );
    return result ?? ExitFailureChoice.keepOpen;
  }

  @override
  void onClose() {
    if (PlatformUtils.isDesktop) {
      windowManager.removeListener(this);
    }
    _debounceTimer?.cancel();
    super.onClose();
  }

  void updateWindowStateEnable(bool newVal) {
    enableWindowState.value = newVal;
    _storage.write(StorageKey.enableWindowState.name, newVal);
  }

  void updateStopBackendOnExit(bool newVal) {
    stopBackendOnExit.value = newVal;
    _storage.write(StorageKey.stopBackendOnExit.name, newVal);
  }

  Future<void> updateSystemTrayEnable(bool newVal) async {
    enableSystemTray.value = newVal;
    _storage.write(StorageKey.enableSystemTray.name, newVal);

    if (!PlatformUtils.isDesktop) return;

    if (newVal) {
      _kickoffSystemTrayInit();
      return;
    }

    _trayInitToken++;
    if (!Get.isRegistered<SystemTrayService>()) {
      return;
    }
    await Get.find<SystemTrayService>().hideTray();
  }
}
