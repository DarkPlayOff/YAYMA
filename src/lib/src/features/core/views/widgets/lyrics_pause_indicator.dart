import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';

/// Fills the instrumental pause between sung lines: a Material shape morphs
/// with the pause's progress while the seconds until the next line count down.
/// Replaces the old three-dot ellipsis.
class LyricsPauseIndicator extends StatelessWidget {
  final Duration time;
  final Duration duration;
  final double positionMs;
  final Color color;
  final VoidCallback? onTap;

  const LyricsPauseIndicator({
    required this.time,
    required this.duration,
    required this.positionMs,
    required this.color,
    this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final remaining = pauseRemaining(time, duration, positionMs);
    final indicator = Opacity(
      opacity: pauseFade(remaining),
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            M3ELoadingIndicator(
              value: pauseProgress(time, duration, positionMs),
              color: color,
              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
            ),
            const SizedBox(width: 10),
            Text(
              formatPauseRemaining(remaining),
              style: TextStyle(
                color: color,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
    if (onTap == null) return indicator;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: indicator,
    );
  }
}

/// 0 at the pause's start, 1 once the next line is due.
double pauseProgress(Duration time, Duration duration, double positionMs) {
  final total = duration.inMilliseconds;
  if (total <= 0) return 1;
  return ((positionMs - time.inMilliseconds) / total).clamp(0.0, 1.0);
}

/// Time left before the next line, clamped to the pause itself.
Duration pauseRemaining(Duration time, Duration duration, double positionMs) {
  final left = time.inMilliseconds + duration.inMilliseconds - positionMs;
  return Duration(milliseconds: left.clamp(0, duration.inMilliseconds).round());
}

/// Seconds left, rounded up so the last second reads `1` until the line lands.
String formatPauseRemaining(Duration remaining) {
  return '${(remaining.inMilliseconds / 1000).ceil()}';
}

/// Fades the indicator out over its last second instead of cutting it off.
double pauseFade(Duration remaining) {
  return (remaining.inMilliseconds / 1000).clamp(0.0, 1.0);
}
