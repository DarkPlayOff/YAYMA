import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:yayma/src/features/core/views/widgets/common_ui.dart';

void main() {
  testWidgets('error shows a retry button only when a retry is given', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: CommonErrorWidget(error: 'boom')),
      ),
    );
    expect(find.text('Повторить'), findsNothing);
    expect(find.text('Не удалось загрузить'), findsOneWidget);
  });

  testWidgets('retry button calls onRetry', (tester) async {
    var retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CommonErrorWidget(error: 'boom', onRetry: () => retries++),
        ),
      ),
    );
    await tester.tap(find.text('Повторить'));
    expect(retries, 1);
  });
}
