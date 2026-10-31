import 'package:flutter_test/flutter_test.dart';
import 'package:yayma/src/app/window_placement.dart';
import 'package:yayma/src/features/core/views/widgets/responsive.dart';

void main() {
  test('the desktop window can never reach the compact layout', () {
    // If this fails, the touch-only mini/full player becomes reachable with a
    // mouse and needs a real review before lowering the window minimum.
    expect(
      WindowPlacement.minimumSize.width,
      greaterThanOrEqualTo(compactBreakpoint),
    );
  });
}
