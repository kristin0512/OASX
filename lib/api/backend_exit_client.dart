import 'dart:async';

import 'package:flutter_nb_net/flutter_net.dart';
import 'package:oasx/service/profile_service.dart';

/// A dedicated, uncached request to the address selected at exit time.
/// It cannot inherit a later change to the shared API client's base URL.
class BackendExitClient {
  BackendExitClient({
    Dio? dio,
    this.preview = ProfileService.isPreview,
    this.timeout = const Duration(seconds: 5),
  }) : _dio = dio ?? Dio();

  final Dio _dio;
  final bool preview;
  final Duration timeout;

  static Uri shutdownUri(String address) {
    final trimmed = address.trim();
    if (trimmed.isEmpty) throw const FormatException('No backend selected');
    final uri = Uri.parse(
      trimmed.contains('://') ? trimmed : 'http://$trimmed',
    );
    if ((uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('Invalid backend address');
    }
    final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    return uri.replace(path: '$path/home/kill_server');
  }

  Future<void> stop(String address) async {
    // Defense in depth: even a mistaken preview caller cannot shut down its
    // fixture or any live backend.
    if (preview) return;
    final endpoint = shutdownUri(address);
    final cancel = CancelToken();
    try {
      final response = await _dio
          .getUri<dynamic>(
            endpoint,
            cancelToken: cancel,
            options: Options(
              followRedirects: false,
              receiveTimeout: timeout,
              sendTimeout: timeout,
              validateStatus: (status) => status == 200,
            ),
          )
          .timeout(timeout);
      // Mainline acknowledges the stop signal with the JSON string success.
      // A login page or arbitrary HTTP 200 is not a shutdown acknowledgment.
      if (response.data != 'success') {
        throw StateError('Backend did not acknowledge the shutdown request');
      }
    } finally {
      cancel.cancel('Exit request complete');
      _dio.close(force: true);
    }
  }
}
