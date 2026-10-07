import 'dart:convert';
import 'dart:typed_data';

const configTransferMaxBytes = 2 * 1024 * 1024;

enum ConfigExportMode { backup, share }

class ConfigTransferException implements Exception {
  const ConfigTransferException(this.message, [this.code]);
  final String message;
  final int? code;
  @override
  String toString() => message;
}

class ConfigTransferDocument {
  ConfigTransferDocument._(this.fileName, this.bytes);
  final String fileName;
  final Uint8List bytes;

  /// Validates locally before an upload; never displays account values.
  factory ConfigTransferDocument.parse(String name, List<int> bytes) {
    if (bytes.isEmpty || bytes.length > configTransferMaxBytes) {
      throw const ConfigTransferException('请选择非空 JSON 文件，最大 2 MiB。');
    }
    if (!name.toLowerCase().endsWith('.json')) {
      throw const ConfigTransferException('请选择 .json 配置文件。');
    }
    try {
      var text = utf8.decode(bytes);
      if (text.startsWith('\uFEFF')) text = text.substring(1);
      final data = jsonDecode(text);
      if (data is! Map || data.isEmpty) {
        throw const FormatException('Expected a nonempty JSON object');
      }
    } on FormatException {
      throw const ConfigTransferException('文件不是有效的 UTF-8 JSON 配置对象。');
    }
    return ConfigTransferDocument._(
      transferFileName(name),
      Uint8List.fromList(bytes),
    );
  }
}

class ConfigTransferImportResult {
  const ConfigTransferImportResult({
    required this.configName,
    this.taskName = '',
    this.warnings = const [],
  });
  final String configName;
  final String taskName;
  final List<String> warnings;

  factory ConfigTransferImportResult.fromJson(
    dynamic data, {
    bool task = false,
  }) {
    if (data is! Map) {
      throw const ConfigTransferException('后端返回的导入结果无效。');
    }
    final name = data[task ? 'config_name' : 'name']?.toString() ?? '';
    if (name.isEmpty || (task && data['updated'] != true)) {
      throw const ConfigTransferException('后端未确认配置导入成功。');
    }
    return ConfigTransferImportResult(
      configName: name,
      taskName: task ? data['task_name']?.toString() ?? '' : '',
      warnings: data['warnings'] is List
          ? (data['warnings'] as List).map((e) => e.toString()).toList()
          : const [],
    );
  }
}

class ConfigTransferExportResult {
  const ConfigTransferExportResult(this.fileName, this.bytes);
  final String fileName;
  final Uint8List bytes;
}

/// Portable filenames cannot escape the directory selected by the user.
String transferFileName(String name) {
  var value = name.split(RegExp(r'[\\/]')).last;
  value = value.replaceAll(RegExp(r'[<>:"|?*\x00-\x1f]'), '_');
  value = value.replaceAll(RegExp(r'[. ]+$'), '');
  if (value.isEmpty) value = 'config.json';
  if (RegExp(
    r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)',
    caseSensitive: false,
  ).hasMatch(value)) {
    value = '_$value';
  }
  return value;
}

String normalizeConfigImportName(String name) {
  final trimmed = name.trim();
  return trimmed.toLowerCase().endsWith('.json')
      ? trimmed.substring(0, trimmed.length - 5)
      : trimmed;
}

String? validateConfigImportName(String name, Iterable<String> existing) {
  name = normalizeConfigImportName(name);
  if (!RegExp(r'^[A-Za-z0-9_\-\u4e00-\u9fff]{1,64}$').hasMatch(name)) {
    return '名称需为 1–64 位中文、字母、数字、下划线或短横线。';
  }
  final lower = name.toLowerCase();
  if (['home', 'template'].contains(lower) ||
      RegExp(r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])$').hasMatch(lower)) {
    return '该名称不可用于新配置。';
  }
  if (existing.any(
    (item) => normalizeConfigImportName(item).toLowerCase() == lower,
  )) {
    return '名称已存在；导入只会新建配置，请使用另一个名称。';
  }
  return null;
}
