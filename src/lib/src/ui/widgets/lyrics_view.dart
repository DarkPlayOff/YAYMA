import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/providers/lyrics_provider.dart';
import 'package:yayma/src/providers/playback_provider.dart';
import 'package:yayma/src/ui/widgets/common_ui.dart';

class LyricsWidget extends StatefulWidget {
  final String trackId;
  final bool visible;
  const LyricsWidget({required this.trackId, required this.visible, super.key});
  @override
  State<LyricsWidget> createState() => _LyricsWidgetState();
}

class _LyricsWidgetState extends State<LyricsWidget> {
  final ScrollController _scrollController = ScrollController();
  final FlutterSignal<int> _activeIndexSignal = signal<int>(-1);
  final FlutterSignal<String> _trackIdSignal = signal<String>('');
  final FlutterSignal<bool> _visibleSignal = signal<bool>(false);

  bool _initialScrollDone = false;
  Timer? _emptyLyricsTimer;
  String? _lastEmptyTrackId;

  @override
  void initState() {
    super.initState();
    _initialScrollDone = !widget.visible;
    _trackIdSignal.value = widget.trackId;
    _visibleSignal.value = widget.visible;

    _setupProgressSubscription();
  }

  void _setupProgressSubscription() {
    effect(() {
      if (!_visibleSignal.value) return;

      final trackId = _trackIdSignal.value;
      final lyricsState = lyricsSignal(trackId).value;
      if (!lyricsState.hasValue) return;

      final lines = lyricsState.value!;
      if (lines.isEmpty) return;

      final progress = trackProgressSignal.value;
      final currentMs = progress.positionMs.toInt();
      final durationMs = progress.durationMs.toInt();

      var activeIndex =
          lines.indexWhere((l) => l.time.inMilliseconds > currentMs) - 1;

      if (activeIndex == -2) {
        activeIndex = lines.length - 1;
      } else if (activeIndex < 0) {
        activeIndex = 0;
      }

      if (_activeIndexSignal.value != activeIndex) {
        _activeIndexSignal.value = activeIndex;
      }

      if (activeIndex == lines.length - 1) {
        final lastLine = lines.last;
        if (lastLine is LyricLine) {
          final lastLineEndMs =
              lastLine.time.inMilliseconds + lastLine.duration.inMilliseconds;
          if (currentMs > lastLineEndMs + 1000) {
            final remainingMs = durationMs - currentMs;
            if (remainingMs > 5000) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && !hideLyricsOverlaySignal.value) {
                  hideLyricsOverlaySignal.value = true;
                }
              });
            }
          }
        }
      }
    });
  }

  @override
  void didUpdateWidget(LyricsWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.trackId != oldWidget.trackId) {
      _initialScrollDone = !widget.visible;
      _activeIndexSignal.value = -1;
      _emptyLyricsTimer?.cancel();
      _lastEmptyTrackId = null;
      hideLyricsOverlaySignal.value = false;

      _trackIdSignal.value = widget.trackId;
      _visibleSignal.value = widget.visible;
    } else if (widget.visible != oldWidget.visible) {
      _visibleSignal.value = widget.visible;
      if (widget.visible) {
        _initialScrollDone = false;
      }
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _emptyLyricsTimer?.cancel();
    super.dispose();
  }

  double get _rowHeight => Platform.isAndroid ? 60.0 : 110.0;

  void _scrollToIndex(int index) {
    if (_scrollController.hasClients) {
      final targetScroll = index * _rowHeight;

      if (!_initialScrollDone) {
        _initialScrollDone = true;
        _scrollController.jumpTo(targetScroll);
      } else {
        unawaited(
          _scrollController.animateTo(
            targetScroll,
            duration: const Duration(milliseconds: 800),
            curve: Curves.easeInOutCubic,
          ),
        );
      }
    }
  }

  void _handleEmptyLyrics() {
    if (_lastEmptyTrackId == widget.trackId) return;
    _lastEmptyTrackId = widget.trackId;

    _emptyLyricsTimer?.cancel();
    _emptyLyricsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && !hideLyricsOverlaySignal.value) {
        hideLyricsOverlaySignal.value = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.visible) return const SizedBox.shrink();

    return SignalBuilder(
      builder: (context) {
        final lyricsAsync = lyricsSignal(widget.trackId).value;
        final hideOverlay = hideLyricsOverlaySignal.value;

        return AnimatedOpacity(
          duration: const Duration(milliseconds: 600),
          opacity: hideOverlay ? 0.0 : 1.0,
          child: lyricsAsync.map(
            data: (lines) {
              if (lines.isEmpty) {
                _handleEmptyLyrics();
                return const Center(
                  child: Text(
                    'Текст отсутствует',
                    style: TextStyle(color: Colors.white24, fontSize: 24),
                  ),
                );
              }

              return LayoutBuilder(
                builder: (context, constraints) {
                  final viewportHeight = constraints.maxHeight;

                  return SignalBuilder(
                    builder: (context) {
                      final activeIndex = _activeIndexSignal.value;

                      if (activeIndex != -1) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          _scrollToIndex(activeIndex);
                        });
                      }

                      return ShaderMask(
                        shaderCallback: (rect) => const LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.white,
                            Colors.white,
                            Colors.transparent,
                          ],
                          stops: [0.0, 0.25, 0.75, 1.0],
                        ).createShader(rect),
                        blendMode: BlendMode.dstIn,
                        child: ScrollConfiguration(
                          behavior: ScrollConfiguration.of(
                            context,
                          ).copyWith(scrollbars: false),
                          child: ListView.builder(
                            controller: _scrollController,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: lines.length,
                            padding: EdgeInsets.only(
                              top: (viewportHeight / 2) - (_rowHeight / 2),
                              bottom: viewportHeight / 2,
                            ),
                            itemExtent: _rowHeight,
                            itemBuilder: (context, index) {
                              final item = lines[index];
                              final isActive = index == activeIndex;
                              final distance = (index - activeIndex).abs();

                              return _LyricRow(
                                key: ValueKey('${widget.trackId}_$index'),
                                item: item,
                                isActive: isActive,
                                distance: distance,
                              );
                            },
                          ),
                        ),
                      );
                    },
                  );
                },
              );
            },
            loading: () => const CommonLoadingWidget(),
            error: (Object e, _) => CommonErrorWidget(error: e.toString()),
          ),
        );
      },
    );
  }
}

class _LyricRow extends StatelessWidget {
  final LyricItem item;
  final bool isActive;
  final int distance;

  const _LyricRow({
    required this.item,
    required this.isActive,
    required this.distance,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    if (item is LyricTimer) {
      return _LyricTimerWidget(
        item: item as LyricTimer,
        isActive: isActive,
      );
    }

    final line = item as LyricLine;
    var opacity = 1.0;
    var scale = 1.0;
    var blur = 0.0;

    if (isActive) {
      opacity = 1.0;
      scale = 1.0;
      blur = 0.0;
    } else {
      if (distance == 1) {
        opacity = 0.4;
        scale = 0.94;
        blur = 1.0;
      } else if (distance == 2) {
        opacity = 0.15;
        scale = 0.9;
        blur = 2.0;
      } else {
        opacity = 0.05;
        scale = 0.86;
        blur = 3.0;
      }
    }

    return RepaintBoundary(
      child: Center(
        child: Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(
            horizontal: Platform.isAndroid ? 16 : 48,
          ),
          alignment: Alignment.center,
          child: AnimatedScale(
            duration: const Duration(milliseconds: 600),
            curve: Curves.easeOutCubic,
            scale: scale,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 600),
              opacity: opacity,
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    line.text,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: Platform.isAndroid ? 32 : 48,
                      fontWeight: isActive ? FontWeight.w900 : FontWeight.w800,
                      letterSpacing: -2.2,
                      height: 1.1,
                      shadows: [
                        if (isActive)
                          Shadow(
                            color: Colors.white.withValues(alpha: 0.3),
                            blurRadius: 20,
                          ),
                        const Shadow(
                          color: Colors.black45,
                          blurRadius: 10,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LyricTimerWidget extends StatefulWidget {
  final LyricTimer item;
  final bool isActive;

  const _LyricTimerWidget({required this.item, required this.isActive});

  @override
  State<_LyricTimerWidget> createState() => _LyricTimerWidgetState();
}

class _LyricTimerWidgetState extends State<_LyricTimerWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    unawaited(_pulseController.repeat(reverse: true));
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final progress = trackProgressSignal.value;
        final currentMs = progress.positionMs.toInt();
        final remainingMs =
            (widget.item.time.inMilliseconds +
                widget.item.duration.inMilliseconds) -
            currentMs;
        final showDots =
            widget.isActive &&
            remainingMs > 0 &&
            (remainingMs / 1000).ceil() <= 5;

        if (!showDots) return const SizedBox.shrink();

        return Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(3, (index) {
              final dotValue = (remainingMs / 1000) - (2 - index);
              final active = dotValue > 0;

              return AnimatedBuilder(
                animation: _pulseController,
                builder: (context, child) {
                  final pulse = active
                      ? (_pulseController.value * 0.15 + 1.0)
                      : 1.0;
                  return Transform.scale(
                    scale: pulse,
                    child: child,
                  );
                },
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 12),
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: active ? 0.9 : 0.1),
                    shape: BoxShape.circle,
                    boxShadow: active
                        ? [
                            BoxShadow(
                              color: Colors.white.withValues(alpha: 0.2),
                              blurRadius: 8,
                            ),
                          ]
                        : null,
                  ),
                ),
              );
            }),
          ),
        );
      },
    );
  }
}

class LyricsReaderDialog extends StatefulWidget {
  final String trackId;
  final String title;

  const LyricsReaderDialog({
    required this.trackId,
    required this.title,
    super.key,
  });

  static void show(BuildContext context, String trackId, String title) {
    unawaited(
      showDialog<void>(
        context: context,
        builder: (context) =>
            LyricsReaderDialog(trackId: trackId, title: title),
      ),
    );
  }

  @override
  State<LyricsReaderDialog> createState() => _LyricsReaderDialogState();
}

class _LyricsReaderDialogState extends State<LyricsReaderDialog> {
  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final lyricsAsync = lyricsSignal(widget.trackId).value;
        return AlertDialog(
          backgroundColor: const Color(0xFF0F0F0F),
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  widget.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -1,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white38),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          content: Container(
            width: 650,
            height: 800,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: lyricsAsync.map(
              data: (items) {
                final lines = items.whereType<LyricLine>().toList();
                if (lines.isEmpty) {
                  return const Center(
                    child: Text(
                      'Текст отсутствует',
                      style: TextStyle(color: Colors.white24, fontSize: 18),
                    ),
                  );
                }
                return ListView.builder(
                  itemCount: lines.length,
                  itemBuilder: (context, index) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    child: Text(
                      lines[index].text,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        height: 1.3,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
                );
              },
              loading: () => const CommonLoadingWidget(),
              error: (Object e, _) => CommonErrorWidget(error: e.toString()),
            ),
          ),
        );
      },
    );
  }
}
