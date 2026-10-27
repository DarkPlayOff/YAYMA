import 'package:flutter_test/flutter_test.dart';
import 'package:yayma/src/features/core/views/layout/player_lyrics.dart';
import 'package:yayma/src/features/playback/providers/lyrics_provider.dart';

void main() {
  test('splits a line and spreads it over the line duration', () {
    final line = LyricLine(
      const Duration(seconds: 10),
      'one  two three',
      const Duration(seconds: 3),
    );

    final words = synthLyricWords(line);

    expect(words.map((w) => w.text), ['one', 'two', 'three']);
    expect(words.first.start, const Duration(seconds: 10));
    expect(words.first.end, const Duration(seconds: 11));
    expect(words.last.end, const Duration(seconds: 13));
  });

  test('blank text yields no words', () {
    final line = LyricLine(Duration.zero, '   ', const Duration(seconds: 3));

    expect(synthLyricWords(line), isEmpty);
  });

  test('zero duration still gives each word a slice', () {
    final line = LyricLine(Duration.zero, 'a b', Duration.zero);

    final words = synthLyricWords(line);

    expect(words, hasLength(2));
    expect(words.last.end, const Duration(milliseconds: 600));
  });

  test('word timings never overlap, so wrapped rows fill in text order', () {
    final line = LyricLine(
      Duration.zero,
      'one two three four five six',
      const Duration(seconds: 6),
    );

    final words = synthLyricWords(line);

    for (var i = 1; i < words.length; i++) {
      expect(words[i].start, words[i - 1].end);
      expect(words[i].start, greaterThan(words[i - 1].start));
    }
  });
}
