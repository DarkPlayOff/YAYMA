import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/core/providers/navigation_provider.dart';
import 'package:yayma/src/features/core/providers/visual_effects_provider.dart';
import 'package:yayma/src/features/core/theme/app_tokens.dart';
import 'package:yayma/src/features/core/views/layout/mobile_full_player.dart';
import 'package:yayma/src/features/core/views/layout/mobile_plate.dart';
import 'package:yayma/src/features/core/views/widgets/app_cover.dart';
import 'package:yayma/src/features/core/views/widgets/common_ui.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';

class MobileMiniPlayer extends StatefulWidget {
  const MobileMiniPlayer({super.key});

  @override
  State<MobileMiniPlayer> createState() => _MobileMiniPlayerState();
}

class _MobileMiniPlayerState extends State<MobileMiniPlayer> {
  final GlobalKey _plateKey = GlobalKey();
  double _dragOffset = 0;
  bool _isNext = true;
  bool _swiping = false;
  Duration _animationDuration = Duration.zero;
  bool _expandingFromDrag = false;
  MobileFullPlayerController? _expandController;
  Rect? _dragPlateRect;
  double _expandStartY = 0;

  bool _openFullPlayer() {
    if (trackMetadataSignal.peek().id == null) return false;

    final box = _plateKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return false;

    final plateRect = box.localToGlobal(Offset.zero) & box.size;
    _dragPlateRect = plateRect;
    final coverScale = Platform.isAndroid || isPlayingSignal.peek()
        ? 1.0
        : 0.96;
    final coverCenter = Offset(
      plateRect.left + MiniPlateLayout.coverCenterOffset,
      plateRect.center.dy,
    );
    final coverRect = Rect.fromCenter(
      center: coverCenter,
      width: MiniPlateLayout.coverSize * coverScale,
      height: MiniPlateLayout.coverSize * coverScale,
    );

    mobileFullPlayerController.reset();
    mobileFullPlayerOrigin.value = MobileFullPlayerOrigin(
      plateRect: plateRect,
      coverRect: coverRect,
    );
    mobileMiniPlayerPlateRect.value = plateRect;
    mobileFullPlayerOpenSignal.value = true;
    return true;
  }

  /// Publishes the plate rect for the full player to collapse into.
  void _syncPlateRect() {
    final box = _plateKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    if (rect != mobileMiniPlayerPlateRect.value) {
      mobileMiniPlayerPlateRect.value = rect;
    }
  }

  void _onExpandDragDown(DragDownDetails details) {
    _expandStartY = details.globalPosition.dy;
    _expandingFromDrag = false;
    _expandController = null;
    _dragPlateRect = null;
  }

  void _onExpandDragUpdate(DragUpdateDetails details) {
    final dy = details.globalPosition.dy - _expandStartY;
    if (!_expandingFromDrag) {
      if (dy > -12) return;
      if (!_openFullPlayer()) return;
      _expandingFromDrag = true;
      _expandController = mobileFullPlayerController;
    }
    _updateExpandDrag(details.globalPosition.dy);
  }

  void _updateExpandDrag(double globalY) {
    final dy = globalY - _expandStartY;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final travel = _dragPlateRect?.top;
    final progress =
        (-dy / (travel == null || travel <= 1 ? screenHeight * 0.5 : travel))
            .clamp(0.0, 1.0);
    _expandController!.updateDrag(progress);
  }

  void _onExpandDragEnd(DragEndDetails details) {
    if (!_expandingFromDrag) {
      _resetExpandDrag();
      return;
    }
    final progress = _expandController!.progress;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final travel = _dragPlateRect?.top;
    final distance = travel == null || travel <= 1
        ? screenHeight * 0.5
        : travel;
    final velocity = details.primaryVelocity ?? 0;
    final normalizedVelocity = -velocity / distance;
    final projected = (progress + normalizedVelocity * 0.1).clamp(0.0, 1.0);
    _expandController!.endDrag(
      expand: projected > 0.12,
      velocity: normalizedVelocity,
    );
    _resetExpandDrag();
  }

  void _onExpandDragCancel() {
    if (_expandingFromDrag) {
      _expandController!.endDrag(expand: _expandController!.progress > 0.12);
    }
    _resetExpandDrag();
  }

  void _resetExpandDrag() {
    _expandingFromDrag = false;
    _expandController = null;
    _dragPlateRect = null;
  }

  @override
  void dispose() {
    // At progress 1 the full player is open and this bar is unmounted; the
    // full player owns the panel from there, so collapsing here would shut it
    // under the user's finger.
    if (_expandingFromDrag && (_expandController?.progress ?? 1) < 1) {
      _expandController?.endDrag(expand: false);
    }
    super.dispose();
  }

  void _onDragStart(DragStartDetails details) {
    if (_swiping) return;
    setState(() {
      _animationDuration = Duration.zero;
      _dragOffset = 0;
    });
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (_swiping) return;
    setState(() {
      _dragOffset += details.primaryDelta ?? 0;
    });
  }

  Future<void> _onDragEnd(DragEndDetails details) async {
    if (_swiping) return;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final defaultWidth = screenWidth - 32;
    const minWidth = 80.0;

    final collapseLeftOffset = minWidth - defaultWidth;
    final collapseRightOffset = defaultWidth - minWidth;
    final velocity = details.primaryVelocity ?? 0;

    const transitionDuration = Duration(milliseconds: 300);

    if (_dragOffset > 100 || velocity > 300) {
      _swiping = true;
      setState(() {
        _isNext = false;
        _animationDuration = transitionDuration;
        _dragOffset = collapseRightOffset;
      });
      await Future<void>.delayed(transitionDuration);
      await PlaybackController.prev();
      _swiping = false;
      if (mounted) {
        setState(() {
          _animationDuration = transitionDuration;
          _dragOffset = 0;
        });
      }
    } else if (_dragOffset < -100 || velocity < -300) {
      _swiping = true;
      setState(() {
        _isNext = true;
        _animationDuration = transitionDuration;
        _dragOffset = collapseLeftOffset;
      });
      await Future<void>.delayed(transitionDuration);
      await PlaybackController.next();
      _swiping = false;
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
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: FadeTransition(opacity: animation, child: child),
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

        final surface = MiniPlateSurface(
          lyricsStyle: isHome && showLyrics,
          colorScheme: colorScheme,
        );

        final screenWidth = MediaQuery.sizeOf(context).width;
        final defaultWidth = screenWidth - MiniPlateLayout.sideInset * 2;

        final slideTranslation = _dragOffset > 0 ? _dragOffset : 0.0;
        final slideWidth = (defaultWidth - _dragOffset.abs()).clamp(
          80.0,
          defaultWidth,
        );

        final contentOpacity = (1.0 - _dragOffset.abs() / 150).clamp(0.0, 1.0);
        final buttonOpacity = (1.0 - _dragOffset.abs() / 100).clamp(0.0, 1.0);

        final meta = trackMetadataSignal();
        final playerOpen = mobileFullPlayerOpenSignal();

        // Visual gap only: the Android system navigation inset is applied by
        // the app shell (Positioned bottom offset in layout.dart), so it
        // must not be added here a second time.
        const bottomPadding = 8.0;
        // Height of the plate.
        const barHeight = 72.0;
        // Horizontal inset of the progress bar so it clears the rounded
        // bottom corners of the plate instead of hugging them.
        const progressInset = MiniPlateLayout.sideInset;

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _syncPlateRect();
        });

        return Opacity(
          // The full player draws a collapsed copy of the plate while it
          // collapses into it, so the two must never be visible at once.
          opacity: playerOpen ? 0 : 1,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              MiniPlateLayout.sideInset,
              0,
              MiniPlateLayout.sideInset,
              bottomPadding,
            ),
            child: SizedBox(
              height: barHeight,
              width: defaultWidth,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                dragStartBehavior: DragStartBehavior.down,
                onTap: _openFullPlayer,
                onVerticalDragDown: _onExpandDragDown,
                onVerticalDragUpdate: _onExpandDragUpdate,
                onVerticalDragEnd: _onExpandDragEnd,
                onVerticalDragCancel: _onExpandDragCancel,
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
                        key: _plateKey,
                        decoration: BoxDecoration(
                          color: surface.color.withValues(alpha: surface.alpha),
                          borderRadius: BorderRadius.circular(AppRadius.xxxl),
                        ),
                        // The border is a foreground decoration on purpose: a
                        // border inside `decoration` adds 1px of padding
                        // around the content, and the full player collapses
                        // into this plate, so both have to line up exactly.
                        foregroundDecoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(AppRadius.xxxl),
                          border: Border.all(color: surface.borderColor),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(AppRadius.xxxl),
                          child: BackdropFilter(
                            enabled:
                                blurEffectsEnabledSignal.value &&
                                surface.blur > 0,
                            filter: ui.ImageFilter.blur(
                              sigmaX: surface.blur,
                              sigmaY: surface.blur,
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
                                    child: const MiniPlayPauseButton(),
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
          left: MiniPlateLayout.sideInset,
          child: AnimatedOpacity(
            duration: animationDuration,
            curve: Curves.easeOutCubic,
            opacity: opacity,
            child: const _MobileCover(coverSize: MiniPlateLayout.coverSize),
          ),
        ),
        Positioned(
          left: MiniPlateLayout.titleInset,
          width: MiniPlateLayout.titleWidth(defaultWidth),
          child: AnimatedOpacity(
            duration: animationDuration,
            curve: Curves.easeOutCubic,
            opacity: opacity,
            child: const ClipRect(child: MiniTrackTextInfo()),
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
        final playerOpen = mobileFullPlayerOpenSignal();
        if (meta.id == null) return const SizedBox();

        final cover = AppCover(
          coverUrl: meta.coverUrl,
          size: coverSize,
          circle: true,
          placeholderIcon: Icons.music_note,
        );
        if (Platform.isAndroid) return cover;

        return AnimatedScale(
          scale: isPlaying ? 1.0 : AppCoverMotion.smallPausedScale,
          duration: playerOpen ? Duration.zero : AppCoverMotion.duration,
          curve: AppCoverMotion.curve,
          child: cover,
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
    // Sits inside the plate's BackdropFilter: without its own layer every
    // position tick would make the blur pass re-run over the whole plate.
    return RepaintBoundary(
      child: SignalBuilder(
        builder: (context) {
          final progress = trackProgressSignal();
          final duration = progress.durationMs;
          final position = progress.positionMs;

          final currentPosition = _dragValueMs ?? position;
          final max = duration > 0 ? duration : 1.0;
          final ratio = (currentPosition / max).clamp(0.0, 1.0);

          final theme = Theme.of(context);
          final colorScheme = theme.colorScheme;

          final navState = currentNavStateSignal.value;
          final showLyrics = showLyricsSignal.value;
          final isHome = navState.section == AppSection.home;

          final surface = MiniPlateSurface(
            lyricsStyle: isHome && showLyrics,
            colorScheme: colorScheme,
          );
          // The drag tooltip is a floating chip, not the plate itself, so it
          // gets a stronger blur than the plate backdrop.
          final blur = surface.lyricsStyle ? 0.0 : 3.0;

          return SizedBox(
            height: 16,
            width: widget.width,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.bottomCenter,
              children: [
                Positioned.fill(
                  child: M3ESlider(
                    value: currentPosition.clamp(0.0, max),
                    max: max,
                    decoration: miniProgressSliderDecoration(colorScheme),
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
                        _dragEndTimer = Timer(
                          const Duration(milliseconds: 500),
                          () {
                            if (mounted) setState(() => _dragValueMs = null);
                          },
                        );
                      });
                    },
                  ),
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
                            color: surface.color.withValues(
                              alpha: surface.alpha,
                            ),
                            borderRadius: BorderRadius.circular(AppRadius.xs),
                            border: Border.all(color: surface.borderColor),
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
      ),
    );
  }
}
