import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/app/session.dart';
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

/// Last transport failure per track, so a failed fetch is retried on a later
/// read instead of being pinned as "no lyrics" for the whole session.
final Map<String, DateTime> _lyricsFailedAt = {};

/// How long a failed fetch stays cached before [lyricsSignal] retries it.
const Duration _lyricsRetryDelay = Duration(seconds: 20);

/// Drops every cached lyrics fetch so the next [lyricsSignal] read refetches
/// from Rust. Call this when the set of enabled lyrics providers changes —
/// otherwise a track's lyrics stay pinned to whatever source answered
/// before the toggle, even after a source is disabled.
/// Also call from logout to avoid leaking per-user data.
void clearLyricsCache() {
  _lyricsCache.clear();
  _lyricsFailedAt.clear();
}

FutureSignal<LyricsResult> lyricsSignal(String trackId) {
  final existing = _lyricsCache[trackId];
  final failedAt = _lyricsFailedAt[trackId];
  if (existing != null &&
      (failedAt == null ||
          DateTime.now().difference(failedAt) < _lyricsRetryDelay)) {
    return existing;
  }
  _lyricsFailedAt.remove(trackId);
  final created = futureSignal<LyricsResult>(() async {
    final ctx = appContextSignal.value;
    // No context yet is not a provider failure: don't cache it as one.
    if (ctx == null) return LyricsResult([], '');
    try {
      final result = await getLyrics(ctx: ctx, trackId: trackId);
      if (result == null) return LyricsResult([], '');
      return LyricsResult(_toLyricItems(result.lines), result.providerName);
    } on Object {
      _lyricsFailedAt[trackId] = DateTime.now();
      rethrow;
    }
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
      final words = current.words;
      // Word timings can span most of a long gap: end the line when the last
      // word is sung instead of stopping the karaoke cursor after 4 s.
      final sung = (words != null && words.isNotEmpty)
          ? words.last.end - current.time
          : const Duration(seconds: 4);
      final textDuration = sung < Duration.zero
          ? Duration.zero
          : (sung > duration ? duration : sung);
      result.add(
        LyricLine(current.time, current.text, textDuration, words: words),
      );

      final timerStart = current.time + textDuration;
      final timerDuration =
          duration - textDuration - const Duration(seconds: 1);

      if (timerDuration > Duration.zero) {
        result.add(LyricTimer(timerStart, timerDuration));
      }
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
