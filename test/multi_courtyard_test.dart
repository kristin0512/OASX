import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:oasx/modules/args/index.dart';

void main() {
  tearDown(() => Get.reset());

  testWidgets('courtyard chips retain one choice and stage multiple choices', (tester) async {
    final controller = Get.put(ArgsController());
    controller.isDraftMode.value = true;
    controller.groupsData.value = {
      'costume_config': GroupsModel(groupName: 'costume_config', members: [
        ArgumentModel.fromJson({
          'name': 'costume_main_type', 'type': 'multi_enum',
          'value': ['costume_main'], 'enumEnum': ['costume_main', 'costume_main_17'],
        }),
      ]),
    };
    await tester.pumpWidget(GetMaterialApp(home: Scaffold(body: ArgumentView(
      setArgument: (_, __, ___, ____, _____, ______) => fail('Draft must not write to backend'),
      getGroupName: () => 'costume_config', index: 0,
    ))));
    await tester.tap(find.text('costume_main'));
    await tester.pump();
    expect(controller.findArgument('costume_config', 'costume_main_type')!.value, ['costume_main']);
    await tester.tap(find.text('costume_main_17'));
    await tester.pump();
    final model = controller.findArgument('costume_config', 'costume_main_type')!;
    expect(model.value, ['costume_main', 'costume_main_17']);
    expect(controller.validateArgument(model, model.value), isNull);
    expect(controller.validateArgument(model, []), isNotNull);
    expect(controller.validateArgument(model, ['unknown']), isNotNull);
    await tester.tap(find.text('costume_main'));
    await tester.pump();
    expect(model.value, ['costume_main_17']);
  });
}
