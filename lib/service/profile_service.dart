import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:get_storage/get_storage.dart';
import 'package:path_provider/path_provider.dart';

/// Owns this portable client's settings, cache and temporary files.
class ProfileService {
  static const isPreview = bool.fromEnvironment('OASX_PREVIEW');
  static const previewAddress = '127.0.0.1:22391';
  static const defaultAddress = isPreview ? previewAddress : '127.0.0.1:22289';
  static Directory? _profile;

  static Future<void> initialize({Directory? projectDirectory}) async {
    if (kIsWeb) {
      await GetStorage.init();
    } else {
      final base =
          projectDirectory ??
          (Platform.isWindows
              ? File(Platform.resolvedExecutable).parent.parent
              : await getApplicationSupportDirectory());
      _profile = Directory.fromUri(
        base.uri.resolve(isPreview ? 'profile-preview/' : 'profile-oasx/'),
      );
      await _profile!.create(recursive: true);
      // The first default box determines the path reused by GetStorage().
      final storage = GetStorage('GetStorage', _profile!.path);
      await storage.initStorage;
    }
    final storage = GetStorage();
    if (isPreview) {
      await storage.write('address', previewAddress);
      await storage.write('autoDeploy', false);
      await storage.write('autoLoginAfterDeploy', false);
      await storage.write('launchAtStartup', false);
      await storage.write('autoScriptList', <String>[]);
    } else {
      await storage.writeIfNull('address', defaultAddress);
      await storage.writeIfNull('autoDeploy', false);
      await storage.writeIfNull('autoLoginAfterDeploy', false);
      await storage.writeIfNull('launchAtStartup', false);
      await storage.writeIfNull('autoScriptList', <String>[]);
    }
    final temp = kIsWeb ? 'web_cache' : (await temporaryDirectory()).path;
    await storage.write('temporaryDirectory', temp);
  }

  static Future<Directory> cacheDirectory() async {
    final profile = _profile;
    if (profile == null) {
      throw StateError('ProfileService.initialize must run before disk access');
    }
    return Directory.fromUri(
      profile.uri.resolve('cache/'),
    ).create(recursive: true);
  }

  static Future<Directory> temporaryDirectory() async {
    final profile = _profile;
    if (profile == null) {
      throw StateError('ProfileService.initialize must run before disk access');
    }
    return Directory.fromUri(
      profile.uri.resolve('temp/'),
    ).create(recursive: true);
  }

  static bool permitsPreviewUri(Uri uri, {bool websocket = false}) {
    return uri.scheme == (websocket ? 'ws' : 'http') &&
        uri.host == '127.0.0.1' &&
        uri.port == 22391 &&
        uri.userInfo.isEmpty;
  }
}
