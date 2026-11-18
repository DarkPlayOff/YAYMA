import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:yayma/src/features/core/views/widgets/common_ui.dart';

Widget _app(ScrollController controller) => MaterialApp(
  home: Scaffold(
    body: AppRefreshIndicator(
      onRefresh: () async {},
      child: ListView.builder(
        controller: controller,
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: 40,
        itemBuilder: (_, i) => SizedBox(height: 48, child: Text('item $i')),
      ),
    ),
  ),
);

void main() {
  testWidgets('pulling the finger back closes the header, not the list', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(controller));

    final first = find.text('item 0');
    final startY = tester.getTopLeft(first).dy;

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
    );
    await gesture.moveBy(const Offset(0, 20)); // touch slop
    await gesture.moveBy(const Offset(0, 60));
    await tester.pump();
    expect(tester.getTopLeft(first).dy, greaterThan(startY + 20));
    expect(controller.offset, 0);

    await gesture.moveBy(const Offset(0, -60));
    await tester.pump();
    expect(controller.offset, 0);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller.offset, 0);
    expect(tester.getTopLeft(first).dy, closeTo(startY, 2));
  });

  testWidgets('the list scrolls as usual when nothing is pulled', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(controller));

    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(0));
  });
}
