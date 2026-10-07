import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:oasx/modules/home/controllers/error_records_controller.dart';
import 'package:oasx/modules/home/models/error_record_models.dart';

/// Saved scenes are isolated to the currently selected account.
class ErrorRecordsPanel extends StatefulWidget {
  const ErrorRecordsPanel({
    super.key,
    required this.scriptName,
    required this.active,
    required this.header,
    this.controller,
  });

  final String scriptName;
  final bool active;
  final Widget header;
  final ErrorRecordsController? controller;

  @override
  State<ErrorRecordsPanel> createState() => _ErrorRecordsPanelState();
}

class _ErrorRecordsPanelState extends State<ErrorRecordsPanel> {
  late final ErrorRecordsController _controller;
  bool _saving = false;
  ErrorRecordDetail? _renderedDetail;
  List<String> _logLines = const [];

  @override
  void initState() {
    super.initState();
    _controller =
        widget.controller ??
        ErrorRecordsController(scriptName: widget.scriptName);
    // An injected controller may still hold the previously selected account.
    // Synchronize before the first frame or starting archive observation.
    _controller.setScriptName(widget.scriptName);
    _controller.setVisible(widget.active);
  }

  @override
  void didUpdateWidget(covariant ErrorRecordsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scriptName != widget.scriptName) {
      _controller.setScriptName(widget.scriptName);
    }
    if (oldWidget.active != widget.active) {
      _controller.setVisible(widget.active);
    }
  }

  @override
  void dispose() {
    _controller.setVisible(false);
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final detail = _controller.detail;
        final sourceLabel = widget.scriptName.isEmpty
            ? '当前未选择账号'
            : _controller.sourceLabel;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                widget.header,
                const Spacer(),
                _toolbarButton(
                  tooltip: '刷新错误记录',
                  icon: Icons.refresh_rounded,
                  onPressed: _controller.loading || _controller.detailLoading
                      ? null
                      : _controller.refresh,
                ),
                if (_controller.selected != null) ...[
                  _toolbarButton(
                    tooltip: '复制错误日志',
                    icon: Icons.content_copy_rounded,
                    onPressed: detail == null
                        ? null
                        : () => _copyLog(detail.logText),
                  ),
                  _toolbarButton(
                    tooltip: '保存错误日志',
                    icon: Icons.download_rounded,
                    onPressed: detail == null || _saving
                        ? null
                        : () => _saveLog(detail),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Tooltip(
                    message: _controller.localRoot ?? sourceLabel,
                    child: Text(
                      sourceLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                if (_controller.canChooseLocalRoot)
                  _toolbarButton(
                    tooltip: '选择 OAS 日志所在目录',
                    icon: Icons.folder_open_outlined,
                    onPressed: _chooseDirectory,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _controller.selected == null
                  ? _buildRecordList(context)
                  : _buildDetail(context),
            ),
          ],
        );
      },
    );
  }

  Widget _toolbarButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon, size: 20),
      onPressed: onPressed,
      constraints: const BoxConstraints.tightFor(width: 36, height: 36),
      padding: const EdgeInsets.all(6),
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _buildRecordList(BuildContext context) {
    final records = _controller.records;
    if (widget.scriptName.isEmpty) {
      return const _ErrorPlaceholder(
        message: '请先选择账号',
        description: '选中账号后，这里会显示该账号的错误记录。',
      );
    }
    if (_controller.loading && records.isEmpty) {
      return const _ErrorPlaceholder(loading: true, message: '正在读取错误记录…');
    }
    if (_controller.error != null && records.isEmpty) {
      return _ErrorPlaceholder(
        message: _controller.error!,
        retry: _controller.refresh,
      );
    }
    if (records.isEmpty) {
      return const _ErrorPlaceholder(
        message: '暂无错误记录',
        description: '这里只显示当前账号的错误日志和截图。',
      );
    }
    return Column(
      children: [
        if (_controller.error != null)
          _messageBanner(context, _controller.error!),
        if (_controller.loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: ListView.separated(
            key: PageStorageKey('error-record-list-${_controller.scriptName}'),
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: records.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final record = records[index];
              return Material(
                color: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  key: ValueKey('error-record-${record.id}'),
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => _controller.select(record),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Icon(
                          Icons.error_outline_rounded,
                          size: 20,
                          color: Theme.of(context).colorScheme.error,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                record.occurredAt,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                              const SizedBox(height: 3),
                              Text(
                                record.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right_rounded, size: 18),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildDetail(BuildContext context) {
    final selected = _controller.selected!;
    final detail = _controller.detail;
    if (!identical(detail, _renderedDetail)) {
      _renderedDetail = detail;
      _logLines = detail?.logText.split('\n') ?? const [];
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _toolbarButton(
              tooltip: '返回错误列表',
              icon: Icons.arrow_back_rounded,
              onPressed: _controller.clearSelection,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: SelectableText(
                selected.occurredAt,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_controller.detailLoading && detail != null)
          const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: detail == null
              ? _ErrorPlaceholder(
                  loading: _controller.detailLoading,
                  message: _controller.detailLoading
                      ? '正在读取错误现场…'
                      : _controller.detailError ?? '无法读取这条错误记录',
                  retry: _controller.detailLoading
                      ? null
                      : () => _controller.select(selected),
                )
              : SelectionArea(
                  child: CustomScrollView(
                    key: ValueKey('error-detail-${selected.id}'),
                    slivers: [
                      SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_controller.error != null)
                              _messageBanner(context, _controller.error!),
                            if (_controller.detailError != null)
                              _messageBanner(context, _controller.detailError!),
                            if (detail.warning != null)
                              _messageBanner(context, detail.warning!),
                            if (detail.images.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                child: Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: detail.images
                                      .map((image) => _buildThumbnail(image))
                                      .toList(growable: false),
                                ),
                              ),
                            if (detail.logText.isEmpty)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 16),
                                child: Text('这条记录没有可读取的错误日志。'),
                              ),
                          ],
                        ),
                      ),
                      SliverList.builder(
                        itemCount: _logLines.length,
                        itemBuilder: (context, index) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: Text(
                            _logLines[index],
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  height: 1.45,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                  color:
                                      RegExp(
                                        r'\b(ERROR|CRITICAL)\b',
                                      ).hasMatch(_logLines[index])
                                      ? Theme.of(context).colorScheme.error
                                      : null,
                                ),
                          ),
                        ),
                      ),
                      const SliverToBoxAdapter(child: SizedBox(height: 16)),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _messageBanner(BuildContext context, String message) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.errorContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(message, style: Theme.of(context).textTheme.bodySmall),
    );
  }

  Widget _buildThumbnail(ErrorRecordImage image) {
    return SizedBox(
      width: 128,
      child: Column(
        children: [
          Tooltip(
            message: '查看截图：${image.name}',
            child: InkWell(
              onTap: () => _showImage(image),
              borderRadius: BorderRadius.circular(8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(
                  image.bytes,
                  width: 128,
                  height: 80,
                  fit: BoxFit.cover,
                  cacheWidth: 256,
                  errorBuilder: (_, __, ___) => const SizedBox(
                    height: 80,
                    child: Center(child: Text('截图无法显示')),
                  ),
                ),
              ),
            ),
          ),
          _toolbarButton(
            tooltip: '保存截图：${image.name}',
            icon: Icons.download_rounded,
            onPressed: _saving ? null : () => _saveImage(image),
          ),
        ],
      ),
    );
  }

  void _showImage(ErrorRecordImage image) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960, maxHeight: 720),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        image.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    _toolbarButton(
                      tooltip: '保存截图',
                      icon: Icons.download_rounded,
                      onPressed: () => _saveImage(image),
                    ),
                    _toolbarButton(
                      tooltip: '关闭截图',
                      icon: Icons.close_rounded,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: InteractiveViewer(
                    minScale: 0.5,
                    maxScale: 5,
                    child: Center(
                      child: Image.memory(
                        image.bytes,
                        fit: BoxFit.contain,
                        cacheWidth: 1920,
                        errorBuilder: (_, __, ___) => const Text('截图无法显示'),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _copyLog(String logText) async {
    await Clipboard.setData(ClipboardData(text: logText));
    if (mounted) _notify('错误日志已复制');
  }

  Future<void> _chooseDirectory() async {
    try {
      final directory = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择主仓库 OAS 目录',
        initialDirectory: _controller.localRoot,
      );
      if (directory != null && mounted) {
        await _controller.setLocalRoot(directory);
      }
    } catch (error) {
      if (mounted) _notify('无法选择日志目录：$error');
    }
  }

  Future<void> _saveLog(ErrorRecordDetail detail) {
    return _saveBytes(
      '错误日志-${detail.summary.id}.txt',
      Uint8List.fromList(utf8.encode(detail.logText)),
      const ['txt'],
    );
  }

  Future<void> _saveImage(ErrorRecordImage image) {
    final extension = image.name.split('.').last.toLowerCase();
    return _saveBytes(image.name, image.bytes, [extension]);
  }

  Future<void> _saveBytes(
    String name,
    Uint8List bytes,
    List<String> extensions,
  ) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '保存错误现场文件',
        fileName: name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_'),
        type: FileType.custom,
        allowedExtensions: extensions,
      );
      if (path == null) return;
      await File(path).writeAsBytes(bytes, flush: true);
      if (mounted) _notify('已保存到 $path');
    } catch (error) {
      if (mounted) _notify('保存失败：$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _notify(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }
}

class _ErrorPlaceholder extends StatelessWidget {
  const _ErrorPlaceholder({
    required this.message,
    this.description,
    this.loading = false,
    this.retry,
  });

  final String message;
  final String? description;
  final bool loading;
  final VoidCallback? retry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading)
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(
                retry == null
                    ? Icons.task_alt_rounded
                    : Icons.error_outline_rounded,
              ),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            if (description != null) ...[
              const SizedBox(height: 8),
              Text(
                description!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (retry != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: OutlinedButton.icon(
                  onPressed: retry,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('重试'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
