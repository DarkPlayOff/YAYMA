import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:yayma/src/app/window_placement.dart';

void main() {
  group('WindowPlacement.parseBounds', () {
    test('restores a normal saved window', () {
      expect(
        WindowPlacement.parseBounds({
          'x': 100,
          'y': 50,
          'width': 1280,
          'height': 720,
        }),
        const Rect.fromLTWH(100, 50, 1280, 720),
      );
    });

    test('keeps a window spanning two 4K monitors', () {
      // A monitor left of the primary plus a full-width window: an old 7680
      // cap silently reset such windows on every restart.
      final bounds = WindowPlacement.parseBounds({
        'x': -3840,
        'y': 0,
        'width': 7696,
        'height': 1600,
      });
      expect(bounds, isNotNull);
      expect(bounds!.width, 7696);
    });

    test('rejects sizes below the window minimum', () {
      expect(
        WindowPlacement.parseBounds({
          'x': 0,
          'y': 0,
          'width': 799,
          'height': 600,
        }),
        isNull,
      );
      expect(
        WindowPlacement.parseBounds({
          'x': 0,
          'y': 0,
          'width': 800,
          'height': 599,
        }),
        isNull,
      );
    });

    test('rejects missing, mistyped or non-finite fields', () {
      expect(WindowPlacement.parseBounds({'x': 0, 'y': 0}), isNull);
      expect(
        WindowPlacement.parseBounds({
          'x': 'left',
          'y': 0,
          'width': 800,
          'height': 600,
        }),
        isNull,
      );
      expect(
        WindowPlacement.parseBounds({
          'x': true,
          'y': 0,
          'width': 800,
          'height': 600,
        }),
        isNull,
      );
      expect(
        WindowPlacement.parseBounds({
          'x': 0,
          'y': 0,
          'width': double.nan,
          'height': 600,
        }),
        isNull,
      );
      expect(
        WindowPlacement.parseBounds({
          'x': double.infinity,
          'y': 0,
          'width': 800,
          'height': 600,
        }),
        isNull,
      );
    });
  });
}
