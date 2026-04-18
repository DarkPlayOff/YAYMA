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
    final barColor = playerBarColorSignal.watch(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final accentColor = accentColorSignal.watch(context);

        double coverSize = 64;
        double volumeWidth = 120;
        double horizontalPadding = 24;

        if (width < 1100) {
          coverSize = 54;
          volumeWidth = 100;
          horizontalPadding = 16;
        }
        if (width < 900) {
          coverSize = 48;
          volumeWidth = 80;
          horizontalPadding = 12;
        }
        if (width < 750) {
          coverSize = 40;
          volumeWidth = 60;
        }

        return AnimatedContainer(
          duration: const Duration(milliseconds: 600),
          height: 100,
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          margin: const EdgeInsets.fromLTRB(0, 0, 16, 16),
          decoration: BoxDecoration(
            color: barColor.withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white10),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 20,
              ),
            ],
          ),
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

  @override
  void dispose() {
    _isTitleHovered.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final meta = trackMetadataSignal();
      if (meta.id == null) return const SizedBox();

      return Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: meta.coverUrl != null
                ? RustCachedImage(
                    imageUrl: meta.coverUrl,
                    width: widget.coverSize,
                    height: widget.coverSize,
                    errorWidget: Container(
                      width: widget.coverSize,
                      height: widget.coverSize,
                      color: Colors.white10,
                    ),
                  )
                : Container(
                    width: widget.coverSize,
                    height: widget.coverSize,
                    color: Colors.white10,
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
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: Icon(
                  isDisliked ? Icons.heart_broken : Icons.heart_broken_outlined,
                  size: 20,
                  color: isDisliked ? Colors.blueGrey : Colors.white38,
                ),
                onPressed: () => trackId != null
                    ? PlaybackController.toggleDislike(trackId: trackId)
                    : null,
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: Icon(
                  Icons.shuffle,
                  size: 20,
                  color: isShuffled ? accentColor : Colors.white38,
                ),
                onPressed: PlaybackController.toggleShuffle,
              ),
              const SizedBox(width: 8),
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
              const SizedBox(width: 8),
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
              const SizedBox(width: 4),
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
            ],
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
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        CommonQualitySelector(accentColor: accentColor),
        const SizedBox(width: 16),
        const Icon(Icons.volume_up_rounded, size: 18, color: Colors.white38),
        CommonVolumeSlider(
          width: volumeWidth,
          activeColor: accentColor,
        ),
      ],
    );
  }
}
