import 'dart:async';

import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/providers/navigation_provider.dart';
import 'package:yayma/src/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/models.dart';
import 'package:yayma/src/ui/widgets/common_ui.dart';
import 'package:yayma/src/ui/widgets/lyrics_view.dart';
import 'package:yayma/src/ui/widgets/quality_selector.dart';
import 'package:yayma/src/ui/widgets/rust_cached_image.dart';
import 'package:yayma/src/ui/widgets/track_elements.dart';

class HomeView extends StatefulWidget {
  const HomeView({super.key});

  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView> {
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
    final meta = trackMetadataSignal.watch(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final width = constraints.maxWidth;
        final showLyrics = showLyricsSignal.watch(context);
        final accentColor = accentColorSignal.watch(context);

        var coverSize = showLyrics ? 280.0 : 360.0;
        var verticalSpacing = 40.0;
        var trackHeaderSpacing = 32.0;
        var controlsSpacing = 32.0;

        // Адаптация под высоту
        if (height < 800) {
          coverSize = showLyrics ? 240.0 : 300.0;
          verticalSpacing = 24.0;
          trackHeaderSpacing = 24.0;
          controlsSpacing = 24.0;
        }
        if (height < 650) {
          coverSize = showLyrics ? 180.0 : 220.0;
          verticalSpacing = 16.0;
          trackHeaderSpacing = 16.0;
          controlsSpacing = 16.0;
        }

        return Stack(
          children: [
            Positioned.fill(
              child: Stack(
                children: [
                  // Левая часть: Интерфейс плеера
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 600),
                    curve: Curves.easeInOutCubic,
                    left: 0,
                    right: showLyrics ? width * 0.5 : 0,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 12,
                        ),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _buildCover(
                                meta.coverUrl,
                                coverSize,
                                meta.albumId,
                              ),
                              SizedBox(height: verticalSpacing),
                              _buildTrackHeader(
                                meta.title,
                                meta.artists,
                                meta.version,
                                meta.albumId,
                                small: height < 750,
                              ),
                              SizedBox(height: trackHeaderSpacing),
                              SizedBox(
                                width: 500,
                                child: CommonProgressSlider(
                                  accentColor: accentColor,
                                  maxWidth: 500,
                                ),
                              ),
                              SizedBox(height: controlsSpacing),
                              _buildMainControls(
                                context,
                                meta.isPlaying,
                                meta.isLiked,
                                meta.isDisliked,
                                meta.id,
                                meta.isShuffled,
                                meta.repeatMode,
                                meta.volume,
                                showLyrics,
                                accentColor,
                                small: height < 750,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),

                  // Правая часть: Текст песен
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 600),
                    curve: Curves.easeInOutCubic,
                    left: showLyrics ? width * 0.5 : width,
                    right: 0,
                    top: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.only(
                        right: 60,
                        top: 40,
                        bottom: 40,
                      ),
                      child: meta.id == null
                          ? const Center(
                              child: Text(
                                'Выберите трек',
                                style: TextStyle(color: Colors.white38),
                              ),
                            )
                          : LyricsWidget(
                              trackId: meta.id!,
                              visible: showLyrics,
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildCover(String? url, double size, String? albumId) {
    return MouseRegion(
      onEnter: (_) => _isCoverHovered.value = true,
      onExit: (_) => _isCoverHovered.value = false,
      cursor: albumId != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: () {
          if (albumId != null) {
            navigateTo(AppSection.album, albumId);
          }
        },
        child: ValueListenableBuilder<bool>(
          valueListenable: _isCoverHovered,
          builder: (context, hovered, _) {
            return AnimatedContainer(
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeInOutCubic,
              width: size,
              height: size,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(32),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.8),
                    blurRadius: hovered ? 100 : 80,
                    spreadRadius: hovered ? 8 : 5,
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(32),
                child: url != null
                    ? RustCachedImage(
                        imageUrl: url,
                        errorWidget: const ColoredBox(
                          color: Colors.white10,
                          child: Icon(
                            Icons.music_note,
                            size: 120,
                            color: Colors.white24,
                          ),
                        ),
                      )
                    : const ColoredBox(
                        color: Colors.white10,
                        child: Icon(
                          Icons.music_note,
                          size: 120,
                          color: Colors.white24,
                        ),
                      ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildTrackHeader(
    String title,
    List<TrackArtistDto> artists,
    String? version,
    String? albumId, {
    bool small = false,
  }) {
    return Column(
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Flexible(
              child: MouseRegion(
                onEnter: (_) => _isTitleHovered.value = true,
                onExit: (_) => _isTitleHovered.value = false,
                cursor: albumId != null
                    ? SystemMouseCursors.click
                    : SystemMouseCursors.basic,
                child: ValueListenableBuilder<bool>(
                  valueListenable: _isTitleHovered,
                  builder: (context, hovered, _) {
                    return GestureDetector(
                      onTap: () {
                        if (albumId != null) {
                          navigateTo(AppSection.album, albumId);
                        }
                      },
                      child: Text(
                        title,
                        style: TextStyle(
                          fontSize: small ? 32 : 42,
                          fontWeight: FontWeight.w900,
                          color: Colors.white,
                          letterSpacing: -1,
                          decoration: hovered && albumId != null
                              ? TextDecoration.underline
                              : null,
                          shadows: const [Shadow(blurRadius: 20)],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  },
                ),
              ),
            ),
            TrackVersionWidget(
              version: version,
              fontSize: small ? 16 : 20,
              color: Colors.white.withValues(alpha: 0.3),
              padding: const EdgeInsets.only(left: 12),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ArtistNamesWidget(
          artists: artists,
          fontSize: small ? 18 : 22,
          color: Colors.white.withValues(alpha: 0.6),
        ),
      ],
    );
  }

  Widget _buildMainControls(
    BuildContext context,
    bool isPlaying,
    bool isLiked,
    bool isDisliked,
    String? trackId,
    bool isShuffled,
    RepeatModeDto repeatMode,
    int volume,
    bool showLyrics,
    Color accentColor, {
    bool small = false,
  }) {
    var repeatIcon = Icons.repeat;
    var repeatColor = Colors.white38;
    if (repeatMode == RepeatModeDto.all) {
      repeatColor = accentColor;
    } else if (repeatMode == RepeatModeDto.single) {
      repeatIcon = Icons.repeat_one;
      repeatColor = accentColor;
    }

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              icon: Icon(
                Icons.lyrics_rounded,
                size: small ? 20 : 24,
                color: showLyrics ? accentColor : Colors.white38,
              ),
              onPressed: () => showLyricsSignal.value = !showLyricsSignal.value,
            ),
            SizedBox(width: small ? 8 : 12),
            IconButton(
              icon: Icon(
                isDisliked ? Icons.heart_broken : Icons.heart_broken_outlined,
                size: small ? 20 : 24,
                color: isDisliked ? Colors.blueGrey : Colors.white38,
              ),
              onPressed: () => trackId != null
                  ? unawaited(PlaybackController.toggleDislike(trackId: trackId))
                  : null,
            ),
            SizedBox(width: small ? 8 : 12),
            IconButton(
              icon: Icon(
                Icons.shuffle,
                size: small ? 20 : 24,
                color: isShuffled ? accentColor : Colors.white38,
              ),
              onPressed: () => unawaited(PlaybackController.toggleShuffle()),
            ),
            SizedBox(width: small ? 12 : 20),
            IconButton(
              icon: Icon(
                Icons.skip_previous_rounded,
                size: small ? 32 : 42,
                color: Colors.white,
              ),
              onPressed: () => unawaited(PlaybackController.prev()),
            ),
            SizedBox(width: small ? 16 : 24),
            IconButton(
              iconSize: small ? 56 : 72,
              icon: Icon(
                isPlaying
                    ? Icons.pause_circle_filled_rounded
                    : Icons.play_circle_filled_rounded,
              ),
              color: Colors.white,
              onPressed: () => unawaited(PlaybackController.togglePlay()),
            ),
            SizedBox(width: small ? 16 : 24),
            IconButton(
              icon: Icon(
                Icons.skip_next_rounded,
                size: small ? 32 : 42,
                color: Colors.white,
              ),
              onPressed: () => unawaited(PlaybackController.next()),
            ),
            SizedBox(width: small ? 12 : 20),
            IconButton(
              icon: Icon(repeatIcon, size: small ? 20 : 24, color: repeatColor),
              onPressed: () => unawaited(PlaybackController.toggleRepeat()),
            ),
            SizedBox(width: small ? 8 : 12),
            IconButton(
              icon: Icon(
                isLiked ? Icons.favorite : Icons.favorite_border,
                size: small ? 20 : 24,
                color: isLiked ? Colors.red : Colors.white38,
              ),
              onPressed: () => trackId != null
                  ? unawaited(PlaybackController.toggleLike(trackId: trackId))
                  : null,
            ),
            SizedBox(width: small ? 8 : 12),
            CommonQualitySelector(accentColor: accentColor, isSmall: true),
          ],
        ),
        SizedBox(height: small ? 20 : 32),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.volume_down, color: Colors.white38, size: 18),
            const SizedBox(width: 12),
            CommonVolumeSlider(
              initialVolume: volume,
              width: small ? 180 : 240,
              activeColor: accentColor,
            ),
            const SizedBox(width: 12),
            const Icon(Icons.volume_up, color: Colors.white38, size: 18),
          ],
        ),
      ],
    );
  }
}
