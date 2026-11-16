import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/core/views/widgets/common_ui.dart';

// signals' AsyncState.map dispatches the error callback only when it matches
// `Function(dynamic)`; a typed `(Object e, _)` closure falls through to a
// zero-argument call and throws. This pins the working shape.
void main() {
  testWidgets('an error state renders the error widget instead of throwing', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CommonAsyncView<String>(
          state: AsyncError(StateError('boom'), StackTrace.current),
          builder: (context, data) => Text(data),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(CommonErrorWidget), findsOneWidget);
  });
}
