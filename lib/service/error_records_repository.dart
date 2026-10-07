import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:oasx/modules/home/models/error_record_models.dart';

abstract class ErrorRecordsRepository {
  Future<List<ErrorRecordSummary>> listRecords();
  Future<ErrorRecordDetail> readRecord(ErrorRecordSummary record);
}

/// Reads archives already written by OAS; never imports or runs the backend.
class LocalErrorRecordsRepository implements ErrorRecordsRepository {
  LocalErrorRecordsRepository(this.rootPath, {this.scriptName});

  final String rootPath;
  final String? scriptName;
  static const maxMetadataBytes = 16 * 1024;
  static const maxLogBytes = 512 * 1024;
  static const maxImageBytes = 4 * 1024 * 1024;
  static const maxImagesBytes = 12 * 1024 * 1024;
  static const maxImages = 12;
  static const maxRecords = 500;
  static final _recordName = RegExp(r'^(?:(.+)_)?(\d{13})$');
  static final _referenceIndexes = <String, _DailyArchiveReferences>{};

  Future<Map<String, Set<String>>> _referenceOwners(Directory errorRoot) {
    final logs = errorRoot.parent;
    final key = logs.path.replaceAll('\\', '/').toLowerCase();
    if (!_referenceIndexes.containsKey(key) && _referenceIndexes.length >= 8) {
      _referenceIndexes.remove(_referenceIndexes.keys.first);
    }
    return (_referenceIndexes[key] ??= _DailyArchiveReferences()).update(logs);
  }

  static String _name(String path) =>
      path.replaceAll('\\', '/').split('/').last;

  static bool _inside(String root, String target) {
    String normalize(String value) => value.replaceAll('\\', '/').toLowerCase();
    final base = normalize(root).replaceAll(RegExp(r'/+$'), '');
    return normalize(target).startsWith('$base/');
  }

  Future<Directory?> _archiveRoot() async {
    final root = Directory(rootPath);
    if (!await root.exists()) {
      throw const FileSystemException('OAS 目录不存在，请重新选择');
    }
    final resolved = await root.resolveSymbolicLinks();
    for (final marker in ['server.py', 'script.py']) {
      if (!await File('$resolved/$marker').exists()) {
        throw const FileSystemException('所选目录不是 OAS 根目录');
      }
    }
    final errors = Directory('$resolved/log/error');
    if (!await errors.exists()) return null;
    final actual = await errors.resolveSymbolicLinks();
    if (!_inside(resolved, actual)) {
      throw const FileSystemException('错误目录位于所选 OAS 目录之外');
    }
    return Directory(actual);
  }

  Future<String?> _safeChild(
    Directory root,
    String name,
    FileSystemEntityType type,
  ) async {
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains('\\') ||
        name.contains(':')) {
      return null;
    }
    final path = '${root.path}/$name';
    if (await FileSystemEntity.type(path, followLinks: false) != type) {
      return null;
    }
    final resolved = await (type == FileSystemEntityType.directory
        ? Directory(path).resolveSymbolicLinks()
        : File(path).resolveSymbolicLinks());
    if (!_inside(root.path, resolved)) return null;
    return resolved;
  }

  static ErrorRecordSummary? summaryForName(String name) {
    final match = _recordName.firstMatch(name);
    if (match == null) return null;
    final stamp = int.tryParse(match.group(2)!);
    if (stamp == null) return null;
    final time = DateTime.fromMillisecondsSinceEpoch(stamp).toLocal();
    if (time.year < 2000 || time.year > 2100) return null;
    return ErrorRecordSummary(
      id: name,
      occurredAt: time.toString().substring(0, 23),
      title: '错误现场',
      scriptName: match.group(1),
      timestampMs: stamp,
    );
  }

  Future<ErrorRecordSummary> _ownedSummary(
    Directory archive,
    ErrorRecordSummary record,
    Map<String, Set<String>> referenceOwners,
  ) async {
    final metadataType = await FileSystemEntity.type(
      '${archive.path}/metadata.json',
      followLinks: false,
    );
    if (metadataType == FileSystemEntityType.notFound) {
      if (record.scriptName != null) return record;
      final owners = referenceOwners[record.id];
      return record.withScriptName(owners?.length == 1 ? owners!.single : null);
    }
    // A partially written/invalid manifest must not fall back to a guessed owner.
    final path = await _safeChild(
      archive,
      'metadata.json',
      FileSystemEntityType.file,
    );
    if (path == null) return record.withScriptName(null);
    try {
      final file = await File(path).open();
      dynamic metadata;
      try {
        if (await file.length() > maxMetadataBytes) {
          return record.withScriptName(null);
        }
        metadata = jsonDecode(utf8.decode(await file.read(maxMetadataBytes)));
      } finally {
        await file.close();
      }
      if (metadata is! Map || metadata['version'] != 1) {
        return record.withScriptName(null);
      }
      final owner = metadata['config_name'];
      if (owner is! String ||
          owner.isEmpty ||
          owner.length > 255 ||
          owner.trim() != owner ||
          RegExp(r'[\r\n\\/:]').hasMatch(owner) ||
          (metadata['timestamp_ms'] != null &&
              metadata['timestamp_ms'] != record.timestampMs) ||
          (record.scriptName != null && record.scriptName != owner)) {
        return record.withScriptName(null);
      }
      return record.withScriptName(owner);
    } on FileSystemException {
      return record.withScriptName(null);
    } on FormatException {
      return record.withScriptName(null);
    }
  }

  @override
  Future<List<ErrorRecordSummary>> listRecords() async {
    final root = await _archiveRoot();
    if (root == null) return [];
    final referenceOwners = await _referenceOwners(root);
    final records = <ErrorRecordSummary>[];
    await for (final entity in root.list(followLinks: false)) {
      final name = _name(entity.path);
      final summary = summaryForName(name);
      if (summary == null) continue;
      try {
        final path = await _safeChild(
          root,
          name,
          FileSystemEntityType.directory,
        );
        if (path == null) {
          continue;
        }
        final owned = await _ownedSummary(
          Directory(path),
          summary,
          referenceOwners,
        );
        if (scriptName == null || owned.belongsTo(scriptName!)) {
          records.add(owned);
        }
      } on FileSystemException {
        // The backend may prune an old directory while the list is being read.
      }
    }
    records.sort((a, b) => b.timestampMs.compareTo(a.timestampMs));
    return records.take(maxRecords).toList(growable: false);
  }

  @override
  Future<ErrorRecordDetail> readRecord(ErrorRecordSummary record) async {
    final root = await _archiveRoot();
    if (root == null || summaryForName(record.id) == null) {
      throw const FileSystemException('错误记录不存在或已被清理');
    }
    final path = await _safeChild(
      root,
      record.id,
      FileSystemEntityType.directory,
    );
    if (path == null) throw const FileSystemException('错误记录不存在或路径无效');
    final directory = Directory(path);
    final owned = await _ownedSummary(
      directory,
      summaryForName(record.id)!,
      await _referenceOwners(root),
    );
    if (scriptName != null &&
        (!owned.belongsTo(scriptName!) || !record.belongsTo(scriptName!))) {
      throw const FileSystemException('错误记录不属于当前账号');
    }
    final warnings = <String>[];
    var logText = '';
    final logPath = await _safeChild(
      directory,
      'log.txt',
      FileSystemEntityType.file,
    );
    if (logPath == null) {
      warnings.add('日志尚未写入或已不可用，可稍后刷新。');
    } else {
      final file = await File(logPath).open();
      try {
        final length = await file.length();
        if (length > maxLogBytes) {
          await file.setPosition(length - maxLogBytes);
          warnings.add('日志较长，仅显示末尾 512 KB。');
        }
        logText = utf8.decode(
          await file.read(maxLogBytes),
          allowMalformed: true,
        );
      } finally {
        await file.close();
      }
    }
    final imageNames = <String>[];
    await for (final entity in directory.list(followLinks: false)) {
      final name = _name(entity.path);
      if (name.toLowerCase().endsWith('.png')) imageNames.add(name);
    }
    imageNames.sort();
    final images = <ErrorRecordImage>[];
    var totalBytes = 0;
    if (imageNames.length > maxImages) warnings.add('截图较多，仅显示最近 12 张。');
    for (final name in imageNames.reversed.take(maxImages).toList().reversed) {
      try {
        final imagePath = await _safeChild(
          directory,
          name,
          FileSystemEntityType.file,
        );
        if (imagePath == null) continue;
        final file = await File(imagePath).open();
        try {
          final length = await file.length();
          if (length > maxImageBytes || totalBytes + length > maxImagesBytes) {
            warnings.add('部分截图过大，未载入。');
            continue;
          }
          final bytes = await file.read(maxImageBytes + 1);
          if (bytes.length > maxImageBytes ||
              totalBytes + bytes.length > maxImagesBytes) {
            continue;
          }
          images.add(ErrorRecordImage(name: name, bytes: bytes));
          totalBytes += bytes.length;
        } finally {
          await file.close();
        }
      } on FileSystemException {
        warnings.add('部分截图正在写入或已被清理。');
      }
    }
    return ErrorRecordDetail(
      summary: owned,
      logText: logText,
      images: images,
      warning: warnings.isEmpty ? null : warnings.toSet().join('\n'),
    );
  }
}

class _DailyArchiveLog {
  int size = -1;
  int offset = 0;
  DateTime? modified;
  String carry = '';
  final ids = <String>{};
}

/// Old workers still write timestamp-only archives. Prove their owner from a
/// precise reference in the original account log, not from time proximity.
class _DailyArchiveReferences {
  static const maxInitialBytes = 1024 * 1024;
  static final _dailyName = RegExp(r'^\d{4}-\d{2}-\d{2}_(.+)\.txt$');
  static final _saved = RegExp(
    r'\|\s*WARNING\s*\|\s*Saving error:\s+(?:.*?[\\/])?log[\\/]error[\\/]([^\s|]+)',
  );
  final _logs = <String, _DailyArchiveLog>{};
  Future<Map<String, Set<String>>>? _pending;

  Future<Map<String, Set<String>>> update(Directory root) {
    final pending = _pending;
    if (pending != null) return pending;
    final next = _scan(root);
    _pending = next;
    return next.whenComplete(() {
      if (identical(_pending, next)) _pending = null;
    });
  }

  Future<Map<String, Set<String>>> _scan(Directory root) async {
    final present = <String, String>{};
    try {
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = LocalErrorRecordsRepository._name(entity.path);
        final match = _dailyName.firstMatch(name);
        if (match == null) continue;
        final owner = match.group(1)!;
        if (owner.trim() != owner || RegExp(r'[\r\n\\/:]').hasMatch(owner)) {
          continue;
        }
        try {
          final resolved = await entity.resolveSymbolicLinks();
          if (!LocalErrorRecordsRepository._inside(root.path, resolved)) {
            continue;
          }
          final stat = await entity.stat();
          if (stat.type != FileSystemEntityType.file) continue;
          final state = _logs.putIfAbsent(name, _DailyArchiveLog.new);
          present[name] = owner;
          if (state.size == stat.size && state.modified == stat.modified) {
            continue;
          }
          final reset =
              state.size < 0 ||
              stat.size < state.offset ||
              (stat.size == state.offset && stat.modified != state.modified);
          if (reset) {
            state.ids.clear();
            state.carry = '';
            state.offset = stat.size > maxInitialBytes
                ? stat.size - maxInitialBytes
                : 0;
          }
          final file = await File(resolved).open();
          try {
            await file.setPosition(state.offset);
            while (state.offset < stat.size) {
              final remaining = stat.size - state.offset;
              final bytes = await file.read(
                remaining > 64 * 1024 ? 64 * 1024 : remaining,
              );
              if (bytes.isEmpty) break;
              state.offset += bytes.length;
              final lines =
                  (state.carry + utf8.decode(bytes, allowMalformed: true))
                      .split('\n');
              state.carry = lines.removeLast();
              for (final line in lines) {
                final id = _saved.firstMatch(line)?.group(1);
                if (id != null &&
                    LocalErrorRecordsRepository.summaryForName(id) != null) {
                  state.ids.add(id);
                }
              }
              if (state.carry.length > 8192) {
                state.carry = state.carry.substring(state.carry.length - 8192);
              }
            }
          } finally {
            await file.close();
          }
          state.size = stat.size;
          state.modified = stat.modified;
        } on FileSystemException {
          // Rotating logs are retried at the next normal panel refresh.
        }
      }
    } on FileSystemException {
      return {};
    }
    _logs.removeWhere((name, _) => !present.containsKey(name));
    final owners = <String, Set<String>>{};
    for (final entry in present.entries) {
      for (final id in _logs[entry.key]!.ids) {
        owners.putIfAbsent(id, () => <String>{}).add(entry.value);
      }
    }
    return owners;
  }
}

/// The preview never reads local archives, even if settings contain a real path.
class PreviewErrorRecordsRepository implements ErrorRecordsRepository {
  PreviewErrorRecordsRepository({this.scriptName = '演示账号'});
  final String scriptName;
  static const _records = [
    ErrorRecordSummary(
      id: 'demo-stuck',
      occurredAt: '2026-10-05 10:24:38.126',
      title: '演示 · 界面停滞后重启',
      scriptName: '演示-百鬼棋局',
    ),
    ErrorRecordSummary(
      id: 'demo-stopped',
      occurredAt: '2026-10-05 09:18:07.042',
      title: '演示 · 异常后停止',
      scriptName: '演示-主号日常',
    ),
  ];

  @override
  Future<List<ErrorRecordSummary>> listRecords() async =>
      _records.map((record) => record.withScriptName(scriptName)).toList();

  @override
  Future<ErrorRecordDetail> readRecord(ErrorRecordSummary record) async {
    if (!_records.any((candidate) => candidate.id == record.id) ||
        !record.belongsTo(scriptName)) {
      throw StateError('演示记录不属于当前账号');
    }
    final stopped = record.id == 'demo-stopped';
    return ErrorRecordDetail(
      summary: record,
      logText:
          '════════════════════════════════════════\n'
          '                 ${stopped ? 'DAILY TASK' : 'CHESS'}\n'
          '════════════════════════════════════════\n'
          '${stopped ? '09:18:00.000' : '10:24:28.126'} | INFO | 演示数据：开始${stopped ? '日常任务' : '百鬼棋局'}\n'
          '${stopped ? '09:18:07.042' : '10:24:38.126'} | ERROR | ${stopped ? 'RuntimeError: 演示异常后停止' : 'GameStuckError: 演示界面停滞'}\n'
          '${stopped ? '09:18:07.045' : '10:24:38.130'} | INFO | 演示数据：已保存日志和截图\n'
          '${stopped ? '09:18:07.050 | WARNING | 演示数据：服务已停止' : '10:24:38.140 | WARNING | 演示数据：计划重启游戏'}\n'
          '此处仅展示错误查看功能，不会连接或控制模拟器。',
      images: [ErrorRecordImage(name: '演示截图.png', bytes: _demoPng())],
      warning: '演示记录和示意图，不是真实账号的错误。',
    );
  }

  // A small, original schematic board image generated wholly in memory.
  static Uint8List _demoPng() {
    const width = 320, height = 180;
    final pixels = BytesBuilder();
    for (var y = 0; y < height; y++) {
      pixels.addByte(0);
      for (var x = 0; x < width; x++) {
        final board = x > 50 && x < 270 && y > 32 && y < 158;
        final line = board && ((x - 50) % 31 < 2 || (y - 32) % 25 < 2);
        final dialog = x > 110 && x < 210 && y > 62 && y < 120;
        pixels.add(
          dialog
              ? [218, 196, 149]
              : line
              ? [142, 116, 88]
              : board
              ? [91, 69, 69]
              : [37, 33, 47],
        );
      }
    }
    final output = BytesBuilder()..add([137, 80, 78, 71, 13, 10, 26, 10]);
    void chunk(String type, List<int> payload) {
      final data = [...ascii.encode(type), ...payload];
      var crc = 0xffffffff;
      for (final byte in data) {
        crc ^= byte;
        for (var bit = 0; bit < 8; bit++) {
          crc = (crc & 1) != 0 ? 0xedb88320 ^ (crc >>> 1) : crc >>> 1;
        }
      }
      final size = ByteData(4)..setUint32(0, payload.length);
      final checksum = ByteData(4)..setUint32(0, crc ^ 0xffffffff);
      output
        ..add(size.buffer.asUint8List())
        ..add(data)
        ..add(checksum.buffer.asUint8List());
    }

    final header = ByteData(13)
      ..setUint32(0, width)
      ..setUint32(4, height)
      ..setUint8(8, 8)
      ..setUint8(9, 2);
    chunk('IHDR', header.buffer.asUint8List());
    chunk('IDAT', zlib.encode(pixels.takeBytes()));
    chunk('IEND', []);
    return output.takeBytes();
  }
}
