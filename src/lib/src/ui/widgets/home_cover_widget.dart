import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/providers/navigation_provider.dart';
import 'package:yayma/src/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/models.dart';
import 'package:yayma/src/ui/widgets/rust_cached_image.dart';

class CoverErrorPlaceholder extends StatelessWidget {
  const CoverErrorPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Colors.white10,
      child: Icon(Icons.music_note, size: 120, color: Colors.white24),
    );
  }
}

class HomeCoverWidget extends StatefulWidget {
  const HomeCoverWidget({super.key});

  @override
  State<HomeCoverWidget> createState() => _HomeCoverWidgetState();
}

class _HomeCoverWidgetState extends State<HomeCoverWidget> {

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final meta = trackMetadataSignal();
        final showLyrics = showLyricsSignal.value;
        final isPlaying = isPlayingSignal();
        final height = MediaQuery.of(context).size.height;
        final width = MediaQuery.of(context).size.width;
        final isNarrow = width < 600;

        var size = showLyrics ? 280.0 : 360.0;
        if (height < 800) size = showLyrics ? 240.0 : 300.0;
        if (height < 650) size = showLyrics ? 180.0 : 220.0;
        if (isNarrow && !showLyrics) size = width * 0.75;

        final scale = isPlaying ? 1.0 : 0.92;

        if (Platform.isAndroid) {
          return _AndroidCarousel(size: size);
        }

        return MouseRegion(
          cursor: meta.albumId != null ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: GestureDetector(
            onTap: () {
              if (meta.albumId != null) navigateTo(AppSection.album, meta.albumId);
            },
            child: AnimatedScale(
              scale: scale,
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeInOutCubic,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeInOutCubic,
                width: size,
                height: size,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(32),
                ),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 500),
                  transitionBuilder: (child, animation) {
                    return FadeTransition(
                      opacity: animation,
                      child: ScaleTransition(
                        scale: Tween<double>(begin: 0.9, end: 1).animate(animation),
                        child: child,
                      ),
                    );
                  },
                  child: ClipRRect(
                    key: ValueKey(meta.coverUrl),
                    borderRadius: BorderRadius.circular(32),
                    child: meta.coverUrl != null
                        ? RustCachedImage(
                            imageUrl: meta.coverUrl,
                            width: size,
                            height: size,
                            cacheWidth: size.toInt(),
                            cacheHeight: size.toInt(),
                            errorWidget: const CoverErrorPlaceholder(),
                          )
                        : const CoverErrorPlaceholder(),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _AndroidCarousel extends StatefulWidget {
  final double size;

  const _AndroidCarousel({required this.size});

  @override
  State<_AndroidCarousel> createState() => _AndroidCarouselState();
}

class _AndroidCarouselState extends State<_AndroidCarousel> with SingleTickerProviderStateMixin {
  late AnimationController _pageController;
  int _targetPage = 0;
  double _dragOffset = 0;
  bool _isDragging = false;
  
  EffectCleanup? _cleanup;
  late final FlutterSignal<bool> _visualPlaying = signal<bool>(isPlayingSignal.value);
  Timer? _bufferingTimer;
  EffectCleanup? _cleanupPlayback;

  @override
  void initState() {
    super.initState();
    _targetPage = playerStateSignal.value?.queueIndex ?? 0;
    _pageController = AnimationController(
      vsync: this,
      value: _targetPage.toDouble(),
      lowerBound: double.negativeInfinity,
      upperBound: double.infinity,
    );

    _cleanup = effect(() {
      final state = playerStateSignal.value;
      if (state == null) return;
      final queueIndex = state.queueIndex;
      final queue = queueTracksSignal.value.value ?? const [];
      if (queue.isEmpty) return;
      
      if (!_isDragging) {
        final currentMod = _targetPage % queue.length;
        var diff = queueIndex - currentMod;
        
        if (diff > queue.length / 2) diff -= queue.length;
        if (diff < -queue.length / 2) diff += queue.length;
        
        final newTarget = _targetPage + diff;
        
        if (_targetPage != newTarget) {
          _targetPage = newTarget;
          if (diff.abs() == 1) {
            _animateToPage(newTarget.toDouble());
          } else {
            _pageController.value = newTarget.toDouble();
          }
        }
      }
    });

    _cleanupPlayback = effect(() {
      final isPlaying = isPlayingSignal();
      final isBuffering = playerStateSignal.value?.isBuffering ?? false;

      if (isPlaying) {
        _bufferingTimer?.cancel();
        _bufferingTimer = null;
        _visualPlaying.value = true;
      } else {
        if (isBuffering) {
          // Delay scaling down during buffering to avoid cover flickering
          _bufferingTimer ??= Timer(const Duration(seconds: 1), () {
            _visualPlaying.value = false;
            _bufferingTimer = null;
          });
        } else {
          // Immediately scale down on pause
          _bufferingTimer?.cancel();
          _bufferingTimer = null;
          _visualPlaying.value = false;
        }
      }
    });
  }

  @override
  void dispose() {
    _cleanup?.call();
    _cleanupPlayback?.call();
    _bufferingTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  void _animateToPage(double page) {
    unawaited(_pageController.animateTo(
      page,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOutCubic,
    ));
  }

  void _handleDragStart(DragStartDetails details) {
    _isDragging = true;
    _pageController.stop();
    _dragOffset = 0;
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    if (!_isDragging) return;
    _dragOffset += details.primaryDelta ?? 0;
    
    final queue = queueTracksSignal.value.value ?? const [];
    if (queue.isEmpty) return;
    
    final state = playerStateSignal.value;
    final isRepeatAll = state?.repeatMode == RepeatModeDto.all;
    
    final pageDelta = -(_dragOffset / (widget.size * 0.59));
    final clampedDelta = pageDelta.clamp(-1.0, 1.0);
    _dragOffset = -clampedDelta * (widget.size * 0.59);
    
    var rawPage = _targetPage.toDouble() + clampedDelta;
    
    if (!isRepeatAll) {
      final currentIndex = _targetPage % queue.length;
      final minPage = _targetPage - currentIndex;
      final maxPage = _targetPage + (queue.length - 1 - currentIndex);
      rawPage = rawPage.clamp(minPage.toDouble(), maxPage.toDouble());
    }
    
    _pageController.value = rawPage;
  }

  void _handleDragEnd(DragEndDetails details) {
    if (!_isDragging) return;
    _isDragging = false;
    
    final queue = queueTracksSignal.value.value ?? const [];
    if (queue.isEmpty) return;
    
    final state = playerStateSignal.value;
    final isRepeatAll = state?.repeatMode == RepeatModeDto.all;
    
    final velocity = details.primaryVelocity ?? 0.0;
    var nextPage = _pageController.value.roundToDouble();
    
    if (velocity < -300) {
      nextPage = (_pageController.value + 0.5).floorToDouble() + 1;
    } else if (velocity > 300) {
      nextPage = (_pageController.value - 0.5).ceilToDouble() - 1;
    }
    
    nextPage = nextPage.clamp(_targetPage.toDouble() - 1.0, _targetPage.toDouble() + 1.0);
    
    if (!isRepeatAll) {
      final currentIndex = _targetPage % queue.length;
      final minPage = _targetPage - currentIndex;
      final maxPage = _targetPage + (queue.length - 1 - currentIndex);
      nextPage = nextPage.clamp(minPage.toDouble(), maxPage.toDouble());
    }
    
    final diff = (nextPage - _targetPage).toInt();
    _targetPage = nextPage.toInt();
    
    _animateToPage(nextPage);
    
    if (diff > 0) {
      for (var i = 0; i < diff; i++) {
        unawaited(PlaybackController.next());
      }
    } else if (diff < 0) {
      for (var i = 0; i < -diff; i++) {
        unawaited(PlaybackController.prev());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final queue = queueTracksSignal.value.value ?? const [];
    if (queue.isEmpty) return SizedBox(width: widget.size, height: widget.size);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: _handleDragStart,
      onHorizontalDragUpdate: _handleDragUpdate,
      onHorizontalDragEnd: _handleDragEnd,
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: _pageController,
          builder: (context, _) {
            final page = _pageController.value;
            final state = playerStateSignal.value;
            final isRepeatAll = state?.repeatMode == RepeatModeDto.all;
            
            final minIndex = (page - 1).floor();
            final maxIndex = (page + 1).ceil();
            
            final visibleIndices = <int>[];
            for (var i = minIndex; i <= maxIndex; i++) {
              if (!isRepeatAll) {
                final currentIndex = _targetPage % queue.length;
                final minP = _targetPage - currentIndex;
                final maxP = _targetPage + (queue.length - 1 - currentIndex);
                if (i < minP || i > maxP) continue;
              }
              visibleIndices.add(i);
            }
            
            visibleIndices.sort((a, b) {
              final distA = (page - a).abs();
              final distB = (page - b).abs();
              return distB.compareTo(distA);
            });
            
            return Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: visibleIndices.map((index) {
                final qIndex = ((index % queue.length) + queue.length) % queue.length;
                final track = queue[qIndex];
                final diff = (page - index).clamp(-1.0, 1.0);
                
                final isCenter = diff.abs() < 0.2;
                final itemScale = 1.0 - (0.28 * diff.abs());
                final opacity = 1.0 - (0.65 * diff.abs());
                
                final offset = (index - page) * 0.59 * widget.size;
                
                return Positioned(
                  left: offset,
                  width: widget.size,
                  height: widget.size,
                  child: SignalBuilder(
                    builder: (context) {
                      final isPlaying = _visualPlaying();
                      final centerScale = isPlaying ? 1.0 : 0.92;
                      final activeScale = centerScale + (1.0 - centerScale) * diff.abs();
                      
                      return Transform.scale(
                        scale: itemScale,
                        child: AnimatedScale(
                          scale: activeScale,
                          duration: const Duration(milliseconds: 350),
                          curve: Curves.easeInOutCubic,
                          child: Opacity(
                            opacity: opacity.clamp(0.0, 1.0),
                            child: GestureDetector(
                              onTap: () {
                                if (isCenter) {
                                  if (track.albumId != null) {
                                    navigateTo(AppSection.album, track.albumId);
                                  }
                                } else {
                                  final tapDiff = index - _targetPage;
                                  _targetPage = index;
                                  _animateToPage(index.toDouble());
                                  if (tapDiff > 0) {
                                    for (var i = 0; i < tapDiff; i++) {
                                      unawaited(PlaybackController.next());
                                    }
                                  } else if (tapDiff < 0) {
                                    for (var i = 0; i < -tapDiff; i++) {
                                      unawaited(PlaybackController.prev());
                                    }
                                  }
                                }
                              },
                              child: _CarouselCard(track: track, size: widget.size),
                            ),
                          ),
                        ),
                      );
                    }
                  ),
                );
              }).toList(),
            );
          },
        ),
      ),
    );
  }
}

class _CarouselCard extends StatelessWidget {
  final SimpleTrackDto track;
  final double size;

  const _CarouselCard({
    required this.track,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size * (32 / 360)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 16 * (size / 360),
              spreadRadius: 1,
            ),
          ],
        ),
        child: ClipRRect(
          key: ValueKey(track.coverUrl),
          borderRadius: BorderRadius.circular(size * (32 / 360)),
          child: track.coverUrl != null
              ? RustCachedImage(
                  imageUrl: track.coverUrl,
                  width: size,
                  height: size,
                  cacheWidth: size.toInt(),
                  cacheHeight: size.toInt(),
                  errorWidget: const CoverErrorPlaceholder(),
                )
              : const CoverErrorPlaceholder(),
        ),
      ),
    );
  }
}
