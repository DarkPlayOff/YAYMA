import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:yayma/src/features/core/views/widgets/keyboard_focus.dart';

void main() {
  testWidgets('tapping outside the search field drops its focus', (
    tester,
  ) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    // Mounted where main.dart puts it: MaterialApp.builder, above the Navigator.
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => Actions(
          actions: unfocusOnTapOutside,
          child: child ?? const SizedBox.shrink(),
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: TextField(focusNode: focusNode),
          ),
        ),
      ),
    );

    focusNode.requestFocus();
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);

    // Android keeps the field focused on an outside touch by default, which
    // brings the keyboard back after the player is dismissed.
    await tester.tapAt(const Offset(400, 400)); // the results area
    await tester.pump();
    expect(focusNode.hasFocus, isFalse);
  });
}
