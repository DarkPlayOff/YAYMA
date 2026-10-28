import 'package:flutter_test/flutter_test.dart';
import 'package:yayma/src/features/core/views/widgets/lyrics_pause_indicator.dart';
import 'package:yayma/src/features/playback/providers/lyrics_provider.dart';

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

  group('withOutroTimer', () {
    final line = LyricLine(
      const Duration(seconds: 60),
      'last line',
      const Duration(seconds: 4),
    );

    test('short tail adds nothing', () {
      expect(withOutroTimer([line], const Duration(seconds: 65)), [line]);
    });

    test('long tail counts down to the end of the track', () {
      final items = withOutroTimer([line], const Duration(seconds: 80));

      final timer = items.last as LyricTimer;
      expect(timer.time, const Duration(seconds: 64));
      expect(timer.duration, const Duration(seconds: 16));
    });

    test('word timings set where the line ends', () {
      final sung = LyricLine(
        const Duration(seconds: 60),
        'last line',
        const Duration(seconds: 4),
        words: [
          LyricWord(
            text: 'last',
            start: const Duration(seconds: 60),
            end: const Duration(seconds: 62),
          ),
        ],
      );

      final items = withOutroTimer([sung], const Duration(seconds: 80));

      expect((items.last as LyricTimer).time, const Duration(seconds: 62));
    });
  });
}
