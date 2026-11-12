import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:yayma/src/features/core/views/widgets/common_ui.dart';

/// Cancelling the prompt with the keyboard open used to dispose the
/// [TextEditingController] on pop, while the still-animating dialog rebuilt on
/// the keyboard-inset change and threw "used after being disposed" (surfacing
/// as a `_dependents.isEmpty` framework assertion).
void main() {
  testWidgets('prompt dialog can be cancelled with the keyboard open', (
    tester,
  ) async {
    tester.view.viewInsets = FakeViewPadding.zero;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showTextPromptDialog(context, title: 'Новый'),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Keyboard slides in.
    tester.view.viewInsets = const FakeViewPadding(bottom: 900);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Отмена'));
    // Keyboard slides out while the dialog animates away.
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
