import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:get_storage/get_storage.dart';
import 'package:oasx/api/api_client.dart';
import 'package:oasx/modules/home/models/error_record_models.dart';
import 'package:oasx/service/error_records_repository.dart';
import 'package:oasx/service/profile_service.dart';

/// A read-only archive browser. This does not start or stop any script.
class ErrorRecordsController extends ChangeNotifier {
  ErrorRecordsController({
    required String scriptName,
    ErrorRecordsRepository? repository,
    bool preview = ProfileService.isPreview,
    String Function()? backendAddress,
  }) : _scriptName = scriptName,
       _preview = preview,
       _override = preview ? null : repository,
       _backendAddress =
           backendAddress ??
           (repository == null
               ? (() => ApiClient().address)
               : (() => 'injected'));

  String _scriptName;
  String get scriptName => _scriptName;
  final bool _preview;
  final ErrorRecordsRepository? _override;
  final String Function() _backendAddress;
  Timer? _timer;
  bool _disposed = false;
  bool _visible = false;
  int _listGeneration = 0;
  int _detailGeneration = 0;
  String? _lastSource;
  bool loading = false;
  String? error;
  List<ErrorRecordSummary> records = [];
  ErrorRecordSummary? selected;
  bool detailLoading = false;
  String? detailError;
  ErrorRecordDetail? detail;

  String get sourceLabel =>
      _preview ? '演示 · $scriptName 的错误记录' : '$scriptName · 错误记录';
  bool get canChooseLocalRoot => !_preview && _override == null && !kIsWeb;

  String get _address {
    final value = _backendAddress().trim();
    return value.endsWith('/') ? value.substring(0, value.length - 1) : value;
  }

  /// Exact address binding avoids displaying another installation's archives.
  String? get localRoot {
    if (_preview) return null;
    final override = _override;
    if (override != null) {
      return override is LocalErrorRecordsRepository ? override.rootPath : null;
    }
    return resolveLocalRoot(_address, GetStorage().read('errorArchiveRoots'));
  }

  @visibleForTesting
  static String? resolveLocalRoot(String address, dynamic stored) {
    if (stored is Map &&
        stored[address] is String &&
        (stored[address] as String).trim().isNotEmpty) {
      return stored[address] as String;
    }
    // Each installation chooses its own archive directory explicitly.
    return null;
  }

  String get _sourceKey => _preview
      ? 'preview|$scriptName'
      : '$_address|${localRoot ?? ''}|$scriptName';

  ErrorRecordsRepository _repository() {
    if (_preview) return PreviewErrorRecordsRepository(scriptName: scriptName);
    if (_override != null) return _override;
    if (kIsWeb) throw StateError('错误现场需要在桌面客户端读取本机 OAS 目录');
    final root = localRoot;
    if (root == null) {
      throw StateError('请为当前服务选择对应的本机 OAS 目录；远程服务需要先将错误档案复制到本机');
    }
    return LocalErrorRecordsRepository(root, scriptName: scriptName);
  }

  void setScriptName(String account) {
    if (_disposed || account == _scriptName) return;
    _scriptName = account;
    _listGeneration++;
    _detailGeneration++;
    _lastSource = null;
    records = [];
    selected = null;
    detail = null;
    error = detailError = null;
    loading = detailLoading = false;
    notifyListeners();
    if (_visible) unawaited(refresh());
  }

  Future<void> setLocalRoot(String path) async {
    if (!canChooseLocalRoot || path.trim().isEmpty) return;
    final address = _address;
    // Validate the explicit selection before binding it to this address.
    await LocalErrorRecordsRepository(path).listRecords();
    if (_disposed || _address != address) return;
    final stored = GetStorage().read('errorArchiveRoots');
    final roots = stored is Map
        ? Map<String, dynamic>.from(stored)
        : <String, dynamic>{};
    roots[address] = path;
    await GetStorage().write('errorArchiveRoots', roots);
    if (!_disposed) await refresh();
  }

  void setVisible(bool visible) {
    if (_disposed) return;
    _visible = visible;
    _timer?.cancel();
    _timer = null;
    if (!visible) return;
    unawaited(refresh());
    _timer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (!loading || _lastSource != _sourceKey) unawaited(refresh());
    });
  }

  Future<void> refresh() async {
    if (_disposed) return;
    final generation = ++_listGeneration;
    final source = _sourceKey;
    if (_lastSource != source) {
      _lastSource = source;
      records = [];
      selected = null;
      detail = null;
      detailError = null;
      detailLoading = false;
      _detailGeneration++;
    }
    loading = true;
    error = null;
    notifyListeners();
    try {
      final result = await _repository().listRecords();
      if (_disposed || generation != _listGeneration) return;
      if (source != _sourceKey) {
        await _sourceChanged();
        return;
      }
      records = result
          .where((record) => record.belongsTo(scriptName))
          .toList(growable: false);
      loading = false;
      notifyListeners();
      final current = selected;
      if (current != null) {
        if (records.any((record) => record.id == current.id)) {
          // Archives may still be writing PNG files or log.txt when first seen.
          await select(current, quiet: true);
        } else {
          clearSelection();
        }
      }
    } catch (failure) {
      if (_disposed || generation != _listGeneration) return;
      if (source != _sourceKey) {
        await _sourceChanged();
        return;
      }
      loading = false;
      error = _message(failure);
      notifyListeners();
    }
  }

  Future<void> select(ErrorRecordSummary record, {bool quiet = false}) async {
    if (_disposed) return;
    if (!record.belongsTo(scriptName) ||
        !records.any(
          (candidate) =>
              candidate.id == record.id && candidate.belongsTo(scriptName),
        )) {
      clearSelection();
      detailError = '错误记录不属于当前账号';
      notifyListeners();
      return;
    }
    final generation = ++_detailGeneration;
    final source = _sourceKey;
    final keepDetail = quiet && selected?.id == record.id;
    selected = record;
    if (!keepDetail) detail = null;
    detailLoading = !keepDetail;
    detailError = null;
    notifyListeners();
    try {
      final result = await _repository().readRecord(record);
      if (_disposed || generation != _detailGeneration) return;
      if (source != _sourceKey) {
        await _sourceChanged();
        return;
      }
      if (!result.summary.belongsTo(scriptName) ||
          result.summary.id != record.id) {
        throw StateError('错误记录不属于当前账号');
      }
      detail = result;
      detailLoading = false;
      notifyListeners();
    } catch (failure) {
      if (_disposed || generation != _detailGeneration) return;
      if (source != _sourceKey) {
        await _sourceChanged();
        return;
      }
      detailLoading = false;
      detailError = _message(failure);
      notifyListeners();
    }
  }

  void clearSelection() {
    if (_disposed) return;
    _detailGeneration++;
    selected = null;
    detail = null;
    detailError = null;
    detailLoading = false;
    notifyListeners();
  }

  Future<void> _sourceChanged() async {
    if (_disposed) return;
    loading = false;
    records = [];
    clearSelection();
    if (_visible) await refresh();
  }

  static String _message(Object failure) => failure.toString().replaceFirst(
    RegExp(r'^(Bad state: |FileSystemException: )'),
    '',
  );

  @override
  void dispose() {
    _disposed = true;
    _listGeneration++;
    _detailGeneration++;
    _timer?.cancel();
    super.dispose();
  }
}
