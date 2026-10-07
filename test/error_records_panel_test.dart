import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:get_storage/get_storage.dart';
import 'package:oasx/modules/home/controllers/error_records_controller.dart';
import 'package:oasx/modules/home/models/error_record_models.dart';
import 'package:oasx/modules/home/widgets/error_records_panel.dart';
import 'package:oasx/modules/home/widgets/log_center_panel.dart';
import 'package:oasx/modules/log/script_log_controller.dart';
import 'package:oasx/service/script_service.dart';
import 'package:oasx/service/websocket_service.dart';

const _newRecord = ErrorRecordSummary(
  id: 'new',
  occurredAt: '2026-10-05 19:48:27.186',
  title: '错误现场',
  scriptName: 'demo',
);
const _olderRecord = ErrorRecordSummary(
  id: 'old',
  occurredAt: '2026-10-04 08:11:22.333',
  title: '错误现场',
  scriptName: 'demo',
);

class _MemoryController extends ErrorRecordsController {
  _MemoryController() : super(scriptName: 'demo', preview: true) {
    records = [_newRecord, _olderRecord];
  }

  final visibleChanges = <bool>[];
  int refreshCount = 0;

  @override
  void setVisible(bool visible) => visibleChanges.add(visible);

  @override
  Future<void> refresh() async {
    refreshCount++;
    error = null;
    loading = false;
    notifyListeners();
  }

  @override
  Future<void> select(ErrorRecordSummary record, {bool quiet = false}) async {
    selected = record;
    detail = ErrorRecordDetail(
      summary: record,
      logText: 'Traceback (most recent call last):\nRuntimeError: 演示错误',
      images: [
        ErrorRecordImage(
          name: '演示截图.png',
          bytes: base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1cAAAAASUVORK5CYII=',
          ),
        ),
      ],
    );
    notifyListeners();
  }

  void changed() => notifyListeners();
}

class _OfflineScripts extends ScriptService {
  @override
  // ignore: must_call_super
  Future<void> onInit() async {}

  @override
  // ignore: must_call_super
  Future<void> onClose() async {}
}

Widget _frame(Widget child) => MaterialApp(
  theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
  home: Scaffold(
    body: Center(child: SizedBox(width: 320, height: 520, child: child)),
  ),
);

Widget _panel(_MemoryController controller) => _frame(
  ErrorRecordsPanel(
    scriptName: 'demo',
    active: true,
    controller: controller,
    header: const Text('信息 / 错误'),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory storageRoot;

  setUpAll(() async {
    storageRoot = await Directory.systemTemp.createTemp('oasx-error-ui-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => storageRoot.path,
        );
    final box = GetStorage('GetStorage', storageRoot.path);
    await box.initStorage;
  });

  setUp(() => Get.testMode = true);
  tearDown(() async => Get.reset());
  // GetStorage keeps its Windows lock file open until this test process exits.
  // This dedicated temporary profile never reads or writes a real OAS profile.

  testWidgets('320px list opens detail, zooms a screenshot and returns', (
    tester,
  ) async {
    final controller = _MemoryController();
    await tester.pumpWidget(_panel(controller));
    expect(find.text('演示 · demo 的错误记录'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text(_newRecord.occurredAt)).dy,
      lessThan(tester.getTopLeft(find.text(_olderRecord.occurredAt)).dy),
    );
    await tester.tap(find.byKey(const ValueKey('error-record-new')));
    await tester.pumpAndSettle();
    expect(find.text('RuntimeError: 演示错误'), findsOneWidget);
    expect(find.byTooltip('复制错误日志'), findsOneWidget);
    expect(find.byTooltip('保存错误日志'), findsOneWidget);
    await tester.tap(find.byTooltip('查看截图：演示截图.png'));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.tap(find.byTooltip('关闭截图'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('返回错误列表'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('error-record-new')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(controller.visibleChanges.last, false);
    controller.dispose();
  });

  testWidgets('loading, empty and failure states remain distinguishable', (
    tester,
  ) async {
    final controller = _MemoryController()..records = [];
    controller.loading = true;
    await tester.pumpWidget(_panel(controller));
    expect(find.text('正在读取错误记录…'), findsOneWidget);
    controller.loading = false;
    controller.changed();
    await tester.pump();
    expect(find.text('暂无错误记录'), findsOneWidget);
    controller.error = '目录暂时无法读取';
    controller.changed();
    await tester.pump();
    expect(find.text('目录暂时无法读取'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(controller.refreshCount, 1);
    expect(find.text('暂无错误记录'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('no selected account cannot expose an injected account archive', (
    tester,
  ) async {
    final controller = _MemoryController();
    await tester.pumpWidget(
      _frame(
        LogCenterPanel(scriptName: '', errorRecordsController: controller),
      ),
    );
    await tester.pump();
    expect(controller.scriptName, isEmpty);
    expect(find.text('当前未选择账号'), findsOneWidget);
    expect(find.byKey(const ValueKey('error-record-new')), findsNothing);
    expect(find.text('请先选择账号'), findsOneWidget);
    await tester.tap(find.text('信息'));
    await tester.pump();
    expect(controller.visibleChanges.last, false);
    expect(find.byKey(const ValueKey('error-record-new')), findsNothing);
    await tester.tap(find.text('错误'));
    await tester.pump();
    expect(controller.visibleChanges.last, true);
    expect(find.byKey(const ValueKey('error-record-new')), findsNothing);
    expect(find.text('请先选择账号'), findsOneWidget);
    expect(find.text('RuntimeError: 演示错误'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets(
    'initial injected controller mismatch clears old account detail before first frame',
    (tester) async {
      final controller = _MemoryController();
      controller.selected = _newRecord;
      controller.detail = const ErrorRecordDetail(
        summary: _newRecord,
        logText: 'old-account-secret',
      );
      await tester.pumpWidget(
        _frame(
          ErrorRecordsPanel(
            scriptName: 'other',
            active: false,
            header: const Text('错误'),
            controller: controller,
          ),
        ),
      );
      expect(controller.scriptName, 'other');
      expect(controller.records, isEmpty);
      expect(controller.selected, isNull);
      expect(controller.detail, isNull);
      expect(find.text('演示 · other 的错误记录'), findsOneWidget);
      expect(find.byKey(const ValueKey('error-record-new')), findsNothing);
      expect(find.text('old-account-secret'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets('tab switch retains live logs and pauses archive observation', (
    tester,
  ) async {
    Get.put<WebSocketService>(WebSocketService());
    Get.put<ScriptService>(_OfflineScripts());
    final logs = Get.put(
      ScriptLogController(name: 'demo'),
      tag: 'demo',
      permanent: true,
    );
    logs.logs.add('2026-10-05 19:48:27.186 | demo.py:1 | INFO | 保留的信息日志');
    final controller = _MemoryController();
    await tester.pumpWidget(
      _frame(
        LogCenterPanel(scriptName: 'demo', errorRecordsController: controller),
      ),
    );
    await tester.pump();
    expect(find.textContaining('保留的信息日志', findRichText: true), findsOneWidget);
    await tester.tap(find.text('错误'));
    await tester.pump();
    expect(find.byKey(const ValueKey('error-record-new')), findsOneWidget);
    expect(controller.visibleChanges.last, true);
    await tester.tap(find.text('信息'));
    await tester.pump();
    expect(controller.visibleChanges.last, false);
    expect(find.textContaining('保留的信息日志', findRichText: true), findsOneWidget);
    expect(logs.logs, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await Get.delete<ScriptLogController>(tag: 'demo', force: true);
  });
}
