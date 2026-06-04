import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/providers/navigation_provider.dart';
import 'package:yayma/src/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/models.dart';
import 'package:yayma/src/ui/widgets/common_ui.dart';
import 'package:yayma/src/ui/widgets/quality_selector.dart';
import 'package:yayma/src/ui/widgets/rust_cached_image.dart';
import 'package:yayma/src/ui/widgets/track_elements.dart';

class PlayerBar extends StatelessWidget {
  const PlayerBar({super.key});

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final theme = Theme.of(context);
      final colorScheme = theme.colorScheme;
      final navState = currentNavStateSignal.value;
      final showLyrics = showLyricsSignal.value;
      final isHome = navState.section == AppSection.home;

      final useLyricsStyle = isHome && showLyrics;
      final alpha = useLyricsStyle ? 0.5 : 0.9;
      final blur = useLyricsStyle ? 0.0 : 3.0;

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
          final accentColor = colorScheme.primary;
          final isNarrow = width < 600;

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
            height: isNarrow ? 80 : 100,
            padding: EdgeInsets.symmetric(
              horizontal: isNarrow ? 16 : 24,
            ),
            margin: EdgeInsets.fromLTRB(
              isNarrow ? 16 : 16,
              0,
              isNarrow ? 16 : 16,
              isNarrow ? 8 : 16,
            ),
            decoration: BoxDecoration(
              color: barColor.withValues(alpha: alpha),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                child: Row(
                  children: [
                    if (isNarrow) ...[
                      Expanded(
                        child: _TrackInfo(coverSize: coverSize),
                      ),
                      const _PlayPauseButton(),
                    ] else ...[
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
                  ],
                ),
              ),
            ),
          );
        },
      );
    });
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
    return Watch((context) {
      final meta = trackMetadataSignal();
      final isPlaying = isPlayingSignal();
      if (meta.id == null) return const SizedBox();

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
              child: AnimatedScale(
                scale: isPlaying ? 1.0 : 0.96,
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeInOutCubic,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 400),
                  child: ClipRRect(
                    key: ValueKey(meta.coverUrl),
                    borderRadius: BorderRadius.circular(12),
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
                              color: Colors.white10,
                            ),
                          )
                        else
                          Container(
                            width: widget.coverSize,
                            height: widget.coverSize,
                            color: Colors.white10,
                          ),
                        if (hasAlbum)
                          Positioned.fill(
                            child: ValueListenableBuilder<bool>(
                              valueListenable: _isCoverHovered,
                              builder: (context, hovered, _) {
                                return AnimatedOpacity(
                                  duration: const Duration(milliseconds: 150),
                                  opacity: hovered ? 1 : 0,
                                  child: Container(
                                    color: Colors.black.withValues(alpha: 0.45),
                                    alignment: Alignment.center,
                                    child: const Icon(
                                      Icons.album_rounded,
                                      color: Colors.white,
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
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
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
    });
  }
}

class _PlayerControls extends StatelessWidget {
  final Color accentColor;
  const _PlayerControls({required this.accentColor});

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final trackId = trackMetadataSignal().id;
      final isPlaying = isPlayingSignal();
      final isLiked = isLikedSignal();
      final isDisliked = isDislikedSignal();
      final isShuffled = isShuffledSignal();
      final repeatMode = repeatModeSignal();

      var repeatIcon = Icons.repeat;
      if (repeatMode == RepeatModeDto.single) {
        repeatIcon = Icons.repeat_one;
      }

      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FittedBox(
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
                        : Colors.white38,
                  ),
                  onPressed: () =>
                      showLyricsSignal.value = !showLyricsSignal.value,
                ),
                IconButton(
                  icon: Icon(
                    Icons.shuffle,
                    size: 20,
                    color: isShuffled ? accentColor : Colors.white38,
                  ),
                  onPressed: PlaybackController.toggleShuffle,
                ),
                IconButton(
                  icon: Icon(
                    isDisliked
                        ? Icons.heart_broken
                        : Icons.heart_broken_outlined,
                    size: 20,
                    color: isDisliked ? Colors.blueGrey : Colors.white38,
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
                  iconSize: 54,
                  icon: Icon(
                    isPlaying
                        ? Icons.pause_circle_filled_rounded
                        : Icons.play_circle_filled_rounded,
                  ),
                  onPressed: PlaybackController.togglePlay,
                ),
                const IconButton(
                  icon: Icon(Icons.skip_next_rounded, size: 28),
                  onPressed: PlaybackController.next,
                ),
                IconButton(
                  icon: Icon(
                    isLiked ? Icons.favorite : Icons.favorite_border,
                    size: 20,
                    color: isLiked ? Colors.red : Colors.white38,
                  ),
                  onPressed: () => trackId != null
                      ? PlaybackController.toggleLike(trackId: trackId)
                      : null,
                ),
                IconButton(
                  icon: Icon(
                    repeatIcon,
                    size: 20,
                    color: repeatMode != RepeatModeDto.none
                        ? accentColor
                        : Colors.white38,
                  ),
                  onPressed: PlaybackController.toggleRepeat,
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          CommonProgressSlider(accentColor: accentColor, compact: true),
        ],
      );
    });
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

    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerRight,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          CommonQualitySelector(accentColor: accentColor),
          if (showVolume) ...[
            const SizedBox(width: 16),
            const Icon(
              Icons.volume_up_rounded,
              size: 18,
              color: Colors.white38,
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

class _PlayPauseButton extends StatelessWidget {
  const _PlayPauseButton();

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final isPlaying = isPlayingSignal();
      return IconButton(
        iconSize: 48,
        icon: Icon(
          isPlaying
              ? Icons.pause_circle_filled_rounded
              : Icons.play_circle_filled_rounded,
        ),
        onPressed: PlaybackController.togglePlay,
      );
    });
  }
}
