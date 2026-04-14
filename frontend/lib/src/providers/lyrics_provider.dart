import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/providers/auth_provider.dart';
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

// Кэш сигналов для текстов песен (чтобы не перекачивать одно и то же)
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

  // Сортируем по времени на всякий случай
  rawLines.sort((a, b) => a.time.compareTo(b.time));

  final result = <LyricItem>[];

  // Проверяем паузу в самом начале трека
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

    // Если пауза до следующей строки большая (больше 7 секунд),
    // разделяем это время на показ текста и таймер ожидания.
    if (duration > const Duration(seconds: 7)) {
      // Даем тексту побыть активным 3 секунды (хватит, чтобы допеть фразу)
      const textDuration = Duration(seconds: 3);
      result.add(LyricLine(current.time, current.text, textDuration));

      // Остальное время (за вычетом 1 сек перед следующей строкой) — таймер
      final timerStart = current.time + textDuration;
      final timerDuration =
          duration - textDuration - const Duration(seconds: 1);

      result.add(LyricTimer(timerStart, timerDuration));
    } else {
      // Обычная последовательность
      result.add(LyricLine(current.time, current.text, duration));
    }
  }

  return result;
}
