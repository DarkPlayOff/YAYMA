import 'package:flutter_test/flutter_test.dart';
import 'package:yayma/src/features/core/views/layout/mobile_cover_swipe.dart';

void main() {
  test('adjacent moves keep their index direction', () {
    expect(coverMoveDirection(3, 4, 10), 1);
    expect(coverMoveDirection(4, 3, 10), -1);
  });

  test('repeat-all wraps are detected at both ends', () {
    expect(coverMoveDirection(9, 0, 10), 1);
    expect(coverMoveDirection(0, 9, 10), -1);
  });

  test('unknown or unchanged indexes report no direction', () {
    expect(coverMoveDirection(null, 2, 10), 0);
    expect(coverMoveDirection(2, null, 10), 0);
    expect(coverMoveDirection(2, 2, 10), 0);
  });

  test('two-track queues are treated as an ordinary step', () {
    expect(coverMoveDirection(0, 1, 2), 1);
    expect(coverMoveDirection(1, 0, 2), -1);
  });
}
