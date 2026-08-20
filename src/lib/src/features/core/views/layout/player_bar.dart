import 'dart:io';
import 'dart:ui' as ui;

import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/core/providers/navigation_provider.dart';
import 'package:yayma/src/features/core/providers/visual_effects_provider.dart';
import 'package:yayma/src/features/core/theme/app_tokens.dart';
import 'package:yayma/src/features/core/views/layout/mobile_mini_player.dart';
import 'package:yayma/src/features/core/views/widgets/common_ui.dart';
import 'package:yayma/src/features/core/views/widgets/quality_selector.dart';
import 'package:yayma/src/features/core/views/widgets/rust_cached_image.dart';
import 'package:yayma/src/features/core/views/widgets/track_elements.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/models.dart';

class PlayerBar extends StatelessWidget {
  const PlayerBar({super.key});

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;
        final navState = currentNavStateSignal.value;
        final showLyrics = showLyricsSignal.value;
        final isHome = navState.section == AppSection.home;

        final useLyricsStyle = isHome && showLyrics;
        final alpha = useLyricsStyle ? 0.5 : 0.9;
        final blur = useLyricsStyle ? 0.0 : 2.0;

        // Dynamic background color based on theme
        final barColor =
            Color.lerp(
              colorScheme.surfaceContainerHighest,
              Colors.black,
              0.4,
            ) ??
            colorScheme.surface;

        return LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            if (width < 600) {
              return const MobileMiniPlayer();
            }

            final accentColor = colorScheme.primary;
            double coverSize = 75;
            double volumeWidth = 120;

            if (width < 1100) {
              coverSize = 64;
              volumeWidth = 100;
            }
            if (width < 900) {
              coverSize = 56;
              volumeWidth = 80;
            }
            if (width < 750) {
              coverSize = 48;
              volumeWidth = 60;
            }

            return AnimatedContainer(
              duration: const Duration(milliseconds: 600),
              height: 100,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              decoration: BoxDecoration(
                color: barColor.withValues(alpha: alpha),
                borderRadius: BorderRadius.circular(AppRadius.xl),
                border: Border.all(
                  color: colorScheme.onSurface.withValues(alpha: 0.08),
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.xl),
                child: BackdropFilter(
                  enabled: blurEffectsEnabledSignal.value && blur > 0,
                  filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: _TrackInfo(coverSize: coverSize),
                      ),
                      Expanded(
                        flex: 4,
                        child: _PlayerControls(accentColor: accentColor),
                      ),
                      Expanded(
                        flex: 3,
                        child: _VolumeAndQuality(
                          accentColor: accentColor,
                          volumeWidth: volumeWidth,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _TrackInfo extends StatefulWidget {
  final double coverSize;
  const _TrackInfo({required this.coverSize});

  @override
  State<_TrackInfo> createState() => _TrackInfoState();
}

class _TrackInfoState extends State<_TrackInfo> {
  final ValueNotifier<bool> _isTitleHovered = ValueNotifier(false);
  final ValueNotifier<bool> _isCoverHovered = ValueNotifier(false);

  @override
  void dispose() {
    _isTitleHovered.dispose();
    _isCoverHovered.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final meta = trackMetadataSignal();
        final isPlaying = isPlayingSignal();
        if (meta.id == null) return const SizedBox();
        final cs = Theme.of(context).colorScheme;

        final hasAlbum = meta.albumId != null;

        return Row(
          children: [
            MouseRegion(
              cursor: hasAlbum
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
              onEnter: (_) => _isCoverHovered.value = true,
              onExit: (_) => _isCoverHovered.value = false,
              child: GestureDetector(
                onTap: () {
                  if (hasAlbum) {
                    navigateTo(AppSection.album, meta.albumId);
                  }
                },
                child: PlayerCoverRectReporter(
                  child: AnimatedScale(
                    scale: isPlaying ? 1.0 : 0.96,
                    duration: const Duration(milliseconds: 350),
                    curve: Curves.easeInOutCubic,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 400),
                      child: ClipRRect(
                        key: ValueKey(meta.coverUrl),
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        child: Stack(
                          children: [
                            if (meta.coverUrl != null)
                              RustCachedImage(
                                imageUrl: meta.coverUrl,
                                width: widget.coverSize,
                                height: widget.coverSize,
                                errorWidget: Container(
                                  width: widget.coverSize,
                                  height: widget.coverSize,
                                  color: cs.onSurface.withValues(alpha: 0.1),
                                ),
                              )
                            else
                              Container(
                                width: widget.coverSize,
                                height: widget.coverSize,
                                color: cs.onSurface.withValues(alpha: 0.1),
                              ),
                            if (hasAlbum)
                              Positioned.fill(
                                child: ValueListenableBuilder<bool>(
                                  valueListenable: _isCoverHovered,
                                  builder: (context, hovered, _) {
                                    return AnimatedOpacity(
                                      duration: const Duration(
                                        milliseconds: 150,
                                      ),
                                      opacity: hovered ? 1 : 0,
                                      child: Container(
                                        color: Colors.black.withValues(
                                          alpha: 0.45,
                                        ),
                                        alignment: Alignment.center,
                                        child: Icon(
                                          Icons.album_rounded,
                                          color: cs.onSurface,
                                          size: 24,
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: MouseRegion(
                          onEnter: (_) => _isTitleHovered.value = true,
                          onExit: (_) => _isTitleHovered.value = false,
                          cursor: meta.albumId != null
                              ? SystemMouseCursors.click
                              : SystemMouseCursors.basic,
                          child: ValueListenableBuilder<bool>(
                            valueListenable: _isTitleHovered,
                            builder: (context, hovered, _) {
                              return GestureDetector(
                                onTap: () {
                                  if (meta.albumId != null) {
                                    navigateTo(AppSection.album, meta.albumId);
                                  }
                                },
                                child: Text(
                                  meta.title,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 17,
                                    height: 1.15,
                                    letterSpacing: -0.4,
                                    decoration: hovered && meta.albumId != null
                                        ? TextDecoration.underline
                                        : null,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      TrackVersionWidget(
                        version: meta.version,
                        fontSize: 12,
                      ),
                    ],
                  ),
                  ArtistNamesWidget(
                    artists: meta.artists,
                    maxLines: 1,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PlayerControls extends StatelessWidget {
  final Color accentColor;
  const _PlayerControls({required this.accentColor});

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final trackId = trackMetadataSignal().id;
        final isPlaying = isPlayingSignal();
        final isLiked = isLikedSignal();
        final isDisliked = isDislikedSignal();
        final isShuffled = isShuffledSignal();
        final repeatMode = repeatModeSignal();
        final showBuffering = showBufferingIndicatorSignal.value;
        final onSurfaceVariant = Theme.of(context).colorScheme.onSurfaceVariant;

        var repeatIcon = Icons.repeat;
        if (repeatMode == RepeatModeDto.single) {
          repeatIcon = Icons.repeat_one;
        }

        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Expanded(
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: Icon(
                          Icons.lyrics_rounded,
                          size: 20,
                          color: showLyricsSignal.value
                              ? accentColor
                              : onSurfaceVariant,
                        ),
                        onPressed: () =>
                            showLyricsSignal.value = !showLyricsSignal.value,
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.shuffle,
                          size: 20,
                          color: isShuffled ? accentColor : onSurfaceVariant,
                        ),
                        onPressed: PlaybackController.toggleShuffle,
                      ),
                      IconButton(
                        icon: Icon(
                          isDisliked
                              ? Icons.heart_broken
                              : Icons.heart_broken_outlined,
                          size: 20,
                          color: isDisliked
                              ? Colors.blueGrey
                              : onSurfaceVariant,
                        ),
                        onPressed: () => trackId != null
                            ? PlaybackController.toggleDislike(trackId: trackId)
                            : null,
                      ),
                      const IconButton(
                        icon: Icon(Icons.skip_previous_rounded, size: 28),
                        onPressed: PlaybackController.prev,
                      ),
                      IconButton(
                        iconSize: 48,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 48,
                          minHeight: 48,
                        ),
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
                                    child: ScaleTransition(
                                      scale: animation,
                                      child: child,
                                    ),
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
                      ),
                      const IconButton(
                        icon: Icon(Icons.skip_next_rounded, size: 28),
                        onPressed: PlaybackController.next,
                      ),
                      AnimatedLikeButton(
                        isLiked: isLiked,
                        size: 20,
                        onTap: trackId != null
                            ? () => PlaybackController.toggleLike(
                                trackId: trackId,
                              )
                            : null,
                      ),
                      IconButton(
                        icon: Icon(
                          repeatIcon,
                          size: 20,
                          color: repeatMode != RepeatModeDto.none
                              ? accentColor
                              : onSurfaceVariant,
                        ),
                        onPressed: PlaybackController.toggleRepeat,
                      ),
                      CommonQualitySelector(accentColor: accentColor),
                    ],
                  ),
                ),
              ),
            ),
            CommonProgressSlider(accentColor: accentColor, compact: true),
            const SizedBox(height: 6),
          ],
        );
      },
    );
  }
}

class _VolumeAndQuality extends StatelessWidget {
  final Color accentColor;
  final double volumeWidth;
  const _VolumeAndQuality({
    required this.accentColor,
    required this.volumeWidth,
  });

  @override
  Widget build(BuildContext context) {
    final showVolume = !Platform.isAndroid;
    final onSurfaceVariant = Theme.of(context).colorScheme.onSurfaceVariant;

    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerRight,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (showVolume) ...[
            Icon(
              Icons.volume_up_rounded,
              size: 18,
              color: onSurfaceVariant,
            ),
            CommonVolumeSlider(
              width: volumeWidth,
              activeColor: accentColor,
            ),
            const SizedBox(width: 8),
            const AudioDeviceButton(),
          ],
        ],
      ),
    );
  }
}
