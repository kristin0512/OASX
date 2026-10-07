import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:oasx/api/api_client.dart';
import 'package:oasx/api/config_transfer_api.dart';
import 'package:oasx/api/config_transfer_models.dart';
import 'package:oasx/service/config_transfer_files.dart';
import 'package:oasx/translation/i18n_content.dart';

typedef ConfigImportGuard = String? Function();

class ConfigTransferDialogs {
  static Future<ConfigTransferImportResult?> importJson(
    BuildContext context, {
    String initialName = '',
    List<String> existingNames = const [],
    String? configName,
    String? taskName,
    ConfigImportGuard? guard,
    ConfigTransferApi? api,
    ConfigTransferFiles? files,
  }) => showDialog<ConfigTransferImportResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ConfigJsonImportDialog(
      initialName: initialName,
      existingNames: existingNames,
      configName: configName,
      taskName: taskName,
      guard: guard,
      api: api ?? ApiClient().configTransfers(),
      files: files ?? ConfigTransferFiles(),
    ),
  );

  static Future<void> exportJson(
    BuildContext context,
    String configName,
    ConfigExportMode mode, {
    String? taskName,
    ConfigTransferApi? api,
    ConfigTransferFiles? files,
  }) async {
    final path = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ConfigJsonExportDialog(
        configName: configName,
        taskName: taskName,
        mode: mode,
        api: api ?? ApiClient().configTransfers(),
        files: files ?? ConfigTransferFiles(),
      ),
    );
    if (path != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${I18n.configJsonSaved.tr}：$path')),
      );
    }
  }
}

class ConfigJsonImportDialog extends StatefulWidget {
  const ConfigJsonImportDialog({
    super.key,
    required this.api,
    required this.files,
    this.initialName = '',
    this.existingNames = const [],
    this.configName,
    this.taskName,
    this.guard,
  });
  final ConfigTransferApi api;
  final ConfigTransferFiles files;
  final String initialName;
  final List<String> existingNames;
  final String? configName;
  final String? taskName;
  final ConfigImportGuard? guard;
  @override
  State<ConfigJsonImportDialog> createState() => _ConfigJsonImportDialogState();
}

class _ConfigJsonImportDialogState extends State<ConfigJsonImportDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initialName,
  );
  ConfigTransferDocument? _document;
  bool _busy = false;
  String? _error;
  bool get _isTask => widget.taskName != null;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text((_isTask ? I18n.taskJsonImport : I18n.configJsonImport).tr),
      content: SizedBox(
        width: 430,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                (_isTask ? I18n.taskJsonImportHelp : I18n.configJsonImportHelp)
                    .tr,
              ),
              const SizedBox(height: 12),
              if (_isTask)
                Text('${widget.configName} / ${widget.taskName!.tr}')
              else
                TextField(
                  controller: _name,
                  enabled: !_busy,
                  decoration: InputDecoration(labelText: I18n.newName.tr),
                ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const ValueKey('json-pick'),
                onPressed: _busy ? null : _pickFile,
                icon: const Icon(Icons.file_open_outlined),
                label: Text(I18n.configJsonChoose.tr),
              ),
              if (_document != null)
                Text(
                  '${_document!.fileName} · ${(_document!.bytes.length / 1024).toStringAsFixed(1)} KiB',
                ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(I18n.cancel.tr),
        ),
        FilledButton(
          key: const ValueKey('json-import'),
          onPressed: _busy || _document == null ? null : _import,
          child: _busy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(I18n.configJsonImportAction.tr),
        ),
      ],
    ),
  );

  Future<void> _pickFile() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.ensureSupported();
      final document = await widget.files.pickJson();
      if (mounted && document != null) setState(() => _document = document);
    } catch (e) {
      if (mounted) {
        setState(() {
          _document = null;
          _error = _message(e);
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    final document = _document;
    if (document == null) return;
    final guardError = widget.guard?.call();
    final nameError = _isTask
        ? null
        : validateConfigImportName(_name.text.trim(), widget.existingNames);
    final error = guardError ?? nameError;
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = _isTask
          ? await widget.api.importTask(
              widget.configName!,
              widget.taskName!,
              document,
            )
          : await widget.api.importConfig(_name.text.trim(), document);
      if (mounted) Navigator.of(context).pop(result);
    } catch (e) {
      if (mounted) setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _ConfigJsonExportDialog extends StatefulWidget {
  const _ConfigJsonExportDialog({
    required this.configName,
    required this.mode,
    required this.api,
    required this.files,
    this.taskName,
  });
  final String configName;
  final String? taskName;
  final ConfigExportMode mode;
  final ConfigTransferApi api;
  final ConfigTransferFiles files;
  @override
  State<_ConfigJsonExportDialog> createState() =>
      _ConfigJsonExportDialogState();
}

class _ConfigJsonExportDialogState extends State<_ConfigJsonExportDialog> {
  bool _busy = false;
  String? _error;
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(
        (widget.mode == ConfigExportMode.backup
                ? I18n.configJsonBackup
                : I18n.configJsonShare)
            .tr,
      ),
      content: SizedBox(
        width: 430,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.configName}${widget.taskName == null ? '' : ' / ${widget.taskName!.tr}'}',
            ),
            const SizedBox(height: 12),
            Text(
              (widget.mode == ConfigExportMode.backup
                      ? I18n.configJsonBackupHelp
                      : I18n.configJsonShareHelp)
                  .tr,
            ),
            Text(I18n.configJsonSavedValues.tr),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(I18n.cancel.tr),
        ),
        FilledButton(
          key: const ValueKey('json-export'),
          onPressed: _busy ? null : _export,
          child: _busy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(I18n.configJsonSave.tr),
        ),
      ],
    ),
  );

  Future<void> _export() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.ensureSupported();
      final defaultName = transferFileName(
        '${widget.configName}${widget.taskName == null ? '' : '-${widget.taskName}'}-${widget.mode.name}.json',
      );
      final selected = await widget.files.chooseSavePath(defaultName);
      if (selected == null || selected.trim().isEmpty) return;
      final path = selected.toLowerCase().endsWith('.json')
          ? selected
          : '$selected.json';
      final result = await widget.api.export(
        widget.configName,
        widget.mode,
        taskName: widget.taskName,
      );
      await widget.files.writeJson(path, result.bytes);
      if (mounted) Navigator.of(context).pop(path);
    } catch (e) {
      if (mounted) setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

String _message(Object error) =>
    error is ConfigTransferException ? error.message : '操作失败，请检查文件权限或后端连接后重试。';
