import 'package:get/get.dart';
import 'package:oasx/api/github_release_model.dart';
import 'package:oasx/service/app_update/models/app_update_plan.dart';
import 'package:oasx/translation/i18n_content.dart';

/// This pinned compatibility build must not install newer, incompatible releases.
class AppUpdateService extends GetxService {
  final RxBool isInstalling = false.obs;
  final RxBool isCheckingForUpdates = false.obs;
  final RxDouble downloadProgress = (-1.0).obs;
  final RxString downloadProgressLabel = ''.obs;

  static const maintenanceMessage =
      '此副本固定为 AzurTian v0.3.9 主线兼容版，请手动维护；已禁用自动升级和安装。';

  Future<void> checkForUpdates({
    bool showTip = false,
    bool forceCheck = false,
  }) async {
    if (showTip || forceCheck) _showMaintenanceNotice();
  }

  Future<void> openReleasePage(GithubReleaseModel release) async {
    _showMaintenanceNotice();
  }

  Future<void> installUpdate(AppUpdatePlan plan) async {
    _showMaintenanceNotice();
  }

  void handleUpdateDialogClosed() {
    isInstalling.value = false;
    downloadProgress.value = -1;
    downloadProgressLabel.value = '';
  }

  void _showMaintenanceNotice() {
    Get.snackbar(I18n.tip.tr, maintenanceMessage);
  }
}
