import 'dart:async';
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

  bool _hasBeenVisible = false;
  bool _initialScrollDone = false;
  Timer? _emptyLyricsTimer;
  String? _lastEmptyTrackId;

  final Map<String, List<_ProcessedLyricLine>> _processedLinesCache = {};

  @override
  void initState() {
    super.initState();
    _hasBeenVisible = widget.visible;
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
      _hasBeenVisible = widget.visible;
      _initialScrollDone = !widget.visible;
      _activeIndexSignal.value = -1;
      _emptyLyricsTimer?.cancel();
      _lastEmptyTrackId = null;
      _processedLinesCache.clear();
      hideLyricsOverlaySignal.value = false;

      _trackIdSignal.value = widget.trackId;
      _visibleSignal.value = widget.visible;
    } else if (widget.visible != oldWidget.visible) {
      _visibleSignal.value = widget.visible;
      if (widget.visible && !_hasBeenVisible) {
        _hasBeenVisible = true;
        _initialScrollDone = false;
      }
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _emptyLyricsTimer?.cancel();
    _processedLinesCache.clear();
    super.dispose();
  }

  static const double _rowHeight = 110;

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

  List<_ProcessedLyricLine> _getProcessedLines(List<LyricItem> items) {
    return _processedLinesCache.putIfAbsent(widget.trackId, () {
      return items.map((item) {
        if (item is LyricLine) {
          final words = item.text.split(' ');
          final wordDuration =
              item.duration.inMilliseconds / (words.isEmpty ? 1 : words.length);
          final processedWords = <_ProcessedWord>[];

          for (var i = 0; i < words.length; i++) {
            final wordStart = item.time.inMilliseconds + (i * wordDuration);
            final wordEnd = wordStart + wordDuration;
            processedWords.add(
              _ProcessedWord(words[i], wordStart.toInt(), wordEnd.toInt()),
            );
          }

          return _ProcessedLyricLine(item, processedWords);
        }
        return _ProcessedLyricLine(item, const []);
      }).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasBeenVisible) return const SizedBox.shrink();

    final lyricsAsync = lyricsSignal(widget.trackId).watch(context);
    final hideOverlay = hideLyricsOverlaySignal.watch(context);

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

          final processedLines = _getProcessedLines(lines);

          return LayoutBuilder(
            builder: (context, constraints) {
              final viewportHeight = constraints.maxHeight;

              return Watch((context) {
                final activeIndex = _activeIndexSignal.watch(context);

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
                      itemCount: processedLines.length,
                      padding: EdgeInsets.only(
                        top: (viewportHeight / 2) - (_rowHeight / 2),
                        bottom: viewportHeight / 2,
                      ),
                      itemExtent: _rowHeight,
                      itemBuilder: (context, index) {
                        final item = processedLines[index];
                        final isActive = index == activeIndex;
                        final distance = (index - activeIndex).abs();

                        return _AppleLyricRow(
                          key: ValueKey('${widget.trackId}_$index'),
                          item: item,
                          isActive: isActive,
                          distance: distance,
                        );
                      },
                    ),
                  ),
                );
              });
            },
          );
        },
        loading: () => const CommonLoadingWidget(),
        error: (Object e, _) => CommonErrorWidget(error: e.toString()),
      ),
    );
  }
}

@immutable
class _ProcessedWord {
  final String text;
  final int startTimeMs;
  final int endTimeMs;
  const _ProcessedWord(this.text, this.startTimeMs, this.endTimeMs);
}

@immutable
class _ProcessedLyricLine {
  final LyricItem original;
  final List<_ProcessedWord> words;
  const _ProcessedLyricLine(this.original, this.words);
}

class _AppleLyricRow extends StatelessWidget {
  final _ProcessedLyricLine item;
  final bool isActive;
  final int distance;

  const _AppleLyricRow({
    required this.item,
    required this.isActive,
    required this.distance,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    if (item.original is LyricTimer) {
      return _LyricTimerWidget(
        item: item.original as LyricTimer,
        isActive: isActive,
      );
    }

    final line = item.original as LyricLine;
    var opacity = 1.0;
    var scale = 1.0;

    if (!isActive) {
      if (distance == 1) {
        opacity = 0.4;
        scale = 0.94;
      } else if (distance == 2) {
        opacity = 0.15;
        scale = 0.9;
      } else {
        opacity = 0.05;
        scale = 0.86;
      }
    }

    return RepaintBoundary(
      child: Center(
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 48),
          alignment: Alignment.center,
          child: AnimatedScale(
            duration: const Duration(milliseconds: 800),
            curve: Curves.easeInOutCubic,
            scale: scale,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 800),
              opacity: opacity,
              child: _WordByWordText(
                words: item.words,
                text: line.text,
                isActive: isActive,
                distance: distance,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WordByWordText extends StatelessWidget {
  final List<_ProcessedWord> words;
  final String text;
  final bool isActive;
  final int distance;

  const _WordByWordText({
    required this.words,
    required this.text,
    required this.isActive,
    required this.distance,
  });

  @override
  Widget build(BuildContext context) {
    const baseStyle = TextStyle(
      color: Colors.white,
      fontSize: 48,
      fontWeight: FontWeight.w900,
      letterSpacing: -2.2,
      height: 1,
    );

    return FittedBox(
      fit: BoxFit.scaleDown,
      child: isActive
          ? _buildActiveContent(baseStyle)
          : _buildInactiveContent(baseStyle),
    );
  }

  Widget _buildInactiveContent(TextStyle baseStyle) {
    final content = Text(
      text,
      style: baseStyle.copyWith(color: baseStyle.color?.withValues(alpha: 0.8)),
      textAlign: TextAlign.center,
    );

    // Apply blur only if close to active line to save resources
    if (distance <= 2) {
      return ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: 1, sigmaY: 1),
        child: content,
      );
    }

    return content;
  }

  Widget _buildActiveContent(TextStyle baseStyle) {
    if (words.isEmpty)
      return Text(text, style: baseStyle, textAlign: TextAlign.center);

    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: words
          .map(
            (word) => _WordWidget(
              key: ValueKey(word.startTimeMs),
              word: word,
              baseStyle: baseStyle,
            ),
          )
          .toList(),
    );
  }
}

enum _WordStatus { future, current, past }

class _WordWidget extends StatelessWidget {
  final _ProcessedWord word;
  final TextStyle baseStyle;

  const _WordWidget({
    required this.word,
    required this.baseStyle,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      // Use select to rebuild only when this word status actually changes
      final status = trackProgressSignal
          .select((s) {
            final currentMs = s.value.positionMs;
            if (currentMs > word.endTimeMs) return _WordStatus.past;
            if (currentMs >= word.startTimeMs) return _WordStatus.current;
            return _WordStatus.future;
          })
          .watch(context);

      var wordOpacity = 1.0;
      var wordScale = 1.0;
      var glow = 0.0;

      switch (status) {
        case _WordStatus.current:
          wordScale = 1.1;
          glow = 1.0;
          wordOpacity = 1.0;
        case _WordStatus.past:
          wordOpacity = 0.6;
        case _WordStatus.future:
          wordOpacity = 0.4;
      }

      return Padding(
        padding: const EdgeInsets.only(right: 12),
        child: AnimatedScale(
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOutCubic,
          scale: wordScale,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 400),
            opacity: wordOpacity,
            child: Text(
              word.text,
              style: baseStyle.copyWith(
                shadows: [
                  if (glow > 0)
                    Shadow(
                      color: Colors.white.withValues(alpha: 0.5 * glow),
                      blurRadius: 30,
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
      );
    });
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
      duration: const Duration(
        milliseconds: 942,
      ), // Close to sin(ms/150) period
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      // Rebuild only when visibility or active dots count changes
      final progress = trackProgressSignal.watch(context);
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

      return AnimatedOpacity(
        duration: const Duration(milliseconds: 400),
        opacity: 1,
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
                    ? (_pulseController.value * 0.2 + 1.0)
                    : 1.0;
                return Transform.scale(
                  scale: pulse,
                  child: child,
                );
              },
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 10),
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: active ? 1.0 : 0.2),
                  shape: BoxShape.circle,
                  boxShadow: active
                      ? [
                          BoxShadow(
                            color: Colors.white.withValues(alpha: 0.3),
                            blurRadius: 10,
                          ),
                        ]
                      : null,
                ),
              ),
            );
          }),
        ),
      );
    });
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
      backgroundColor: const Color(0xFF0F0F0F),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      title: Row(
        children: [
          Expanded(
            child: Text(
              title,
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
            if (lines.isEmpty)
              return const Center(
                child: Text(
                  'Текст отсутствует',
                  style: TextStyle(color: Colors.white24, fontSize: 18),
                ),
              );
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
  }
}
