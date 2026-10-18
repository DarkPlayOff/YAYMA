import 'dart:async';
import 'dart:ui' as ui;

import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/core/providers/navigation_provider.dart';
import 'package:yayma/src/features/core/providers/visual_effects_provider.dart';
import 'package:yayma/src/features/core/theme/app_tokens.dart';
import 'package:yayma/src/features/core/views/widgets/app_cover.dart';
import 'package:yayma/src/features/core/views/widgets/common_ui.dart';
import 'package:yayma/src/features/core/views/widgets/track_elements.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';

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
      position:
          Tween<Offset>(
            begin: isIncoming ? slideOffset : -slideOffset,
            end: Offset.zero,
          ).animate(
            CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
            ),
          ),
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
        final blur = useLyricsStyle ? 0.0 : 2.0;

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
        final slideWidth = (defaultWidth - _dragOffset.abs()).clamp(
          80.0,
          defaultWidth,
        );

        final contentOpacity = (1.0 - _dragOffset.abs() / 150).clamp(0.0, 1.0);
        final buttonOpacity = (1.0 - _dragOffset.abs() / 100).clamp(0.0, 1.0);

        final meta = trackMetadataSignal();

        // Visual gap only: the Android system navigation inset is applied by
        // the app shell (Positioned bottom offset in layout.dart), so it
        // must not be added here a second time.
        const bottomPadding = 8.0;
        // Plate height (was 80 before the 8dp reduction).
        const barHeight = 72.0;
        // Horizontal inset of the progress bar so it clears the rounded
        // bottom corners of the plate instead of hugging them.
        const progressInset = 16.0;

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, bottomPadding),
          child: SizedBox(
            height: barHeight,
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
                    height: barHeight,
                    child: Container(
                      decoration: BoxDecoration(
                        color: barColor.withValues(alpha: alpha),
                        borderRadius: BorderRadius.circular(AppRadius.xxxl),
                        border: Border.all(
                          color: colorScheme.onSurface.withValues(alpha: 0.08),
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(AppRadius.xxxl),
                        child: BackdropFilter(
                          enabled: blurEffectsEnabledSignal.value && blur > 0,
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
                              Positioned(
                                bottom: 0,
                                left: progressInset,
                                right: progressInset,
                                child: AnimatedOpacity(
                                  duration: _animationDuration,
                                  curve: Curves.easeOutCubic,
                                  opacity: buttonOpacity,
                                  child: _MiniProgressBar(
                                    width: defaultWidth - progressInset * 2,
                                  ),
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
            child: AppCover(
              coverUrl: meta.coverUrl,
              size: coverSize,
              circle: true,
              placeholderIcon: Icons.music_note,
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

class _MiniProgressBar extends StatefulWidget {
  final double width;
  const _MiniProgressBar({required this.width});

  @override
  State<_MiniProgressBar> createState() => _MiniProgressBarState();
}

class _MiniProgressBarState extends State<_MiniProgressBar> {
  double? _dragValueMs;
  bool _isDragging = false;
  Timer? _commitTimer;
  Timer? _dragEndTimer;

  @override
  void dispose() {
    _commitTimer?.cancel();
    _dragEndTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final progress = trackProgressSignal();
        final duration = progress.durationMs;
        final position = progress.positionMs;

        final currentPosition = _dragValueMs ?? position;
        final max = duration > 0 ? duration : 1.0;
        final ratio = (currentPosition / max).clamp(0.0, 1.0);

        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;
        final accentColor = colorScheme.primary;

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

        return SizedBox(
          height: 16,
          width: widget.width,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.bottomCenter,
            children: [
              M3ESlider(
                value: currentPosition.clamp(0.0, max),
                max: max,
                decoration: expressSliderDecoration(
                  activeColor: accentColor,
                  inactiveColor: colorScheme.onSurface.withValues(
                    alpha: 0.08,
                  ),
                  trackHeight: 3,
                  thumbWidth: 3,
                  thumbHeight: 10,
                ),
                onChangeStart: (val) {
                  // Abort a pending deferred commit: a new drag took over
                  // the gesture, so the press jump must not seek (see
                  // onChangeEnd below).
                  _commitTimer?.cancel();
                  _dragEndTimer?.cancel();
                  _isDragging = true;
                  setState(() => _dragValueMs = val);
                },
                onChanged: (val) {
                  setState(() => _dragValueMs = val);
                },
                onChangeEnd: (val) {
                  _isDragging = false;
                  // Keep the freshest held value: M3ESlider passes
                  // widget.value here, which can be one frame stale — a
                  // fast press+release completes within a single frame, so
                  // widget.value is still the pre-tap position. onChanged
                  // already held the fresh tapped value in _dragValueMs.
                  final commitValue = _dragValueMs ?? val;
                  // M3ESlider also emits onChangeEnd mid-gesture when a
                  // press loses the arena to a drag (its onTapCancel path
                  // rejects before the drag accepts), committing a seek
                  // while the finger is still down. Defer the actual seek
                  // one event-loop turn: if the drag took over,
                  // onChangeStart cancels this timer in the same dispatch.
                  _commitTimer?.cancel();
                  _commitTimer = Timer(Duration.zero, () {
                    if (!mounted || _isDragging) return; // preview only
                    unawaited(
                      PlaybackController.seekTo(
                        Duration(milliseconds: commitValue.toInt()),
                      ),
                    );
                    // Free the held value (and the tooltip) shortly after
                    // the seek echo.
                    _dragEndTimer?.cancel();
                    _dragEndTimer = Timer(const Duration(milliseconds: 500), () {
                      if (mounted) setState(() => _dragValueMs = null);
                    });
                  });
                },
              ),
              if (_dragValueMs != null)
                Positioned(
                  bottom: 24,
                  left: (ratio * widget.width - 25).clamp(
                    8.0,
                    widget.width - 58.0,
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.xs),
                    child: BackdropFilter(
                      enabled: blurEffectsEnabledSignal.value && blur > 0,
                      filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: barColor.withValues(alpha: alpha),
                          borderRadius: BorderRadius.circular(AppRadius.xs),
                          border: Border.all(
                            color: colorScheme.onSurface.withValues(
                              alpha: 0.08,
                            ),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.15),
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Text(
                          formatDuration(_dragValueMs!.toInt()),
                          style: TextStyle(
                            color: colorScheme.onSurface,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
