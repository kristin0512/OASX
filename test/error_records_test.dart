import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oasx/modules/home/controllers/error_records_controller.dart';
import 'package:oasx/modules/home/models/error_record_models.dart';
import 'package:oasx/modules/home/widgets/error_records_panel.dart';
import 'package:oasx/service/error_records_repository.dart';

class PendingRepository implements ErrorRecordsRepository {
  final requests = <String, Completer<ErrorRecordDetail>>{};
  final summaries = [
    const ErrorRecordSummary(
      id: 'one',
      occurredAt: 'one',
      title: 'one',
      scriptName: 'test',
    ),
    const ErrorRecordSummary(
      id: 'two',
      occurredAt: 'two',
      title: 'two',
      scriptName: 'test',
    ),
  ];
  @override
  Future<List<ErrorRecordSummary>> listRecords() async => summaries;
  @override
  Future<ErrorRecordDetail> readRecord(ErrorRecordSummary record) =>
      (requests[record.id] = Completer<ErrorRecordDetail>()).future;
}

class PendingListRepository extends PendingRepository {
  final first = Completer<List<ErrorRecordSummary>>();
  int calls = 0;
  @override
  Future<List<ErrorRecordSummary>> listRecords() {
    calls++;
    return calls == 1 ? first.future : Future.value(summaries);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('oasx-error-records-');
    await File('${root.path}/server.py').writeAsString('');
    await File('${root.path}/script.py').writeAsString('');
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<Directory> archive(String id) =>
      Directory('${root.path}/log/error/$id').create(recursive: true);

  test(
    'matches real mainline timestamp layout without inventing owner',
    () async {
      final old = await archive('1791147994842');
      await File(
        '${old.path}/log.txt',
      ).writeAsString('GameStuckError: fixture');
      await File(
        '${old.path}/2026-10-05_10-00-00-001000.png',
      ).writeAsBytes([137, 80, 78, 71]);
      await archive('account_1791234394842');
      await archive('not-an-error');
      final repo = LocalErrorRecordsRepository(root.path);
      final records = await repo.listRecords();
      expect(records.length, 2);
      expect(records.first.scriptName, 'account');
      expect(records.last.scriptName, isNull);
      final detail = await repo.readRecord(records.last);
      expect(detail.logText, contains('GameStuckError'));
      expect(detail.images.single.name, endsWith('.png'));
    },
  );

  test('partially written archive can be reread once complete', () async {
    final directory = await archive('1791147994842');
    final repo = LocalErrorRecordsRepository(root.path);
    final record = (await repo.listRecords()).single;
    expect((await repo.readRecord(record)).warning, contains('尚未写入'));
    await File('${directory.path}/log.txt').writeAsString('completed');
    expect((await repo.readRecord(record)).logText, 'completed');
    await directory.delete(recursive: true);
    await expectLater(
      repo.readRecord(record),
      throwsA(isA<FileSystemException>()),
    );
  });

  test(
    'large log reads bounded tail and oversized images are skipped',
    () async {
      final directory = await archive('1791147994842');
      final log = File('${directory.path}/log.txt');
      await log.writeAsBytes(
        Uint8List(LocalErrorRecordsRepository.maxLogBytes + 100),
      );
      await log.writeAsString('ERROR-tail', mode: FileMode.append);
      final image = await File(
        '${directory.path}/huge.png',
      ).open(mode: FileMode.write);
      await image.truncate(LocalErrorRecordsRepository.maxImageBytes + 1);
      await image.close();
      final repo = LocalErrorRecordsRepository(root.path);
      final detail = await repo.readRecord((await repo.listRecords()).single);
      expect(detail.logText, endsWith('ERROR-tail'));
      expect(detail.logText.length, LocalErrorRecordsRepository.maxLogBytes);
      expect(detail.images, isEmpty);
      expect(detail.warning, contains('512 KB'));
    },
  );

  test('invalid ids cannot traverse outside archive root', () async {
    await archive('1791147994842');
    final repo = LocalErrorRecordsRepository(root.path);
    for (final id in [
      '../1791147994842',
      r'..\1791147994842',
      'C:1791147994842',
    ]) {
      await expectLater(
        repo.readRecord(ErrorRecordSummary(id: id, occurredAt: '', title: '')),
        throwsA(isA<FileSystemException>()),
      );
    }
  });

  test(
    'archive roots require an explicit mapping for each backend address',
    () {
      expect(
        ErrorRecordsController.resolveLocalRoot('http://127.0.0.1:22289', null),
        isNull,
      );
      for (final address in [
        'http://127.0.0.1:22288',
        'http://127.0.0.1:22391',
        'http://example.com:22289',
        'http://127.0.0.1:22289/other',
        'http://user@127.0.0.1:22289',
      ]) {
        expect(ErrorRecordsController.resolveLocalRoot(address, null), isNull);
      }
      expect(
        ErrorRecordsController.resolveLocalRoot('http://other:22289', {
          'http://other:22289': root.path,
        }),
        root.path,
      );
    },
  );

  test(
    'preview bypasses injected disk repository and backend address; generated PNG decodes',
    () async {
      final controller = ErrorRecordsController(
        scriptName: 'unrelated-live-account',
        preview: true,
        repository: LocalErrorRecordsRepository('Z:/must-never-read'),
        backendAddress: () =>
            throw StateError('preview must not consult address'),
      );
      await controller.refresh();
      expect(controller.records.length, 2);
      expect(controller.localRoot, isNull);
      expect(controller.canChooseLocalRoot, isFalse);
      await controller.select(controller.records.first);
      final firstText = controller.detail!.logText;
      final codec = await ui.instantiateImageCodec(
        controller.detail!.images.single.bytes,
      );
      final image = (await codec.getNextFrame()).image;
      expect(image.width, 320);
      image.dispose();
      codec.dispose();
      await controller.select(controller.records.last);
      expect(controller.detail!.logText, isNot(firstText));
      await controller.setLocalRoot('Z:/must-never-read');
      controller.dispose();
    },
  );

  test(
    'late selection cannot replace new detail or notify disposed controller',
    () async {
      final repo = PendingRepository();
      final controller = ErrorRecordsController(
        scriptName: 'test',
        preview: false,
        repository: repo,
      );
      await controller.refresh();
      final first = controller.select(repo.summaries.first);
      final second = controller.select(repo.summaries.last);
      repo.requests['two']!.complete(
        ErrorRecordDetail(summary: repo.summaries.last, logText: 'new'),
      );
      await second;
      repo.requests['one']!.complete(
        ErrorRecordDetail(summary: repo.summaries.first, logText: 'old'),
      );
      await first;
      expect(controller.detail!.logText, 'new');
      final pending = controller.select(repo.summaries.first);
      controller.dispose();
      repo.requests['one']!.complete(
        ErrorRecordDetail(
          summary: repo.summaries.first,
          logText: 'after-dispose',
        ),
      );
      await pending;
    },
  );

  test('refresh rereads selected partial detail', () async {
    final directory = await archive('test_1791147994842');
    final controller = ErrorRecordsController(
      scriptName: 'test',
      preview: false,
      repository: LocalErrorRecordsRepository(root.path),
    );
    await controller.refresh();
    await controller.select(controller.records.single);
    expect(controller.detail!.logText, isEmpty);
    await File('${directory.path}/log.txt').writeAsString('finished');
    await controller.refresh();
    expect(controller.detail!.logText, 'finished');
    controller.dispose();
  });

  test(
    'backend changes during list and detail loads recover without stuck loading',
    () async {
      final repository = PendingListRepository();
      var address = 'http://127.0.0.1:22289';
      final controller = ErrorRecordsController(
        scriptName: 'test',
        preview: false,
        repository: repository,
        backendAddress: () => address,
      );
      final first = controller.refresh();
      address = 'http://127.0.0.1:22290';
      repository.first.complete([]);
      await first;
      expect(controller.loading, isFalse);
      expect(controller.records, isEmpty);
      // An invisible panel does not spawn more disk reads after source changes.
      expect(repository.calls, 1);
      await controller.refresh();
      expect(repository.calls, 2);
      expect(controller.loading, isFalse);
      expect(controller.records.length, 2);
      final detail = controller.select(controller.records.first);
      address = 'http://127.0.0.1:22291';
      repository.requests['one']!.complete(
        ErrorRecordDetail(
          summary: repository.summaries.first,
          logText: 'old-source',
        ),
      );
      await detail;
      expect(controller.loading, isFalse);
      expect(controller.detailLoading, isFalse);
      expect(controller.selected, isNull);
      expect(controller.detail, isNull);
      controller.dispose();
    },
  );

  Future<void> manifest(Directory directory, String owner) =>
      File('${directory.path}/metadata.json').writeAsString(
        jsonEncode({
          'version': 1,
          'config_name': owner,
          'timestamp_ms': LocalErrorRecordsRepository.summaryForName(
            directory.path.replaceAll('\\', '/').split('/').last,
          )!.timestampMs,
        }),
      );

  test(
    'metadata and legacy prefix are isolated to exact selected account',
    () async {
      final owned = await archive('1791147994842');
      await manifest(owned, '01-测试');
      await archive('09_1791234394842');
      await archive('1791248563357'); // Unknown legacy owner is not guessed.
      final first = LocalErrorRecordsRepository(root.path, scriptName: '01-测试');
      final ninth = LocalErrorRecordsRepository(root.path, scriptName: '09');
      expect((await first.listRecords()).map((record) => record.id), [
        '1791147994842',
      ]);
      expect((await ninth.listRecords()).map((record) => record.id), [
        '09_1791234394842',
      ]);
      expect(
        await LocalErrorRecordsRepository(
          root.path,
          scriptName: '1',
        ).listRecords(),
        isEmpty,
      );
      expect(
        await LocalErrorRecordsRepository(
          root.path,
          scriptName: '',
        ).listRecords(),
        isEmpty,
      );
    },
  );

  test(
    'malformed oversized or conflicting metadata does not fall back to prefix',
    () async {
      final malformed = await archive('test_1791147994842');
      await File('${malformed.path}/metadata.json').writeAsString('{');
      final conflict = await archive('test_1791234394842');
      await manifest(conflict, 'other');
      final oversized = await archive('test_1791248563357');
      await File('${oversized.path}/metadata.json').writeAsBytes(
        Uint8List(LocalErrorRecordsRepository.maxMetadataBytes + 1),
      );
      expect(
        await LocalErrorRecordsRepository(
          root.path,
          scriptName: 'test',
        ).listRecords(),
        isEmpty,
      );
      expect(
        await LocalErrorRecordsRepository(
          root.path,
          scriptName: 'other',
        ).listRecords(),
        isEmpty,
      );
    },
  );

  test(
    'details revalidate actual owner and reject forged or obsolete summaries',
    () async {
      final directory = await archive('1791147994842');
      await manifest(directory, 'test');
      final repository = LocalErrorRecordsRepository(
        root.path,
        scriptName: 'test',
      );
      final record = (await repository.listRecords()).single;
      await manifest(directory, 'other');
      await expectLater(
        repository.readRecord(record),
        throwsA(isA<FileSystemException>()),
      );
      final unknown = await archive('1791234394842');
      await File(
        '${unknown.path}/log.txt',
      ).writeAsString('private-other-account-log');
      await expectLater(
        repository.readRecord(
          const ErrorRecordSummary(
            id: '1791234394842',
            occurredAt: '',
            title: '',
            scriptName: 'test',
          ),
        ),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test(
    'controller rejects foreign unknown and mismatched detail records',
    () async {
      final repository = PendingRepository();
      repository.summaries.add(
        const ErrorRecordSummary(
          id: 'foreign',
          occurredAt: '',
          title: '',
          scriptName: 'other',
        ),
      );
      repository.summaries.add(
        const ErrorRecordSummary(id: 'unknown', occurredAt: '', title: ''),
      );
      final controller = ErrorRecordsController(
        scriptName: 'test',
        preview: false,
        repository: repository,
      );
      await controller.refresh();
      expect(controller.records.length, 2);
      await controller.select(repository.summaries[2]);
      expect(repository.requests, isEmpty);
      await controller.select(repository.summaries[3]);
      expect(repository.requests, isEmpty);
      final detail = controller.select(repository.summaries.first);
      repository.requests['one']!.complete(
        ErrorRecordDetail(
          summary: repository.summaries.first.withScriptName('other'),
          logText: 'must-not-be-rendered',
        ),
      );
      await detail;
      expect(controller.detail, isNull);
      expect(controller.detailError, contains('不属于当前账号'));
      controller.dispose();
    },
  );

  test(
    'account switch clears details immediately and ignores old responses',
    () async {
      final repository = PendingListRepository();
      repository.summaries.add(
        const ErrorRecordSummary(
          id: 'other-record',
          occurredAt: '',
          title: '',
          scriptName: 'other',
        ),
      );
      final controller = ErrorRecordsController(
        scriptName: 'test',
        preview: false,
        repository: repository,
      );
      final loading = controller.refresh();
      controller.setScriptName('other');
      repository.first.complete(repository.summaries);
      await loading;
      expect(controller.records, isEmpty);
      expect(controller.loading, isFalse);
      await controller.refresh();
      expect(controller.records.single.id, 'other-record');
      final detail = controller.select(controller.records.single);
      controller.setScriptName('test');
      expect(controller.selected, isNull);
      expect(controller.detail, isNull);
      repository.requests['other-record']!.complete(
        ErrorRecordDetail(
          summary: repository.summaries.last,
          logText: 'old-account-detail',
        ),
      );
      await detail;
      expect(controller.detail, isNull);
      await controller.refresh();
      expect(controller.records.length, 2);
      expect(controller.sourceLabel, contains('test'));
      expect(controller.sourceLabel, isNot(contains('全部')));
      controller.dispose();
    },
  );

  String savedReference(String id) =>
      '2026-10-06 12:00:00.001 | script.py:0114 | WARNING | Saving error: ./log/error/$id\n';

  test(
    'old running workers gain ownership from exact appended daily log reference',
    () async {
      await archive('1791147994842');
      final daily = File('${root.path}/log/2026-10-06_01-测试.txt');
      await daily.writeAsString('INFO: ordinary startup\n');
      final repository = LocalErrorRecordsRepository(
        root.path,
        scriptName: '01-测试',
      );
      expect(await repository.listRecords(), isEmpty);
      await daily.writeAsString(
        savedReference('1791147994842'),
        mode: FileMode.append,
      );
      // A new repository instance must reuse the bounded incremental index.
      final refreshed = LocalErrorRecordsRepository(
        root.path,
        scriptName: '01-测试',
      );
      final record = (await refreshed.listRecords()).single;
      expect(record.id, '1791147994842');
      expect((await refreshed.readRecord(record)).summary.scriptName, '01-测试');
      await daily.writeAsString('new log after rotation\n');
      expect(await refreshed.listRecords(), isEmpty);
    },
  );

  test(
    'ambiguous daily references and similar ids are not assigned to selected account',
    () async {
      await archive('1791147994842');
      await archive('1791234394842');
      await File('${root.path}/log/2026-10-06_01-测试.txt').writeAsString(
        '${savedReference('1791147994842')}${savedReference('17912343948420')}'
        'INFO | Saving error: ./log/error/1791234394842\n',
      );
      await File(
        '${root.path}/log/2026-10-06_09.txt',
      ).writeAsString(savedReference('1791147994842'));
      expect(
        await LocalErrorRecordsRepository(
          root.path,
          scriptName: '01-测试',
        ).listRecords(),
        isEmpty,
      );
      expect(
        await LocalErrorRecordsRepository(
          root.path,
          scriptName: '09',
        ).listRecords(),
        isEmpty,
      );
    },
  );

  testWidgets(
    'account widget update removes old account records before any new load',
    (tester) async {
      final repository = PendingRepository();
      final controller = ErrorRecordsController(
        scriptName: 'test',
        preview: false,
        repository: repository,
      );
      await controller.refresh();
      Widget panel(String account) => MaterialApp(
        home: Scaffold(
          body: ErrorRecordsPanel(
            scriptName: account,
            active: false,
            header: const Text('错误'),
            controller: controller,
          ),
        ),
      );
      await tester.pumpWidget(panel('test'));
      expect(find.text('test · 错误记录'), findsOneWidget);
      expect(find.byKey(const ValueKey('error-record-one')), findsOneWidget);
      await tester.pumpWidget(panel('other'));
      expect(find.text('other · 错误记录'), findsOneWidget);
      expect(find.byKey(const ValueKey('error-record-one')), findsNothing);
      expect(controller.records, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );
}
