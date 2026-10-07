import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:oasx/api/config_transfer_api.dart';
import 'package:oasx/api/config_transfer_models.dart';
import 'package:oasx/modules/common/widgets/config_transfer_dialog.dart';
import 'package:oasx/service/config_transfer_files.dart';
import 'package:oasx/translation/i18n.dart';

const _capabilities = {
  'version': 1,
  'max_bytes': configTransferMaxBytes,
  'modes': ['backup', 'share'],
  'config_import': true,
  'task_import': true,
};

class _MemoryFiles extends ConfigTransferFiles {
  bool cancelled = false;
  int writes = 0;
  @override
  Future<ConfigTransferDocument?> pickJson() async => cancelled
      ? null
      : ConfigTransferDocument.parse('demo.json', utf8.encode('{"Chess":{}}'));
  @override
  Future<String?> chooseSavePath(String fileName) async => null;
  @override
  Future<void> writeJson(String path, Uint8List bytes) async {
    writes++;
  }
}

Widget _frame(Widget child) => GetMaterialApp(
  translations: Messages(),
  locale: const Locale('zh', 'CN'),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  tearDown(() => Get.reset());

  testWidgets(
    'unsaved edits/running guard prevents task POST without discarding drafts',
    (tester) async {
      final writes = <String>[];
      final api = ConfigTransferApi((request) async {
        writes.add(request.path);
        return const ConfigTransferResponse(200, _capabilities);
      });
      await tester.pumpWidget(
        _frame(
          ConfigJsonImportDialog(
            api: api,
            files: _MemoryFiles(),
            configName: 'demo',
            taskName: 'Chess',
            guard: () => '请先保存参数修改',
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('json-pick')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('json-import')));
      await tester.pumpAndSettle();
      expect(find.text('请先保存参数修改'), findsOneWidget);
      expect(writes, ['/config/transfer/capabilities']);
    },
  );

  testWidgets(
    'picker cancellation never submits and an existing name is rejected locally',
    (tester) async {
      final writes = <String>[];
      final files = _MemoryFiles()..cancelled = true;
      final api = ConfigTransferApi((request) async {
        writes.add(request.path);
        return const ConfigTransferResponse(200, _capabilities);
      });
      await tester.pumpWidget(
        _frame(
          ConfigJsonImportDialog(
            api: api,
            files: files,
            initialName: 'demo',
            existingNames: const ['demo'],
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('json-pick')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('json-import')))
            .onPressed,
        isNull,
      );
      files.cancelled = false;
      await tester.tap(find.byKey(const ValueKey('json-pick')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('json-import')));
      await tester.pumpAndSettle();
      expect(find.textContaining('名称已存在'), findsOneWidget);
      expect(writes, ['/config/transfer/capabilities']);
    },
  );

  testWidgets(
    'cancelled export save dialog performs no export request/file write',
    (tester) async {
      final requests = <String>[];
      final files = _MemoryFiles();
      final api = ConfigTransferApi((request) async {
        requests.add(request.path);
        return const ConfigTransferResponse(200, _capabilities);
      });
      await tester.pumpWidget(
        _frame(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => ConfigTransferDialogs.exportJson(
                context,
                'demo',
                ConfigExportMode.backup,
                api: api,
                files: files,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('私密设置'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('json-export')));
      await tester.pumpAndSettle();
      expect(requests, ['/config/transfer/capabilities']);
      expect(files.writes, 0);
    },
  );
}
