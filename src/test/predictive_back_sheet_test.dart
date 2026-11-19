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

Future<void> _dragSheet(WidgetTester tester, List<double> progress) async {
  await _sendBack(tester, 'startBackGesture', _event(0));
  for (final p in progress) {
    await _sendBack(tester, 'updateBackGestureProgress', _event(p));
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
    await _dragSheet(tester, [0.2, 0.4, 0.6]);
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
    await _dragSheet(tester, [0.2, 0.4, 0.6]);
    final dragged = tester.getTopLeft(find.byKey(_sheetKey)).dy;

    await _sendBack(tester, 'commitBackGesture');
    // The pop runs synchronously on commit; until the exit animation's first
    // tick the sheet is still where the finger left it — it must not snap back
    // open first.
    expect(tester.getTopLeft(find.byKey(_sheetKey)).dy, closeTo(dragged, 1));

    final tops = await _sampleTop(tester, 60);
    expect(
      tops,
      equals([...tops]..sort()),
      reason: 'sheet must only move down',
    );
    expect(find.byKey(_sheetKey), findsNothing);
  });

  testWidgets('a fully dragged gesture commits without leaving the sheet', (
    tester,
  ) async {
    await _openSheet(tester);
    await _dragSheet(tester, [0.3, 0.7, 1.0]);

    await _sendBack(tester, 'commitBackGesture');
    await tester.pumpAndSettle();

    expect(find.byKey(_sheetKey), findsNothing);
  });

  testWidgets('a late progress event after commit cannot freeze the sheet', (
    tester,
  ) async {
    await _openSheet(tester);
    await _dragSheet(tester, [0.2, 0.4]);

    await _sendBack(tester, 'commitBackGesture');
    await tester.pump(const Duration(milliseconds: 16));
    // A stray update arriving mid-exit used to stop the controller and leave
    // the sheet stuck halfway with no way to close it.
    await _sendBack(tester, 'updateBackGestureProgress', _event(0.8));
    await tester.pumpAndSettle();

    expect(find.byKey(_sheetKey), findsNothing);
  });

  testWidgets('a second gesture during the exit does not over-pop', (
    tester,
  ) async {
    await _openSheet(tester);
    await _dragSheet(tester, [0.2, 0.4]);
    await _sendBack(tester, 'commitBackGesture');
    await tester.pump(const Duration(milliseconds: 16)); // mid exit animation

    await _sendBack(tester, 'startBackGesture', _event(0));
    await _sendBack(tester, 'updateBackGestureProgress', _event(0.5));
    await tester.pump(const Duration(milliseconds: 16));
    await _sendBack(tester, 'commitBackGesture');
    await tester.pumpAndSettle();

    expect(find.byKey(_sheetKey), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('swiping the sheet down dismisses it', (tester) async {
    await _openSheet(tester);

    // The finder's own render box is centered inside the sheet, whose outer
    // detector receives the pointer; warnIfMissed avoids a false-positive hit
    // warning about that detail.
    await tester.drag(
      find.byKey(_sheetKey),
      const Offset(0, 400),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();

    expect(find.byKey(_sheetKey), findsNothing);
  });

  testWidgets('releasing a half-swipe below the threshold closes the sheet', (
    tester,
  ) async {
    await _openSheet(tester);

    // The user's hang: drag the sheet partway down and release. The route
    // must run its exit animation from the finger position and finalize.
    final start = tester.getTopLeft(find.byKey(_sheetKey)) + const Offset(20, 20);
    final gesture = await tester.startGesture(start);
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.byKey(_sheetKey), findsNothing);
  });

  testWidgets('tapping the barrier closes the sheet with an exit animation', (
    tester,
  ) async {
    await _openSheet(tester);

    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    expect(find.byKey(_sheetKey), findsNothing);
  });
}
