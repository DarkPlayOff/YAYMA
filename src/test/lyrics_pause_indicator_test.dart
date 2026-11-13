import 'package:flutter_test/flutter_test.dart';
import 'package:yayma/src/features/core/views/widgets/lyrics_pause_indicator.dart';

void main() {
  const time = Duration(seconds: 10);
  const duration = Duration(seconds: 8);

  test('progress clamps to the pause', () {
    expect(pauseProgress(time, duration, 9000), 0);
    expect(pauseProgress(time, duration, 14000), 0.5);
    expect(pauseProgress(time, duration, 20000), 1);
  });

  test('remaining counts down to the next line', () {
    expect(pauseRemaining(time, duration, 10000), duration);
    expect(pauseRemaining(time, duration, 14000), const Duration(seconds: 4));
    expect(pauseRemaining(time, duration, 30000), Duration.zero);
  });

  test('remaining formats as bare seconds, rounded up', () {
    expect(formatPauseRemaining(const Duration(seconds: 7)), '7');
    expect(formatPauseRemaining(const Duration(milliseconds: 6500)), '7');
    expect(formatPauseRemaining(const Duration(seconds: 65)), '65');
    expect(formatPauseRemaining(Duration.zero), '0');
  });

  test('fade only runs during the last second', () {
    expect(pauseFade(const Duration(milliseconds: 2000)), 1);
    expect(pauseFade(const Duration(milliseconds: 500)), 0.5);
    expect(pauseFade(Duration.zero), 0);
  });
}
