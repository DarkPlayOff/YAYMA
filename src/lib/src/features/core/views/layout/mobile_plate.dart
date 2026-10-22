import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/core/views/widgets/common_ui.dart';
import 'package:yayma/src/features/core/views/widgets/track_elements.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';

/// Geometry of the mini player plate.
///
/// The mini player renders the plate and the full player renders a collapsed
/// copy of it, so both take their numbers from here: a difference of a pixel
/// or two shows up when the copy is replaced by the real plate.
class MiniPlateLayout {
  /// Side inset of the plate content: the cover and the progress bar.
  static const double sideInset = 16;

  /// Left inset of the title / artist block.
  static const double titleInset = 80;

  /// Gap between the title block and the play button.
  static const double titleGap = 64;

  static const double coverSize = 48;

  /// Offset of the cover centre from the plate's left edge.
  static const double coverCenterOffset = sideInset + coverSize / 2;

  /// Width of the title block inside the plate.
  static double titleWidth(double plateWidth) =>
      plateWidth - titleInset - titleGap;

  /// Width of the progress bar inside the plate.
  static double progressWidth(double plateWidth) => plateWidth - sideInset * 2;
}

/// Surface of the mini plate: background colour, opacity, blur and border.
///
/// The plate and its collapsed copy have to look identical, so they share
/// this: a difference here shows up as the copy turning into a slightly
/// different pill at the end of the collapse.
class MiniPlateSurface {
  /// Whether the lyrics style is active.
  final bool lyricsStyle;

  final ColorScheme colorScheme;

  const MiniPlateSurface({
    required this.lyricsStyle,
    required this.colorScheme,
  });

  /// Background colour of the plate.
  Color get color =>
      Color.lerp(colorScheme.surfaceContainerHighest, Colors.black, 0.4) ??
      colorScheme.surface;

  /// Opacity of the plate background.
  double get alpha => lyricsStyle ? 0.5 : 0.9;

  /// Blur sigma of the plate backdrop.
  double get blur => lyricsStyle ? 0.0 : 2.0;

  Color get borderColor => colorScheme.onSurface.withValues(alpha: 0.08);
}

/// Title and artist block of the mini plate.
class MiniTrackTextInfo extends StatelessWidget {
  const MiniTrackTextInfo({super.key});

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final meta = trackMetadataSignal();
        if (meta.id == null) return const SizedBox.shrink();

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(
                    meta.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                ),
                TrackVersionWidget(version: meta.version, fontSize: 12),
              ],
            ),
            ArtistNamesWidget(artists: meta.artists, maxLines: 1),
          ],
        );
      },
    );
  }
}

/// Play / pause button of the mini plate.
class MiniPlayPauseButton extends StatelessWidget {
  const MiniPlayPauseButton({super.key});

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final isPlaying = isPlayingSignal();
        final showBuffering = showBufferingIndicatorSignal.value;
        return IconButton(
          iconSize: 48,
          icon: showBuffering
              ? M3ECircularWavyProgressIndicator(
                  strokeWidth: 3,
                  size: 40,
                  color: accentColorSignal.value,
                )
              : AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  switchInCurve: Curves.easeOutBack,
                  switchOutCurve: Curves.easeIn,
                  transitionBuilder: (child, animation) {
                    return FadeTransition(
                      opacity: animation,
                      child: ScaleTransition(scale: animation, child: child),
                    );
                  },
                  child: Icon(
                    isPlaying
                        ? Icons.pause_circle_filled_rounded
                        : Icons.play_circle_filled_rounded,
                    key: ValueKey<bool>(isPlaying),
                  ),
                ),
          onPressed: PlaybackController.togglePlay,
        );
      },
    );
  }
}

/// Read-only progress slider of the mini plate.
///
/// The mini player uses an interactive variant of it, the full player this
/// one for the collapsed copy.
class MiniProgressSlider extends StatelessWidget {
  const MiniProgressSlider({super.key});

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final progress = trackProgressSignal();
        final max = progress.durationMs > 0 ? progress.durationMs : 1.0;

        return IgnorePointer(
          child: M3ESlider(
            value: progress.positionMs.clamp(0.0, max),
            max: max,
            decoration: miniProgressSliderDecoration(
              Theme.of(context).colorScheme,
            ),
            onChanged: (_) {},
          ),
        );
      },
    );
  }
}

/// Decoration of the mini plate progress slider.
///
/// The interactive slider of the mini player and the read-only one of the
/// collapsed copy share it, so they look identical when they replace each
/// other at the end of the collapse.
M3ESliderDecoration miniProgressSliderDecoration(ColorScheme colorScheme) {
  return expressSliderDecoration(
    activeColor: colorScheme.primary,
    inactiveColor: colorScheme.onSurface.withValues(alpha: 0.08),
    trackHeight: 3,
    thumbWidth: 3,
    thumbHeight: 10,
  );
}
