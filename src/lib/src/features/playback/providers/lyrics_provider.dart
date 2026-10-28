import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/core/services/rust_bridge.dart';
import 'package:yayma/src/features/core/utils/lru_map.dart';
import 'package:yayma/src/rust/api/content.dart';
import 'package:yayma/src/rust/api/models.dart';

sealed class LyricItem {
  final Duration time;
  LyricItem(this.time);
}

class LyricWord {
  final String text;
  final Duration start;
  final Duration end;
  LyricWord({required this.text, required this.start, required this.end});
}

class LyricLine extends LyricItem {
  final String text;
  final Duration duration;
  final List<LyricWord>? words;
  LyricLine(super.time, this.text, this.duration, {this.words});
}

class LyricTimer extends LyricItem {
  final Duration duration;
  LyricTimer(super.time, this.duration);
}

/// A track's parsed lyrics plus the name of the source that provided them,
/// so the UI can show where the text came from.
class LyricsResult {
  final List<LyricItem> items;
  final String providerName;
  LyricsResult(this.items, this.providerName);
}

/// First index in [items] whose time is past [ms], or `items.length` if none.
/// `items` is time-sorted, so this binary-searches instead of scanning — it is
/// called on every progress tick (~8/sec while playing).
int upperBoundByTime(List<LyricItem> items, int ms) {
  var lo = 0;
  var hi = items.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (items[mid].time.inMilliseconds > ms) {
      hi = mid;
    } else {
      lo = mid + 1;
    }
  }
  return lo;
}

const int _maxLyricsCacheSize = 20;

/// Bounded LRU of per-track lyrics fetches. Reads promote entries and
/// inserts past capacity evict the least-recently-used track (see [LruMap]).
final LruMap<String, FutureSignal<LyricsResult>> _lyricsCache = LruMap(
  maximumSize: _maxLyricsCacheSize,
);

/// Drops every cached lyrics fetch so the next [lyricsSignal] read refetches
/// from Rust. Call this when the set of enabled lyrics providers changes —
/// otherwise a track's lyrics stay pinned to whatever source answered
/// before the toggle, even after a source is disabled.
/// Also call from logout to avoid leaking per-user data.
void clearLyricsCache() {
  _lyricsCache.clear();
}

FutureSignal<LyricsResult> lyricsSignal(String trackId) {
  final existing = _lyricsCache[trackId];
  if (existing != null) return existing;
  final created = futureSignal<LyricsResult>(() async {
    final result = await runRustFetch(
      (ctx) => getLyrics(ctx: ctx, trackId: trackId),
    );
    if (result == null) return LyricsResult([], '');
    return LyricsResult(_toLyricItems(result.lines), result.providerName);
  });
  _lyricsCache[trackId] = created;
  return created;
}

List<LyricItem> _toLyricItems(List<LyricsLineDto> lines) {
  if (lines.isEmpty) return [];

  final rawLines = lines
      .map(
        (line) => (
          time: Duration(milliseconds: line.startMs),
          text: line.text,
          words: line.words.isEmpty
              ? null
              : line.words
                    .map(
                      (w) => LyricWord(
                        text: w.text,
                        start: Duration(milliseconds: w.startMs),
                        end: Duration(milliseconds: w.endMs),
                      ),
                    )
                    .toList(),
        ),
      )
      .toList();

  final result = <LyricItem>[];

  if (rawLines.isNotEmpty && rawLines.first.time > const Duration(seconds: 5)) {
    result.add(
      LyricTimer(
        const Duration(seconds: 1),
        rawLines.first.time - const Duration(seconds: 2),
      ),
    );
  }

  for (var i = 0; i < rawLines.length; i++) {
    final current = rawLines[i];
    final nextTime = (i + 1 < rawLines.length)
        ? rawLines[i + 1].time
        : current.time + const Duration(seconds: 10);

    final duration = nextTime - current.time;

    if (duration > const Duration(seconds: 5)) {
      const textDuration = Duration(seconds: 4);
      result.add(
        LyricLine(
          current.time,
          current.text,
          textDuration,
          words: current.words,
        ),
      );

      final timerStart = current.time + textDuration;
      final timerDuration =
          duration - textDuration - const Duration(seconds: 1);

      result.add(LyricTimer(timerStart, timerDuration));
    } else {
      result.add(
        LyricLine(current.time, current.text, duration, words: current.words),
      );
    }
  }

  return result;
}

/// Appends the closing pause: the gap between the last sung line and the end
/// of the track, when it is longer than 5 s.
List<LyricItem> withOutroTimer(List<LyricItem> items, Duration trackDuration) {
  final last = items.isEmpty ? null : items.last;
  if (last is! LyricLine) return items;
  final words = last.words;
  final lineEnd = (words != null && words.isNotEmpty)
      ? words.last.end
      : last.time + const Duration(seconds: 4);
  final gap = trackDuration - lineEnd;
  if (gap <= const Duration(seconds: 5)) return items;
  return [...items, LyricTimer(lineEnd, gap)];
}
