import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:oasx/modules/args/index.dart';
import 'package:oasx/translation/i18n.dart';

class _NoNetwork extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      throw StateError('Guild argument tests must never contact an OAS server');
}

final _fixture =
    jsonDecode(File('test/fixtures/guild_opening_args.json').readAsStringSync())
        as Map<String, dynamic>;
final _additionalLabels = Map<String, String>.from(
  _fixture['additional_translations'] as Map,
);
final _labels = {...Messages().all_cn_translate, ..._additionalLabels};

List<Map<String, dynamic>> _fields(String task, String group) =>
    ((_fixture['args'] as Map)[task][group] as List)
        .map((field) => Map<String, dynamic>.from(field as Map))
        .toList();

typedef _Write = ({
  String? config,
  String? task,
  String group,
  String argument,
  String type,
  dynamic value,
});

Future<ArgsController> _mount(
  WidgetTester tester,
  String task,
  String group,
  List<Map<String, dynamic>> fields,
  List<_Write> writes, {
  bool draft = false,
}) async {
  tester.view.resetPhysicalSize();
  tester.view.physicalSize = const Size(1100, 1600);
  tester.view.devicePixelRatio = 1;
  final controller = Get.put(ArgsController());
  controller.isDraftMode.value = draft;
  controller.groupsName.value = [group];
  controller.groupsData.value = {
    group: GroupsModel(
      groupName: group,
      members: fields.map(ArgumentModel.fromJson).toList(),
    ),
  };
  await tester.pumpWidget(
    GetMaterialApp(
      translations: Messages(),
      locale: const Locale('zh', 'CN'),
      home: Scaffold(
        body: Args(
          scriptName: 'offline-fixture',
          taskName: task,
          groupDraggable: false,
          setArgumentOverride: (config, task, group, argument, type, value) {
            writes.add((
              config: config,
              task: task,
              group: group,
              argument: argument,
              type: type,
              value: value,
            ));
          },
        ),
      ),
    ),
  );
  // This is the same final merge used by LocaleService after downloading
  // /home/additional_translate. No real backend, config or storage is opened.
  Get.appendTranslations({'zh_CN': _additionalLabels});
  Get.updateLocale(const Locale('zh', 'CN'));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
  return controller;
}

Finder _argument(String task, String group, String argument) =>
    find.byKey(ValueKey('args-offline-fixture-$task-$group-$argument'));

void main() {
  late HttpOverrides? previousOverrides;
  setUp(() {
    previousOverrides = HttpOverrides.current;
    HttpOverrides.global = _NoNetwork();
    Get.testMode = true;
  });
  tearDown(() {
    HttpOverrides.global = previousOverrides;
    Get.reset();
  });

  for (final item in [
    (task: 'Dokan', group: 'dokan_config', start: 'dokan_run_time'),
    (
      task: 'DemonRetreat',
      group: 'demon_retreat_time',
      start: 'custom_run_time',
    ),
  ]) {
    testWidgets('${item.task} shows and edits all opening controls', (
      tester,
    ) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final writes = <_Write>[];
      final fields = _fields(item.task, item.group);
      await _mount(tester, item.task, item.group, fields, writes);

      expect(find.text(_labels[item.start]!), findsOneWidget);
      expect(find.text(_labels['opening_wait_minutes']!), findsOneWidget);
      expect(find.text(_labels['opening_retry_interval']!), findsOneWidget);
      expect(find.text(_labels['opening_wait_minutes_help']!), findsOneWidget);
      expect(
        find.text(_labels['opening_retry_interval_help']!),
        findsOneWidget,
      );
      expect(
        find.text(
          fields.firstWhere(
                (field) => field['name'] == 'opening_retry_interval',
              )['value']
              as String,
        ),
        findsOneWidget,
      );
      expect(find.text('opening_wait_minutes'), findsNothing);

      tester.state<TimePickerState>(find.byType(TimePicker)).onConfirm([], [
        19,
        30,
        0,
      ]);
      await tester.pump();
      await tester.enterText(
        find.descendant(
          of: _argument(item.task, item.group, 'opening_wait_minutes'),
          matching: find.byType(TextFormField),
        ),
        '90',
      );
      await tester.pump(const Duration(milliseconds: 200));
      tester
          .state<TimeDeltaPickerState>(find.byType(TimeDeltaPicker))
          .onConfirm([], [0, 0, 4, 0]);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(writes.map((w) => (w.argument, w.type, w.value)), [
        (item.start, 'time', '19:30:00'),
        ('opening_wait_minutes', 'integer', '90'),
        ('opening_retry_interval', 'time_delta', '00 00:04:00'),
      ]);
      expect(
        writes.every(
          (w) =>
              w.config == 'offline-fixture' &&
              w.task == item.task &&
              w.group == item.group,
        ),
        isTrue,
      );
    });
  }

  testWidgets(
    'banquet exposes both independent opening times and retry controls',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final writes = <_Write>[];
      await _mount(
        tester,
        'GuildBanquet',
        'guild_banquet_time',
        _fields('GuildBanquet', 'guild_banquet_time'),
        writes,
      );
      expect(find.text(_labels['run_time_1']!), findsOneWidget);
      expect(find.text(_labels['run_time_2']!), findsOneWidget);
      expect(find.byType(TimePicker), findsNWidgets(2));
      expect(find.byType(TimeDeltaPicker), findsOneWidget);
      expect(find.byType(TextFormField), findsOneWidget);
      for (final item in [
        (field: 'run_time_1', hour: 19),
        (field: 'run_time_2', hour: 20),
      ]) {
        tester
            .state<TimePickerState>(
              find.descendant(
                of: _argument('GuildBanquet', 'guild_banquet_time', item.field),
                matching: find.byType(TimePicker),
              ),
            )
            .onConfirm([], [item.hour, 30, 0]);
        await tester.pump();
      }
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(writes.map((w) => (w.group, w.argument, w.type, w.value)), [
        ('guild_banquet_time', 'run_time_1', 'time', '19:30:00'),
        ('guild_banquet_time', 'run_time_2', 'time', '20:30:00'),
      ]);
    },
  );

  testWidgets(
    'collective weekday and after-dokan settings are separate editable switches',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final writes = <_Write>[];
      await _mount(
        tester,
        'CollectiveMissions',
        'missions_config',
        _fields('CollectiveMissions', 'missions_config'),
        writes,
      );
      expect(find.text(_labels['monday_to_thursday']!), findsOneWidget);
      expect(
        find.text(_labels['collective_monday_to_thursday_help']!),
        findsOneWidget,
      );
      expect(find.text(_labels['run_after_dokan']!), findsOneWidget);
      expect(find.text('是否只在周一到周四开启道馆'), findsNothing);
      for (final field in ['monday_to_thursday', 'run_after_dokan']) {
        await tester.tap(
          find.descendant(
            of: _argument('CollectiveMissions', 'missions_config', field),
            matching: find.byType(Checkbox),
          ),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(
        writes.map((w) => (w.task, w.group, w.argument, w.type, w.value)),
        [
          (
            'CollectiveMissions',
            'missions_config',
            'monday_to_thursday',
            'boolean',
            true,
          ),
          (
            'CollectiveMissions',
            'missions_config',
            'run_after_dokan',
            'boolean',
            true,
          ),
        ],
      );
    },
  );

  testWidgets('opening edits remain staged until explicit save', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final writes = <_Write>[];
    final controller = await _mount(
      tester,
      'Dokan',
      'dokan_config',
      _fields('Dokan', 'dokan_config'),
      writes,
      draft: true,
    );
    tester.state<TimePickerState>(find.byType(TimePicker)).onConfirm([], [
      20,
      0,
      0,
    ]);
    await tester.enterText(find.byType(TextFormField), '75');
    await tester.pump(const Duration(milliseconds: 200));
    tester.state<TimeDeltaPickerState>(find.byType(TimeDeltaPicker)).onConfirm(
      [],
      [0, 0, 4, 0],
    );
    await tester.pumpAndSettle();
    expect(writes, isEmpty);
    expect(controller.dirtyFieldKeys.toSet(), {
      'dokan_config::dokan_run_time',
      'dokan_config::opening_wait_minutes',
      'dokan_config::opening_retry_interval',
    });
    expect(controller.fieldErrors, isEmpty);
  });
}
