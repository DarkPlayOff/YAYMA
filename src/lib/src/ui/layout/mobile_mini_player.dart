import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/providers/navigation_provider.dart';
import 'package:yayma/src/providers/playback_provider.dart';
import 'package:yayma/src/ui/widgets/rust_cached_image.dart';
import 'package:yayma/src/ui/widgets/track_elements.dart';

class MobileMiniPlayer extends StatefulWidget {
  const MobileMiniPlayer({super.key});

  @override
  State<MobileMiniPlayer> createState() => _MobileMiniPlayerState();
}

class _MobileMiniPlayerState extends State<MobileMiniPlayer> {
  double _dragOffset = 0;
  bool _isNext = true;
  Duration _animationDuration = Duration.zero;

  void _onDragStart(DragStartDetails details) {
    setState(() {
      _animationDuration = Duration.zero;
    });
  }

  void _onDragUpdate(DragUpdateDetails details) {
    setState(() {
      _dragOffset += details.primaryDelta ?? 0;
    });
  }

  Future<void> _onDragEnd(DragEndDetails details) async {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final defaultWidth = screenWidth - 32;
    const minWidth = 80.0;
    
    final collapseLeftOffset = minWidth - defaultWidth;
    final collapseRightOffset = defaultWidth - minWidth;
    final velocity = details.primaryVelocity ?? 0;

    const transitionDuration = Duration(milliseconds: 300);

    if (_dragOffset > 100 || velocity > 300) {
      setState(() {
        _isNext = false;
        _animationDuration = transitionDuration;
        _dragOffset = collapseRightOffset;
      });
      await Future<void>.delayed(transitionDuration);
      await PlaybackController.prev();
      if (mounted) {
        setState(() {
          _animationDuration = transitionDuration;
          _dragOffset = 0;
        });
      }
    } else if (_dragOffset < -100 || velocity < -300) {
      setState(() {
        _isNext = true;
        _animationDuration = transitionDuration;
        _dragOffset = collapseLeftOffset;
      });
      await Future<void>.delayed(transitionDuration);
      await PlaybackController.next();
      if (mounted) {
        setState(() {
          _animationDuration = transitionDuration;
          _dragOffset = 0;
        });
      }
    } else {
      setState(() {
        _animationDuration = transitionDuration;
        _dragOffset = 0;
      });
    }
  }

  Widget _buildContentTransition(Widget child, Animation<double> animation) {
    final meta = trackMetadataSignal();
    final isIncoming = child.key == ValueKey(meta.id);
    
    final slideOffset = _isNext ? const Offset(1, 0) : const Offset(-1, 0);

    return SlideTransition(
      position: Tween<Offset>(
        begin: isIncoming ? slideOffset : -slideOffset,
        end: Offset.zero,
      ).animate(CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
      )),
      child: FadeTransition(
        opacity: animation,
        child: child,
      ),
    );
  }

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
        final blur = useLyricsStyle ? 0.0 : 3.0;

        final barColor =
            Color.lerp(
              colorScheme.surfaceContainerHighest,
              Colors.black,
              0.4,
            ) ??
            colorScheme.surface;

        final screenWidth = MediaQuery.sizeOf(context).width;
        final defaultWidth = screenWidth - 32;

        final slideTranslation = _dragOffset > 0 ? _dragOffset : 0.0;
        final slideWidth = (defaultWidth - _dragOffset.abs()).clamp(80.0, defaultWidth);

        final contentOpacity = (1.0 - _dragOffset.abs() / 150).clamp(0.0, 1.0);
        final buttonOpacity = (1.0 - _dragOffset.abs() / 100).clamp(0.0, 1.0);

        final meta = trackMetadataSignal();

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: SizedBox(
            height: 80,
            width: defaultWidth,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: _onDragStart,
              onHorizontalDragUpdate: _onDragUpdate,
              onHorizontalDragEnd: _onDragEnd,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.centerLeft,
                children: [
                  AnimatedPositioned(
                    duration: _animationDuration,
                    curve: Curves.easeOutCubic,
                    left: slideTranslation,
                    width: slideWidth,
                    height: 80,
                    child: Container(
                      decoration: BoxDecoration(
                        color: barColor.withValues(alpha: alpha),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: BackdropFilter(
                          filter: ui.ImageFilter.blur(
                            sigmaX: blur,
                            sigmaY: blur,
                          ),
                          child: Stack(
                            alignment: Alignment.centerLeft,
                            children: [
                              Positioned.fill(
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 350),
                                  transitionBuilder: _buildContentTransition,
                                  child: _TrackContentPair(
                                    key: ValueKey(meta.id),
                                    opacity: contentOpacity,
                                    defaultWidth: defaultWidth,
                                    animationDuration: _animationDuration,
                                  ),
                                ),
                              ),
                              Positioned(
                                right: 8,
                                child: AnimatedOpacity(
                                  duration: _animationDuration,
                                  curve: Curves.easeOutCubic,
                                  opacity: buttonOpacity,
                                  child: const _PlayPauseButton(),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TrackContentPair extends StatelessWidget {
  final double opacity;
  final double defaultWidth;
  final Duration animationDuration;

  const _TrackContentPair({
    required this.opacity,
    required this.defaultWidth,
    required this.animationDuration,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.centerLeft,
      children: [
        Positioned(
          left: 16,
          child: AnimatedOpacity(
            duration: animationDuration,
            curve: Curves.easeOutCubic,
            opacity: opacity,
            child: const _MobileCover(coverSize: 48),
          ),
        ),
        Positioned(
          left: 80,
          width: defaultWidth - 144,
          child: AnimatedOpacity(
            duration: animationDuration,
            curve: Curves.easeOutCubic,
            opacity: opacity,
            child: const ClipRect(
              child: _TrackTextInfo(),
            ),
          ),
        ),
      ],
    );
  }
}

class _MobileCover extends StatelessWidget {
  final double coverSize;
  const _MobileCover({required this.coverSize});

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final meta = trackMetadataSignal();
        final isPlaying = isPlayingSignal();
        if (meta.id == null) return const SizedBox();

        final hasAlbum = meta.albumId != null;

        return GestureDetector(
          onTap: () {
            if (hasAlbum) {
              navigateTo(AppSection.album, meta.albumId);
            }
          },
          child: AnimatedScale(
            scale: isPlaying ? 1.0 : 0.96,
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeInOutCubic,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: meta.coverUrl != null
                  ? RustCachedImage(
                      imageUrl: meta.coverUrl,
                      width: coverSize,
                      height: coverSize,
                      errorWidget: Container(
                        width: coverSize,
                        height: coverSize,
                        color: Colors.white10,
                      ),
                    )
                  : Container(
                      width: coverSize,
                      height: coverSize,
                      color: Colors.white10,
                    ),
            ),
          ),
        );
      },
    );
  }
}

class _TrackTextInfo extends StatelessWidget {
  const _TrackTextInfo();

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final meta = trackMetadataSignal();
        if (meta.id == null) return const SizedBox();

        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: GestureDetector(
                    onTap: () {
                      if (meta.albumId != null) {
                        navigateTo(AppSection.album, meta.albumId);
                      }
                    },
                    child: Text(
                      meta.title,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                      overflow: TextOverflow.ellipsis,
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
        );
      },
    );
  }
}

class _PlayPauseButton extends StatelessWidget {
  const _PlayPauseButton();

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
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
      },
    );
  }
}
