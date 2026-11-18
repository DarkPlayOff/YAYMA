import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:yayma/src/features/core/views/widgets/common_ui.dart';

const ValueKey<String> _sheetKey = ValueKey('sheet');

Future<void> _openSheet(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showAppBottomSheet<void>(
              context: context,
              builder: (_) => const SizedBox(key: _sheetKey, height: 300),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _sendBack(
  WidgetTester tester,
  String method, [
  Map<String, Object?>? arguments,
]) {
  final data = const StandardMethodCodec().encodeMethodCall(
    MethodCall(method, arguments),
  );
  return tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/backgesture',
    data,
    (_) {},
  );
}

Map<String, Object?> _event(double progress) => {
  'touchOffset': <double>[0, 400],
  'progress': progress,
  'swipeEdge': 0,
};

Future<void> _dragSheet(WidgetTester tester) async {
  await _sendBack(tester, 'startBackGesture', _event(0));
  for (final progress in [0.2, 0.4, 0.6]) {
    await _sendBack(tester, 'updateBackGestureProgress', _event(progress));
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// Top edge of the sheet on each frame, until it leaves the tree.
Future<List<double>> _sampleTop(WidgetTester tester, int frames) async {
  final tops = <double>[];
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (find.byKey(_sheetKey).evaluate().isEmpty) break;
    tops.add(tester.getTopLeft(find.byKey(_sheetKey)).dy);
  }
  return tops;
}

double _largestStep(List<double> values) {
  var largest = 0.0;
  for (var i = 1; i < values.length; i++) {
    final step = (values[i] - values[i - 1]).abs();
    if (step > largest) largest = step;
  }
  return largest;
}

void main() {
  testWidgets('cancelling a sheet back gesture returns it without a jump', (
    tester,
  ) async {
    await _openSheet(tester);
    await _dragSheet(tester);
    final dragged = tester.getTopLeft(find.byKey(_sheetKey)).dy;

    await _sendBack(tester, 'cancelBackGesture');
    final tops = await _sampleTop(tester, 40);

    expect(tops.first, closeTo(dragged, 1));
    expect(_largestStep(tops), lessThan(60));
  });

  testWidgets('committing a sheet back gesture closes it from where it was', (
    tester,
  ) async {
    await _openSheet(tester);
    await _dragSheet(tester);
    final dragged = tester.getTopLeft(find.byKey(_sheetKey)).dy;

    await _sendBack(tester, 'commitBackGesture');
    final tops = await _sampleTop(tester, 60);

    expect(tops.first, closeTo(dragged, 1));
    expect(
      tops,
      equals([...tops]..sort()),
      reason: 'sheet must only move down',
    );
    expect(find.byKey(_sheetKey), findsNothing);
  });
}
