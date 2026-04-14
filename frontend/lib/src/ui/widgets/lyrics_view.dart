import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:m3e_collection/m3e_collection.dart';
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
  static const double _itemHeight = 120;
  int _lastActiveIndex = -1;
  bool _hasBeenVisible = false;
  bool _initialScrollDone = false;

  @override
  void initState() {
    super.initState();
    _hasBeenVisible = widget.visible;
    _initialScrollDone = !widget.visible;
  }

  @override
  void didUpdateWidget(LyricsWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.trackId != oldWidget.trackId) {
      _hasBeenVisible = widget.visible;
      _initialScrollDone = !widget.visible;
    } else if (widget.visible && !_hasBeenVisible) {
      _hasBeenVisible = true;
      _initialScrollDone = false;
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToIndex(int index, List<dynamic> lines, double viewportHeight) {
    if (index != _lastActiveIndex || !_initialScrollDone) {
      _lastActiveIndex = index;
      if (_scrollController.hasClients && index >= 0 && index < lines.length) {
        double offsetBefore = 0;
        for (var i = 0; i < index; i++) {
          offsetBefore += lines[i] is LyricTimer ? 250 : _itemHeight;
        }

        final currentHeight = lines[index] is LyricTimer ? 250 : _itemHeight;
        // Т.к. у нас padding.top = viewportHeight / 2,
        // начало списка уже в центре. Нам нужно прокрутить только на высоту элементов.
        final targetScroll = offsetBefore + (currentHeight / 2);

        if (!_initialScrollDone) {
          _initialScrollDone = true;
          _scrollController.jumpTo(targetScroll);
        } else {
          unawaited(
            _scrollController.animateTo(
              targetScroll,
              duration: const Duration(milliseconds: 500),
              curve: Curves.easeOutCubic,
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasBeenVisible) {
      return const SizedBox.shrink();
    }

    final lyricsAsync = lyricsSignal(widget.trackId).watch(context);
    return lyricsAsync.map(
      data: (lines) {
        if (lines.isEmpty) {
          return const Center(
            child: Text(
              'Текст отсутствует',
              style: TextStyle(color: Colors.white24),
            ),
          );
        }
        return Watch((context) {
          final progress = trackProgressSignal.watch(context);
          final currentMs = progress.positionMs.toInt();
          var activeIndex =
              lines.indexWhere((l) => l.time.inMilliseconds > currentMs) - 1;
          if (activeIndex < -1) activeIndex = lines.length - 1;
          if (activeIndex == -2) activeIndex = lines.length - 1;

          return LayoutBuilder(
            builder: (context, constraints) {
              final viewportHeight = constraints.maxHeight;
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => _scrollToIndex(activeIndex, lines, viewportHeight),
              );
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
                  stops: [0.0, 0.2, 0.8, 1.0],
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
                    padding: EdgeInsets.symmetric(vertical: viewportHeight / 2),
                    itemBuilder: (context, index) {
                      final item = lines[index];
                      final distance = (index - activeIndex).abs();
                      final isHighlight = distance == 0;
                      final opacity = isHighlight
                          ? 1.0
                          : (distance == 1 ? 0.4 : (distance == 2 ? 0.1 : 0.0));
                      final scale = isHighlight ? 1.1 : 1.0;

                      Widget content;
                      if (item is LyricLine) {
                        content = Text(
                          item.text,
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 36,
                            fontWeight: FontWeight.w800,
                            shadows: [Shadow(blurRadius: 20)],
                          ),
                        );
                      } else if (item is LyricTimer) {
                        final remainingMs =
                            (item.time.inMilliseconds +
                                item.duration.inMilliseconds) -
                            currentMs;
                        final elapsedMs = currentMs - item.time.inMilliseconds;

                        // Плавное появление в первые 500мс и исчезновение в последние 1000мс
                        var timerOpacity = 1.0;
                        if (elapsedMs < 500) {
                          timerOpacity = (elapsedMs / 500).clamp(0.0, 1.0);
                        } else if (remainingMs < 1000) {
                          timerOpacity = (remainingMs / 1000).clamp(0.0, 1.0);
                        }

                        if (remainingMs <= 0) {
                          content = const SizedBox.shrink();
                        } else {
                          final seconds = (remainingMs / 1000).ceil();

                          content = AnimatedOpacity(
                            duration: const Duration(milliseconds: 200),
                            opacity: timerOpacity,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                Transform.scale(
                                  scale: 2,
                                  child: const LoadingIndicatorM3E(
                                    color: Colors.white10,
                                  ),
                                ),
                                Text(
                                  '$seconds',
                                  style: const TextStyle(
                                    color: Colors.white38,
                                    fontSize: 42,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: -2,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }
                      } else {
                        content = const SizedBox.shrink();
                      }

                      return GestureDetector(
                        onTap: () => unawaited(
                          PlaybackController.seekTo(
                            Duration(
                              milliseconds: item.time.inMilliseconds,
                            ),
                          ),
                        ),
                        child: Container(
                          height: item is LyricTimer ? 250 : _itemHeight,
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          alignment: Alignment.centerRight,
                          child: AnimatedScale(
                            duration: const Duration(milliseconds: 400),
                            curve: Curves.easeOutCubic,
                            scale: scale,
                            alignment: Alignment.centerRight,
                            child: AnimatedOpacity(
                              duration: const Duration(milliseconds: 400),
                              opacity: opacity,
                              child: item is LyricTimer
                                  ? content
                                  : Container(
                                      constraints: BoxConstraints(
                                        maxWidth: math.max(
                                          0,
                                          (constraints.maxWidth - 40) / 1.1,
                                        ),
                                      ),
                                      child: FittedBox(
                                        fit: BoxFit.scaleDown,
                                        alignment: Alignment.centerRight,
                                        child: content,
                                      ),
                                    ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              );
            },
          );
        });
      },
      loading: () => const CommonLoadingWidget(),
      error: (Object e, _) => CommonErrorWidget(error: e.toString()),
    );
  }
}

class LyricsReaderDialog extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final lyricsAsync = lyricsSignal(trackId).watch(context);

    return AlertDialog(
      backgroundColor: const Color(0xFF181818),
      surfaceTintColor: Colors.transparent,
      title: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(color: Colors.white, fontSize: 20),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 600,
        height: 700,
        child: lyricsAsync.map(
          data: (items) {
            final lines = items.whereType<LyricLine>().toList();
            if (lines.isEmpty) {
              return const Center(
                child: Text(
                  'Текст отсутствует',
                  style: TextStyle(color: Colors.white24),
                ),
              );
            }
            return ListView.builder(
              itemCount: lines.length,
              itemBuilder: (context, index) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  lines[index].text,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 18,
                    height: 1.5,
                  ),
                ),
              ),
            );
          },
          loading: () => const CommonLoadingWidget(),
          error: (Object e, StackTrace? _) =>
              CommonErrorWidget(error: e.toString()),
        ),
      ),
    );
  }
}
