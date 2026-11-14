import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:yayma/src/features/core/views/widgets/app_context_menu.dart';

void main() {
  testWidgets('menu near the bottom edge opens above the trigger', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned(
                left: 300,
                bottom: 0,
                child: AppContextMenu<String>(
                  key: const Key('trigger'),
                  items: const [
                    AppContextMenuItem(value: 'a', label: 'Item A'),
                    AppContextMenuItem(value: 'b', label: 'Item B'),
                    AppContextMenuItem(value: 'c', label: 'Item C'),
                  ],
                  onSelected: (_) {},
                  child: const SizedBox(width: 40, height: 40),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('trigger')));
    await tester.pumpAndSettle();

    expect(find.text('Item A'), findsOneWidget);
    final trigger = tester.getRect(find.byKey(const Key('trigger')));
    final lastItem = tester.getRect(find.text('Item C'));
    expect(
      lastItem.bottom,
      lessThanOrEqualTo(trigger.top),
      reason: 'the menu must clear the trigger instead of covering it',
    );
  });
}
