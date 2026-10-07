import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:oasx/api/config_transfer_models.dart';

/// File access is limited to explicit picker selections, never a backend root
/// or the client's account/settings directory.
class ConfigTransferFiles {
  Future<ConfigTransferDocument?> pickJson() async {
    final selection = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      allowMultiple: false,
      withData: kIsWeb,
    );
    if (selection == null || selection.files.isEmpty) return null;
    final selected = selection.files.single;
    if (selected.size <= 0 || selected.size > configTransferMaxBytes) {
      throw const ConfigTransferException('请选择非空 JSON 文件，最大 2 MiB。');
    }
    if (kIsWeb) {
      final bytes = selected.bytes;
      if (bytes == null) throw const ConfigTransferException('无法读取所选文件。');
      return ConfigTransferDocument.parse(selected.name, bytes);
    }
    final path = selected.path;
    if (path == null) throw const ConfigTransferException('无法读取所选文件。');
    return readJsonFile(File(path), selected.name);
  }

  static Future<ConfigTransferDocument> readJsonFile(
    File file,
    String name,
  ) async {
    if (await file.length() > configTransferMaxBytes) {
      throw const ConfigTransferException('请选择非空 JSON 文件，最大 2 MiB。');
    }
    // Limit the stream too, in case the file grows after its length is checked.
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in file.openRead(0, configTransferMaxBytes + 1)) {
      bytes.add(chunk);
    }
    return ConfigTransferDocument.parse(name, bytes.takeBytes());
  }

  Future<String?> chooseSavePath(String fileName) =>
      FilePicker.platform.saveFile(
        dialogTitle: '保存 JSON 配置',
        fileName: transferFileName(fileName),
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );

  Future<void> writeJson(String path, Uint8List bytes) async {
    if (kIsWeb) {
      throw const ConfigTransferException('请使用桌面客户端保存 JSON 文件。');
    }
    await File(path).writeAsBytes(bytes, flush: true);
  }
}
