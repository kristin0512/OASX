import 'package:flutter_nb_net/flutter_net.dart' show FormData, MultipartFile;
import 'config_transfer_models.dart';

class ConfigTransferRequest {
  const ConfigTransferRequest(
    this.method,
    this.path, {
    this.query = const {},
    this.data,
    this.bytes = false,
  });
  final String method;
  final String path;
  final Map<String, dynamic> query;
  final Object? data;
  final bool bytes;
}

class ConfigTransferResponse {
  const ConfigTransferResponse(this.status, this.data);
  final int status;
  final dynamic data;
}

typedef ConfigTransferTransport =
    Future<ConfigTransferResponse> Function(ConfigTransferRequest request);

/// Explicit capability discovery prevents a legacy export from being mistaken
/// for a full backup when it silently ignores the new mode parameter.
class ConfigTransferApi {
  ConfigTransferApi(this.transport);
  final ConfigTransferTransport transport;
  Map? _capabilities;

  Future<void> ensureSupported() async {
    if (_capabilities != null) return;
    final data = await _request(
      const ConfigTransferRequest('GET', '/config/transfer/capabilities'),
    );
    if (data is! Map ||
        data['version'] != 1 ||
        data['modes'] is! List ||
        !(data['modes'] as List).contains('backup') ||
        !(data['modes'] as List).contains('share') ||
        data['config_import'] != true ||
        data['task_import'] != true) {
      throw const ConfigTransferException('当前后端尚未支持完整备份和脱敏分享，请更新对应后端后重试。');
    }
    _capabilities = data;
  }

  Future<ConfigTransferImportResult> importConfig(
    String name,
    ConfigTransferDocument document,
  ) async {
    name = normalizeConfigImportName(name);
    final error = validateConfigImportName(name, const []);
    if (error != null) throw ConfigTransferException(error);
    await ensureSupported();
    _checkSize(document);
    final data = await _request(
      ConfigTransferRequest(
        'POST',
        '/config/import',
        data: FormData.fromMap({
          'name': name,
          'file': MultipartFile.fromBytes(
            document.bytes,
            filename: document.fileName,
          ),
        }),
      ),
    );
    return ConfigTransferImportResult.fromJson(data);
  }

  Future<ConfigTransferImportResult> importTask(
    String configName,
    String taskName,
    ConfigTransferDocument document,
  ) async {
    await ensureSupported();
    _checkSize(document);
    final data = await _request(
      ConfigTransferRequest(
        'POST',
        '/config/task/import',
        data: FormData.fromMap({
          'config_name': configName,
          'task_name': taskName,
          'file': MultipartFile.fromBytes(
            document.bytes,
            filename: document.fileName,
          ),
        }),
      ),
    );
    return ConfigTransferImportResult.fromJson(data, task: true);
  }

  Future<ConfigTransferExportResult> export(
    String configName,
    ConfigExportMode mode, {
    String? taskName,
  }) async {
    await ensureSupported();
    final isTask = taskName != null;
    final data = await _request(
      ConfigTransferRequest(
        'GET',
        isTask ? '/config/task/export' : '/config/export',
        query: {
          if (isTask) ...{
            'config_name': configName,
            'task_name': taskName,
          } else
            'name': configName,
          'mode': mode.name,
        },
        bytes: true,
      ),
    );
    if (data is! List<int>) {
      throw const ConfigTransferException('后端返回的导出文件无效。');
    }
    final name = transferFileName(
      '$configName${isTask ? '-$taskName' : ''}-${mode.name}.json',
    );
    final document = ConfigTransferDocument.parse(name, data);
    return ConfigTransferExportResult(name, document.bytes);
  }

  void _checkSize(ConfigTransferDocument document) {
    final limit = _capabilities?['max_bytes'];
    if (limit is int && document.bytes.length > limit) {
      throw const ConfigTransferException('文件超过当前后端的导入大小限制。');
    }
  }

  Future<dynamic> _request(ConfigTransferRequest request) async {
    final response = await transport(request);
    final data = response.data;
    if (response.status >= 200 && response.status < 300) return data;
    if (response.status == 404 || response.status == 405) {
      throw const ConfigTransferException(
        '当前后端尚未支持配置 JSON 备份、分享和导入，请更新对应后端后重试。',
        404,
      );
    }
    var message = '操作失败，请重试。';
    if (data is Map) {
      final detail = data['detail'] ?? data['message'];
      if (detail is Map) {
        message = detail['message']?.toString() ?? message;
        if (detail['fields'] is List) {
          final fields = (detail['fields'] as List).take(5).join('、');
          if (fields.isNotEmpty) message = '$message：$fields';
        }
      } else if (detail != null) {
        message = detail.toString();
      }
    }
    throw ConfigTransferException(message, response.status);
  }
}
