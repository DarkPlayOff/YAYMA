import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/auth/providers/auth_provider.dart';
import 'package:yayma/src/rust/api/content.dart';

sealed class LyricItem {
  final Duration time;
  LyricItem(this.time);
}

class LyricLine extends LyricItem {
  final String text;
  final Duration duration;
  LyricLine(super.time, this.text, this.duration);
}

class LyricTimer extends LyricItem {
  final Duration duration;
  LyricTimer(super.time, this.duration);
}

final Map<String, FutureSignal<List<LyricItem>>> _lyricsCache = {};

FutureSignal<List<LyricItem>> lyricsSignal(String trackId) {
  return _lyricsCache.putIfAbsent(
    trackId,
    () => futureSignal<List<LyricItem>>(() async {
      final raw = await runRustFetch(
        (ctx) => getLyrics(ctx: ctx, trackId: trackId),
      );
      if (raw == null) return [];
      return _parseLrc(raw);
    }),
  );
}

List<LyricItem> _parseLrc(String lrc) {
  final lines = lrc.split('\n');
  final rawLines = <({Duration time, String text})>[];
  final regExp = RegExp(r'\[(\d+):(\d+\.\d+)\](.*)');

  for (final line in lines) {
    final match = regExp.firstMatch(line);
    if (match != null) {
      final min = int.parse(match.group(1)!);
      final sec = double.parse(match.group(2)!);
      final text = match.group(3)!.trim();
      final duration = Duration(
        minutes: min,
        milliseconds: (sec * 1000).toInt(),
      );
      rawLines.add((time: duration, text: text));
    }
  }

  if (rawLines.isEmpty) return [];

  rawLines.sort((a, b) => a.time.compareTo(b.time));

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

    if (duration > const Duration(seconds: 7)) {
      const textDuration = Duration(seconds: 4);
      result.add(LyricLine(current.time, current.text, textDuration));

      final timerStart = current.time + textDuration;
      final timerDuration =
          duration - textDuration - const Duration(seconds: 1);

      result.add(LyricTimer(timerStart, timerDuration));
    } else {
      result.add(LyricLine(current.time, current.text, duration));
    }
  }

  return result;
}
