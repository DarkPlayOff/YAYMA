import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/core/views/widgets/common_ui.dart';
import 'package:yayma/src/features/playback/providers/lyrics_provider.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';

/// Shared timing for the active-line transition. Opacity, scale, blur, the
/// dimming of not-yet-sung words *and* the scroll that brings the line to the
/// centre all run on this, so nothing arrives out of step with the rest.
const Duration _lyricTransitionDuration = Duration(milliseconds: 600);
const Curve _lyricTransitionCurve = Curves.easeOutCubic;

/// Karaoke word highlighting has to keep up with the singing, so it gets its
/// own short duration rather than [_lyricTransitionDuration].
const Duration _karaokeWordDuration = Duration(milliseconds: 150);

/// First index in [lines] whose time is past [currentMs], or `lines.length`
/// if none. `lines` is time-sorted, so this binary-searches instead of
/// scanning — called on every progress tick (~8/sec while playing).
int _upperBoundByTime(List<LyricItem> lines, int currentMs) {
  var lo = 0;
  var hi = lines.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (lines[mid].time.inMilliseconds > currentMs) {
      hi = mid;
    } else {
      lo = mid + 1;
    }
  }
  return lo;
}

/// Shared type treatment for lyric text (plain and karaoke word rendering),
/// which differ only in color, weight, and an optional highlight glow.
TextStyle _lyricTextStyle({
  required Color color,
  required FontWeight fontWeight,
  Shadow? glow,
}) {
  return TextStyle(
    color: color,
    fontSize: Platform.isAndroid ? 32 : 48,
    fontWeight: fontWeight,
    letterSpacing: -2.2,
    height: 1.1,
    shadows: [
      ?glow,
      const Shadow(color: Colors.black45, blurRadius: 10, offset: Offset(0, 4)),
    ],
  );
}

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

  EffectCleanup? _loadingTrackingCleanup;
  EffectCleanup? _progressSubscriptionCleanup;

  @override
  void initState() {
    super.initState();
    _initialScrollDone = !widget.visible;
    _trackIdSignal.value = widget.trackId;
    _visibleSignal.value = widget.visible;

    _progressSubscriptionCleanup = _setupProgressSubscription();
    _loadingTrackingCleanup = _setupLoadingTracking();
  }

  EffectCleanup _setupLoadingTracking() {
    return effect(() {
      final lyricsState = lyricsSignal(_trackIdSignal.value).value;
      final isLoading = lyricsState.isLoading;
      final isEmpty = lyricsState.value?.items.isEmpty ?? false;
      final suppressDim = _visibleSignal.value && (isLoading || isEmpty);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) lyricsSuppressDimSignal.value = suppressDim;
      });
    });
  }

  EffectCleanup _setupProgressSubscription() {
    return effect(() {
      if (!_visibleSignal.value) return;

      final trackId = _trackIdSignal.value;
      final lyricsState = lyricsSignal(trackId).value;
      if (!lyricsState.hasValue) return;

      final lines = lyricsState.value!.items;
      if (lines.isEmpty) return;

      final progress = trackProgressSignal.value;
      final currentMs = progress.positionMs.toInt();
      final durationMs = progress.durationMs.toInt();

      // Lines are time-sorted, so a binary search for the first line past
      // `currentMs` is enough — this runs on every progress tick (~8/sec).
      var activeIndex = _upperBoundByTime(lines, currentMs) - 1;

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
    _progressSubscriptionCleanup?.call();
    _loadingTrackingCleanup?.call();
    _scrollController.dispose();
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
        // Same timing as the rows themselves, and an ease-*out* curve on
        // purpose: lines can follow each other faster than the animation
        // lasts, and a new `animateTo` restarts from zero velocity — with an
        // ease-in the scroll would visibly stall at every such hand-off.
        unawaited(
          _scrollController.animateTo(
            targetScroll,
            duration: _lyricTransitionDuration,
            curve: _lyricTransitionCurve,
          ),
        );
      }
    }
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
            data: (result) {
              final lines = result.items;
              if (lines.isEmpty) return const SizedBox.shrink();

              return Stack(
                children: [
                  LayoutBuilder(
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
                  ),
                  if (result.providerName.isNotEmpty)
                    Align(
                      alignment: Alignment.topCenter,
                      child: _LyricsSourceLabel(
                        key: ValueKey('${widget.trackId}_source'),
                        providerName: result.providerName,
                      ),
                    ),
                ],
              );
            },
            loading: () => const _LyricsLoadingIndicator(),
            error: (Object e, _) => CommonErrorWidget(error: e.toString()),
          ),
        );
      },
    );
  }
}

/// M3-Expressive loading state for the lyrics panel: the real Android M3
/// `LoadingIndicator` (ported by `m3e_core`), which morphs between
/// `RoundedPolygon` shapes with spring physics — near the top of the screen
/// instead of a centered spinner, shown while the text is being fetched (no
/// dark scrim behind it — see [lyricsSuppressDimSignal] in `layout.dart`).
class _LyricsLoadingIndicator extends StatelessWidget {
  const _LyricsLoadingIndicator();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 32),
        child: M3ELoadingIndicator(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

/// Shows the lyrics source above the text for a couple seconds, then fades
/// out and stays hidden. Keyed by track id so it re-appears for each new
/// track's lyrics.
class _LyricsSourceLabel extends StatefulWidget {
  final String providerName;

  const _LyricsSourceLabel({required this.providerName, super.key});

  @override
  State<_LyricsSourceLabel> createState() => _LyricsSourceLabelState();
}

class _LyricsSourceLabelState extends State<_LyricsSourceLabel> {
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _visible = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 600),
        opacity: _visible ? 1.0 : 0.0,
        child: Text(
          widget.providerName,
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 20,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ),
      ),
    );
  }
}

/// [ImageFiltered] with an animated blur sigma. `ImageFilter.blur` is a plain
/// value, so changing it rebuilds with the new radius instantly — this tweens
/// the sigma over [_lyricTransitionDuration] instead. The filter (and its
/// `saveLayer`) is skipped entirely once the blur is effectively zero.
class _AnimatedBlur extends StatelessWidget {
  final double sigma;
  final Widget child;

  const _AnimatedBlur({required this.sigma, required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: sigma),
      duration: _lyricTransitionDuration,
      curve: _lyricTransitionCurve,
      child: child,
      builder: (context, value, child) {
        if (value < 0.05) return child!;
        return ImageFiltered(
          imageFilter: ui.ImageFilter.blur(
            sigmaX: value,
            sigmaY: value,
            tileMode: TileMode.decal,
          ),
          child: child,
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
        // No blur beyond distance 2: at 0.05 opacity the row is barely
        // visible anyway, so skip the extra `ImageFiltered` saveLayer —
        // rows this far out are usually the majority of what's on screen,
        // and each one stacks another offscreen pass during the transition.
        opacity = 0.05;
        scale = 0.86;
        blur = 0.0;
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
            duration: _lyricTransitionDuration,
            curve: _lyricTransitionCurve,
            scale: scale,
            child: AnimatedOpacity(
              duration: _lyricTransitionDuration,
              curve: _lyricTransitionCurve,
              opacity: opacity,
              child: _AnimatedBlur(
                sigma: blur,
                // Word-synced lines use the karaoke layout whether or not they
                // are active. Swapping layouts on activation moved every word
                // and rescaled the `FittedBox` in a single frame; keeping one
                // layout means activating a line changes colour only.
                child: (line.words?.isNotEmpty ?? false)
                    ? _KaraokeLineText(line: line, isActive: isActive)
                    : FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          line.text,
                          textAlign: TextAlign.center,
                          style: _lyricTextStyle(
                            color: Colors.white,
                            fontWeight: isActive
                                ? FontWeight.w900
                                : FontWeight.w800,
                            glow: isActive
                                ? Shadow(
                                    color: Colors.white.withValues(
                                      alpha: 0.3,
                                    ),
                                    blurRadius: 20,
                                  )
                                : null,
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

/// Renders a lyric line word-by-word, highlighting each word as playback
/// position passes its start/end timing (karaoke-style), for providers that
/// supply word-synced timing (currently BetterLyrics).
///
/// Inactive lines are laid out exactly the same way — they just render every
/// word plain, and let the row's own opacity/blur do the dimming.
class _KaraokeLineText extends StatelessWidget {
  final LyricLine line;
  final bool isActive;

  const _KaraokeLineText({required this.line, required this.isActive});

  @override
  Widget build(BuildContext context) {
    // Only the active line follows playback position. Subscribing every
    // visible row to `trackProgressSignal` would rebuild the whole viewport
    // eight times a second for highlighting that isn't even shown.
    if (!isActive) {
      return _KaraokeLine(words: line.words!, currentMs: 0, lineActive: false);
    }

    return SignalBuilder(
      builder: (context) => _KaraokeLine(
        words: line.words!,
        currentMs: trackProgressSignal.value.positionMs.toInt(),
        lineActive: true,
      ),
    );
  }
}

/// How far singing has progressed through a line's words, expressed as the
/// count of fully-sung words plus the index of the word being sung right
/// now (or -1). Two different [currentMs] values can map to the same
/// signature — e.g. between two consecutive words, or during the silence
/// before the first one — which [_KaraokeLine] uses to skip rebuilding the
/// word row on progress ticks that don't actually change anything visible.
({int sungCount, int singingIndex}) _karaokeSignature(
  List<LyricWord> words,
  int currentMs,
) {
  var sungCount = 0;
  var singingIndex = -1;
  for (var i = 0; i < words.length; i++) {
    final word = words[i];
    if (currentMs >= word.end.inMilliseconds) {
      sungCount++;
    } else if (singingIndex == -1 &&
        currentMs >= word.start.inMilliseconds) {
      singingIndex = i;
    }
  }
  return (sungCount: sungCount, singingIndex: singingIndex);
}

/// Builds the word `Wrap` for a karaoke line, skipping the rebuild when the
/// [_karaokeSignature] derived from [currentMs] hasn't changed since the
/// last frame — the active line's `SignalBuilder` reruns ~8 times/sec while
/// playing, but words only actually transition state a handful of times.
class _KaraokeLine extends StatefulWidget {
  final List<LyricWord> words;
  final int currentMs;
  final bool lineActive;

  const _KaraokeLine({
    required this.words,
    required this.currentMs,
    required this.lineActive,
  });

  @override
  State<_KaraokeLine> createState() => _KaraokeLineState();
}

class _KaraokeLineState extends State<_KaraokeLine> {
  ({int sungCount, int singingIndex, bool lineActive})? _lastSignature;
  Widget? _lastBuilt;

  @override
  Widget build(BuildContext context) {
    final wordSignature = _karaokeSignature(widget.words, widget.currentMs);
    final signature = (
      sungCount: wordSignature.sungCount,
      singingIndex: wordSignature.singingIndex,
      lineActive: widget.lineActive,
    );
    final cached = _lastBuilt;
    if (cached != null && signature == _lastSignature) {
      return cached;
    }
    _lastSignature = signature;

    final built = FittedBox(
      fit: BoxFit.scaleDown,
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final word in widget.words)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: _KaraokeWordText(
                word: word,
                currentMs: widget.currentMs,
                lineActive: widget.lineActive,
              ),
            ),
        ],
      ),
    );
    _lastBuilt = built;
    return built;
  }
}

class _KaraokeWordText extends StatelessWidget {
  final LyricWord word;
  final int currentMs;
  final bool lineActive;

  const _KaraokeWordText({
    required this.word,
    required this.currentMs,
    required this.lineActive,
  });

  @override
  Widget build(BuildContext context) {
    final sung = lineActive && currentMs >= word.end.inMilliseconds;
    final singing =
        lineActive &&
        !sung &&
        currentMs >= word.start.inMilliseconds &&
        currentMs < word.end.inMilliseconds;
    // Dimmed only while its line is active and the word has not been reached.
    final pending = lineActive && !sung && !singing;

    return AnimatedDefaultTextStyle(
      // Two different transitions share this widget: not-yet-sung words dim
      // down as their line becomes active, which should ride the same slow
      // curve as the rest of the row, while a word lighting up mid-line has
      // to land on the beat.
      duration: pending ? _lyricTransitionDuration : _karaokeWordDuration,
      curve: pending ? _lyricTransitionCurve : Curves.linear,
      style: _lyricTextStyle(
        color: pending ? Colors.white30 : Colors.white,
        fontWeight: FontWeight.w900,
        glow: singing
            ? Shadow(color: Colors.white.withValues(alpha: 0.5), blurRadius: 24)
            : null,
      ),
      child: Text(word.text),
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
              data: (result) {
                final lines = result.items.whereType<LyricLine>().toList();
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
