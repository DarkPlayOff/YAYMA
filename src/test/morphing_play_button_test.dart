import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:yayma/src/features/core/views/widgets/morphing_play_button.dart';

Future<void> _mount(WidgetTester tester, VoidCallback onPressed) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: MorphingPlayPauseButton(
            isPlaying: false,
            size: 48,
            color: Colors.orange,
            onPressed: onPressed,
          ),
        ),
      ),
    ),
  );
}

/// The shape painter the button draws its silhouette with.
ShapeMorphPainter _painter(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .firstWhere((paint) => paint.painter is ShapeMorphPainter)
    .painter! as ShapeMorphPainter;

void main() {
  setUp(() => playButtonShapeIndex.value = 0);

  testWidgets('every press moves the button to the next Material shape', (
    tester,
  ) async {
    var presses = 0;
    await _mount(tester, () => presses++);

    // One full lap plus one: the last press wraps back to the first shape.
    for (var i = 1; i <= playButtonShapes.length + 1; i++) {
      await tester.tap(find.byType(MorphingPlayPauseButton));
      await tester.pumpAndSettle();
      expect(playButtonShapeIndex.value, i % playButtonShapes.length);
    }
    expect(presses, playButtonShapes.length + 1);
  });

  testWidgets('the outline flows between the shapes instead of switching', (
    tester,
  ) async {
    await _mount(tester, () {});
    expect(_painter(tester).t, 1.0);

    await tester.tap(find.byType(MorphingPlayPauseButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Part way through: the painted outline is a blend, not either shape.
    final mid = _painter(tester);
    expect(mid.t, greaterThan(0));
    expect(mid.t, lessThan(1));
    expect(mid.from, isNot(equals(mid.to)));

    await tester.pumpAndSettle();
    expect(_painter(tester).t, 1.0);
  });

  testWidgets('every silhouette is painted inside the button box', (
    tester,
  ) async {
    await _mount(tester, () {});

    for (var i = 0; i < playButtonShapes.length; i++) {
      await tester.tap(find.byType(MorphingPlayPauseButton));
      await tester.pumpAndSettle();

      // Points are unit square coordinates, so anything outside 0..1 spills
      // over the button's own box. The tolerance is for the rounding between a
      // sample's direction and its sector.
      for (final point in _painter(tester).to) {
        expect(point.dx, inInclusiveRange(-0.01, 1.01));
        expect(point.dy, inInclusiveRange(-0.01, 1.01));
      }
    }
  });

  testWidgets('every shape reads as the same size', (tester) async {
    await _mount(tester, () {});

    double area(List<Offset> points) {
      var sum = 0.0;
      for (var i = 0; i < points.length; i++) {
        final a = points[i];
        final b = points[(i + 1) % points.length];
        sum += a.dx * b.dy - b.dx * a.dy;
      }
      return sum.abs() / 2;
    }

    double extent(List<Offset> points) {
      final xs = points.map((point) => point.dx);
      final ys = points.map((point) => point.dy);
      return math.max(
        xs.reduce(math.max) - xs.reduce(math.min),
        ys.reduce(math.max) - ys.reduce(math.min),
      );
    }

    await tester.pumpAndSettle();
    final circle = _painter(tester).to;
    for (var i = 1; i < playButtonShapes.length; i++) {
      await tester.tap(find.byType(MorphingPlayPauseButton));
      await tester.pumpAndSettle();

      final shape = _painter(tester).to;
      final name = playButtonShapes[i].name;
      // Filled silhouettes at the circle's area, kept off each other's toes by
      // at most a cell of the sample grid.
      expect(
        area(shape) / area(circle),
        inInclusiveRange(0.7, 1.01),
        reason: '$name is a different visual weight',
      );
      expect(
        extent(shape) / extent(circle),
        inInclusiveRange(0.9, 1.01),
        reason: '$name is a different size',
      );
    }
  });

  testWidgets('the rim is smooth, not stair-stepped', (tester) async {
    playButtonShapeIndex.value = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: RepaintBoundary(
              key: const Key('button'),
              child: MorphingPlayPauseButton(
                isPlaying: false,
                size: 84,
                color: Colors.orange,
                onPressed: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final boundary =
        tester.renderObject(find.byKey(const Key('button')))
            as RenderRepaintBoundary;
    final image = (await tester.runAsync(boundary.toImage))!;
    final pixels = (await tester.runAsync(
      image.toByteData,
    ))!.buffer.asUint8List();
    final row = image.height ~/ 2;

    // Left to right across the left rim: a drawn curve fades from the
    // background to the fill over a pixel, a stepped one snaps.
    var covered = 0;
    var partial = 0;
    for (var x = 0; x < image.width ~/ 2; x++) {
      final alpha = pixels[(row * image.width + x) * 4 + 3];
      if (alpha > 8 && alpha < 247) partial++;
      if (alpha > 8) covered++;
    }
    expect(covered, greaterThan(0), reason: 'the fill was not drawn');
    expect(partial, greaterThan(0), reason: 'the rim has a hard, stepped edge');
  });
}
