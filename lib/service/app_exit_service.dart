import 'dart:async';

enum AppExitResult { hiddenToTray, keptOpen, exited }

enum ExitFailureChoice { keepOpen, exitFrontendOnly }

/// One explicit user-exit path shared by the window and the tray menu.
/// Disposing services must never call this coordinator.
class AppExitService {
  AppExitService({
    required this.minimizeToTray,
    required this.trayAvailable,
    required this.stopBackendOnExit,
    required this.backendAddress,
    required this.hideWindow,
    required this.closeFrontend,
    required this.stopBackend,
    required this.resolveStopFailure,
    required this.preview,
    this.shutdownTimeout = const Duration(seconds: 6),
  });

  final bool Function() minimizeToTray;
  final bool Function() trayAvailable;
  final bool Function() stopBackendOnExit;
  final String Function() backendAddress;
  final Future<void> Function() hideWindow;
  final Future<void> Function() closeFrontend;
  final Future<void> Function(String address) stopBackend;
  final Future<ExitFailureChoice> Function(String address, Object error)
  resolveStopFailure;
  final bool preview;
  final Duration shutdownTimeout;

  Future<AppExitResult>? _pending;
  bool _didExit = false;

  Future<AppExitResult> requestExit({bool fromTray = false}) {
    if (_didExit) return Future.value(AppExitResult.exited);
    final pending = _pending;
    if (pending != null) return pending;

    // Store the future before running callbacks: a second close event during
    // shutdown (or while the failure dialog is open) joins the same attempt.
    final completion = Completer<AppExitResult>();
    _pending = completion.future;
    unawaited(
      _exit(fromTray).then(
        (result) {
          _pending = null;
          completion.complete(result);
        },
        onError: (Object error, StackTrace stack) {
          _pending = null;
          completion.completeError(error, stack);
        },
      ),
    );
    return completion.future;
  }

  Future<AppExitResult> _exit(bool fromTray) async {
    if (!fromTray && minimizeToTray() && trayAvailable()) {
      await hideWindow();
      return AppExitResult.hiddenToTray;
    }

    // Snapshot before the first await. A settings edit cannot retarget an
    // in-flight shutdown to another server. Preview never calls shutdown.
    final shouldStop = !preview && stopBackendOnExit();
    final address = shouldStop ? backendAddress() : '';
    if (shouldStop) {
      try {
        await stopBackend(address).timeout(shutdownTimeout);
      } catch (error) {
        final choice = await resolveStopFailure(address, error);
        if (choice == ExitFailureChoice.keepOpen) {
          return AppExitResult.keptOpen;
        }
      }
    }
    await closeFrontend();
    _didExit = true;
    return AppExitResult.exited;
  }
}
