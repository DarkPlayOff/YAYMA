// Thanks Metrolist's for reference lyrics view — ExperimentalLyrics.kt and
// LyricsLine.kt (github.com/MetrolistGroup/Metrolist).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/rendering.dart'
    show RenderAbstractViewport, ScrollDirection;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/core/views/widgets/common_ui.dart';
import 'package:yayma/src/features/playback/providers/lyrics_provider.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';

/// Synced lyrics: the active line sits at 35% of the viewport, the list glides
/// there with a per-line stagger, and every line is tinted with the cover
/// accent, fading with distance. The sung line fills word by word.
class PlayerLyrics extends StatefulWidget {
  final String trackId;
  final Color? accent;

  const PlayerLyrics({required this.trackId, this.accent, super.key});

  @override
  State<PlayerLyrics> createState() => _PlayerLyricsState();
}

class _PlayerLyricsState extends State<PlayerLyrics>
    with TickerProviderStateMixin {
  final ScrollController _scroll = ScrollController();
  final Map<int, GlobalKey> _keys = {};

  int _activeIndex = -1;

  /// Distance of the last auto-scroll: the cascade is scaled by it.
  double _scrollDelta = 0;

  bool _follow = true;
  EffectCleanup? _cleanup;

  /// Item count of the last reported lyrics, used to estimate a scroll offset.
  int _itemCount = 0;

  late final AnimationController _cascade;

  /// Rust reports the position every 125 ms, so a ticker extrapolates between
  /// reports to keep the word animation at display rate.
  late final Ticker _ticker;
  final ValueNotifier<double> _clock = ValueNotifier(0);
  Duration _elapsed = Duration.zero;

  /// Smoothed difference between the ticker clock and the reported position,
  /// so a report nudges the clock instead of snapping it backwards.
  double _offsetMs = 0;

  static const double _anchor = 0.35;
  static const Duration _scrollDuration = Duration(milliseconds: 750);
  static const Duration _cascadeWindow = Duration(milliseconds: 750);

  @override
  void initState() {
    super.initState();
    _cascade = AnimationController(vsync: this, duration: _cascadeWindow)
      ..value = 1;
    _ticker = createTicker(_onTick);
    _cleanup = effect(() {
      final lyrics = lyricsSignal(widget.trackId).value;
      if (!lyrics.hasValue) return;
      final items = lyrics.value!.items;
      if (items.isEmpty) return;
      _itemCount = items.length;

      final ms = trackProgressSignal.value.positionMs.toInt();
      final playing = isPlayingSignal.value;

      final elapsedMs = _elapsed.inMicroseconds / 1000;
      if (playing) {
        if (!_ticker.isActive) {
          // A ticker restarts its clock at zero on every start().
          _elapsed = Duration.zero;
          _offsetMs = ms.toDouble();
          _ticker.start();
        } else {
          final error = ms - elapsedMs - _offsetMs;
          // A seek moves the position far faster than playback: follow it at
          // once, or the fill replays from the old spot. Everything else is
          // smoothed so a jittery report does not snap the clock backwards.
          _offsetMs += error * (error.abs() > 500 ? 1 : 0.5);
        }
      } else {
        if (_ticker.isActive) _ticker.stop();
        _clock.value = ms.toDouble();
      }

      var index = upperBoundByTime(items, ms) - 1;
      if (index < 0) index = 0;

      final current = index < items.length && items[index] is LyricLine
          ? index
          : -1;
      if (current == _activeIndex) return;
      setState(() => _activeIndex = current);
      if (_follow) {
        _cascade.forward(from: 0);
        _bringIntoView(index);
      }
    });
  }

  void _onTick(Duration elapsed) {
    _elapsed = elapsed;
    _clock.value = elapsed.inMicroseconds / 1000 + _offsetMs;
  }

  /// Our own `animateTo` emits no [UserScrollNotification], so only a real
  /// drag can pause the follow.
  bool _handleUserScroll(UserScrollNotification notification) {
    if (_follow && notification.direction != ScrollDirection.idle) {
      setState(() => _follow = false);
    }
    return false;
  }

  void _snapToCurrentLine() {
    setState(() => _follow = true);
    _cascade.forward(from: 0);
    _bringIntoView(_activeIndex < 0 ? 0 : _activeIndex);
  }

  void _jumpToLine(LyricItem item) {
    setState(() => _follow = true);
    unawaited(PlaybackController.seekTo(item.time));
  }

  void _bringIntoView(int index) {
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _bringIntoViewNow(index),
    );
  }

  void _bringIntoViewNow(int index, {bool cascade = true, bool retry = true}) {
    if (!mounted || !_scroll.hasClients) return;
    final renderObject = _keys[index]?.currentContext?.findRenderObject();
    if (renderObject == null) {
      // Opening mid-song leaves the active line outside the lazy range: jump
      // once to its share of the list so it gets built, then anchor it for
      // real. Row heights vary with wrapping, so a guess in pixels can land
      // where the line is still not built; in that case stop instead of
      // re-posting the same jump every frame.
      final position = _scroll.position;
      final target = _itemCount <= 0
          ? 0.0
          : position.maxScrollExtent * index / _itemCount;
      if (!retry || (target - position.pixels).abs() < 1) return;
      _scroll.jumpTo(
        target.clamp(position.minScrollExtent, position.maxScrollExtent),
      );
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _bringIntoViewNow(index, cascade: false, retry: false),
      );
      return;
    }
    final position = _scroll.position;
    final target = RenderAbstractViewport.of(renderObject)
        .getOffsetToReveal(renderObject, _anchor)
        .offset
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    final delta = position.pixels - target;
    if (cascade && delta.abs() > 1) setState(() => _scrollDelta = delta);
    _scroll.animateTo(
      target,
      duration: _scrollDuration,
      curve: Curves.fastOutSlowIn,
    );
  }

  @override
  void dispose() {
    _cleanup?.call();
    _ticker.dispose();
    _clock.dispose();
    _cascade.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// The sung line is solid, neighbours fade out fast so only a couple of lines
  /// compete with it.
  double _lineAlpha(int index) {
    if (index == _activeIndex) return 1;
    if (!_follow) return 0.2;
    if (_activeIndex < 0) return 0.5;
    return switch ((index - _activeIndex).abs()) {
      1 => 0.45,
      2 => 0.3,
      3 => 0.2,
      4 => 0.14,
      _ => 0.09,
    };
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final accent = widget.accent ?? cs.primary;

    return SignalBuilder(
      builder: (context) {
        final lyrics = lyricsSignal(widget.trackId).value;
        return lyrics.map(
          data: (result) {
            final items = result.items;
            if (items.isEmpty) {
              return Center(
                child: Text(
                  'Текст не найден',
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
              );
            }
            return Stack(
              children: [
                ShaderMask(
                  // Alpha fade only: a colour scrim in the panel tone showed as
                  // a dark band, because the panel is accent-tinted there.
                  shaderCallback: (rect) => const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.white,
                      Colors.white,
                      Colors.transparent,
                    ],
                    stops: [0, 0.1, 0.82, 1],
                  ).createShader(rect),
                  blendMode: BlendMode.dstIn,
                  child: RepaintBoundary(
                    child: NotificationListener<UserScrollNotification>(
                      onNotification: _handleUserScroll,
                      child: ListView.builder(
                        controller: _scroll,
                        physics: const BouncingScrollPhysics(),
                        padding: EdgeInsets.symmetric(
                          vertical: MediaQuery.sizeOf(context).height * 0.1,
                        ),
                        itemCount: items.length,
                        itemBuilder: (context, index) {
                          _keys.putIfAbsent(index, GlobalKey.new);
                          final item = items[index];
                          return _CascadeRow(
                            animation: _cascade,
                            scrollDelta: _scrollDelta,
                            distance:
                                (_activeIndex < 0 ? 0 : index - _activeIndex)
                                    .abs(),
                            child: Padding(
                              key: _keys[index],
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: item is LyricLine
                                  ? _LineRow(
                                      line: item,
                                      active: index == _activeIndex,
                                      // Only the sung line and the one about to
                                      // be sung still move; further rows would
                                      // re-layout per frame for nothing.
                                      animated:
                                          _activeIndex >= 0 &&
                                          index >= _activeIndex &&
                                          index <= _activeIndex + 1,
                                      alpha: _lineAlpha(index),
                                      accent: accent,
                                      clock: _clock,
                                      onTap: () => _jumpToLine(item),
                                    )
                                  : _GapDots(
                                      active: index == _activeIndex,
                                      alpha: _lineAlpha(index),
                                      accent: accent,
                                      onTap: () => _jumpToLine(item),
                                    ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
                if (!_follow)
                  Positioned(
                    right: 4,
                    bottom: 12,
                    child: _BackToLineButton(
                      accent: accent,
                      onPressed: _snapToCurrentLine,
                    ),
                  ),
              ],
            );
          },
          loading: () => const CommonLoadingWidget(),
          error: (Object e, _) => CommonErrorWidget(error: e.toString()),
        );
      },
    );
  }
}

/// Runs the list's own scroll tween, but starting later the further the line is
/// from the active one.
class _CascadeRow extends StatelessWidget {
  final Animation<double> animation;
  final int distance;
  final double scrollDelta;
  final Widget child;

  const _CascadeRow({
    required this.animation,
    required this.distance,
    required this.scrollDelta,
    required this.child,
  });

  static const double _delayPerDistance = 0.027; // 20 ms of 750 ms
  static const double _maxDelay = 0.267; // 200 ms of 750 ms

  @override
  Widget build(BuildContext context) {
    final delay = (distance * _delayPerDistance).clamp(0.0, _maxDelay);
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final t = animation.value;
        final delayed = delay >= 1
            ? 1.0
            : ((t - delay) / (1 - delay)).clamp(0.0, 1.0);
        // Only the difference from the shared motion; zero at both ends, so a
        // line change never jumps.
        final lag =
            scrollDelta *
            (Curves.fastOutSlowIn.transform(delayed) -
                Curves.fastOutSlowIn.transform(t));
        return Transform.translate(offset: Offset(0, lag), child: child);
      },
    );
  }
}

class _LineRow extends StatelessWidget {
  final LyricLine line;
  final bool active;
  final bool animated;
  final double alpha;
  final Color accent;
  final ValueListenable<double> clock;
  final VoidCallback onTap;

  const _LineRow({
    required this.line,
    required this.active,
    required this.animated,
    required this.alpha,
    required this.accent,
    required this.clock,
    required this.onTap,
  });

  /// Every line uses the same metrics: resizing the active one re-wrapped it
  /// and made the whole list jump.
  static const double _fontSize = 36;
  static const TextStyle _style = TextStyle(
    fontSize: _fontSize,
    fontWeight: FontWeight.w700,
    height: 1.3,
    letterSpacing: -0.5,
  );

  @override
  Widget build(BuildContext context) {
    final words = line.words ?? synthLyricWords(line);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: DefaultTextStyle(
        style: _style,
        // The explicit colours below defeat DefaultTextStyle's own animation,
        // so the 250 ms fade is driven here.
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: alpha, end: alpha),
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          builder: (context, faded, _) {
            final color = accent.withValues(alpha: faded);
            if (words.isEmpty) {
              return Text(line.text, style: TextStyle(color: color));
            }
            if (!animated) return _LineWords(words: words, color: color);
            return ValueListenableBuilder<double>(
              valueListenable: clock,
              builder: (context, ms, _) {
                final springs = _wordSprings(words, ms);
                return _LineWords(
                  words: words,
                  color: color,
                  springs: springs,
                  nowMs: active ? ms : null,
                  unsung: accent.withValues(alpha: faded * 0.45),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

/// A line-level LRC has no word timings, so the text is split and they are
/// invented — otherwise word animation never runs. Unlike Metrolist's fixed
/// 0.18 s, the words span the real line duration so the fill tracks the song.
List<LyricWord> synthLyricWords(LyricLine line) {
  final parts = line.text
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .toList();
  if (parts.isEmpty) return const [];
  final span = line.duration.inMilliseconds;
  final step = span > 0 ? span / parts.length : 300.0;
  return [
    for (var i = 0; i < parts.length; i++)
      LyricWord(
        text: parts[i],
        start: line.time + Duration(milliseconds: (i * step).round()),
        end: line.time + Duration(milliseconds: ((i + 1) * step).round()),
      ),
  ];
}

/// Laid out identically in every state, so switching between dim, sung and
/// idle never re-wraps the line.
class _LineWords extends StatelessWidget {
  final List<LyricWord> words;
  final Color color;
  final List<_WordSpring>? springs;

  /// When set, each word fills on its own timing: a line wrapping into three
  /// rows then fills row after row instead of all three at the same x.
  final double? nowMs;
  final Color? unsung;

  const _LineWords({
    required this.words,
    required this.color,
    this.springs,
    this.nowMs,
    this.unsung,
  });

  /// Width of the soft leading edge, in logical pixels.
  static const double _softEdge = 12;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      children: [
        for (var i = 0; i < words.length; i++)
          Padding(
            padding: EdgeInsets.only(right: i == words.length - 1 ? 0 : 9),
            child: Transform.translate(
              offset: Offset(0, springs?[i].dy ?? 0),
              child: Transform.scale(
                scaleX: springs?[i].scaleX ?? 1,
                scaleY: springs?[i].scaleY ?? 1,
                alignment: Alignment.bottomLeft,
                child: _FillingWord(
                  word: words[i],
                  color: color,
                  unsung: unsung,
                  fill: nowMs == null ? null : _fillProgress(words[i], nowMs!),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Dim, fully sung, or mid-fill with a soft edge. The dim copy stays underneath
/// so the un-sung half remains readable; at most one word is mid-fill at a time,
/// so this costs one small `saveLayer`.
class _FillingWord extends StatelessWidget {
  final LyricWord word;
  final Color color;
  final Color? unsung;
  final double? fill;

  const _FillingWord({
    required this.word,
    required this.color,
    required this.unsung,
    required this.fill,
  });

  @override
  Widget build(BuildContext context) {
    final progress = fill;
    final dim = unsung ?? color;
    if (progress == null || progress >= 1) {
      return Text(word.text, style: TextStyle(color: color));
    }
    return Stack(
      children: [
        Text(word.text, style: TextStyle(color: dim)),
        if (progress > 0)
          ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (rect) {
              final edge = rect.width <= 0
                  ? 0.0
                  : (_LineWords._softEdge / rect.width).clamp(0.0, 1.0);
              return LinearGradient(
                colors: const [
                  Colors.white,
                  Colors.white,
                  Colors.transparent,
                  Colors.transparent,
                ],
                stops: [0, progress, (progress + edge).clamp(0.0, 1.0), 1],
              ).createShader(rect);
            },
            child: Text(word.text, style: TextStyle(color: color)),
          ),
      ],
    );
  }
}

/// 0 → not sung yet, 1 → done.
double _fillProgress(LyricWord word, double nowMs) {
  final start = word.start.inMilliseconds;
  final end = word.end.inMilliseconds;
  if (nowMs <= start) return 0;
  if (nowMs >= end) return 1;
  final span = end - start;
  return span <= 0 ? 1 : (nowMs - start) / span;
}

class _WordSpring {
  final double scaleX;
  final double scaleY;
  final double dy;

  const _WordSpring({
    required this.scaleX,
    required this.scaleY,
    required this.dy,
  });
}

/// Per-word spring: the word being sung springs once, the next one leans in
/// just before its turn, and a held word breathes.
List<_WordSpring> _wordSprings(List<LyricWord> words, double nowMs) {
  final springs = <_WordSpring>[];

  for (var i = 0; i < words.length; i++) {
    final word = words[i];
    final start = word.start.inMilliseconds;
    final end = word.end.inMilliseconds;
    final duration = math.max(100, end - start);
    final p = ((nowMs - start) / duration).clamp(0.0, 1.0);
    final pOut = ((nowMs - end) / 600).clamp(0.0, 1.0);

    // Only the word being sung springs: Metrolist re-lays its glyphs to make
    // room for an accumulating push, we scale in place.
    const peak = 0.06;
    var push = 0.0;
    if (pOut > 0) {
      push =
          peak *
          math.exp(-3.5 * pOut) *
          math.cos(5 * math.pi * pOut) *
          (1 - pOut);
    } else if (nowMs >= start) {
      push =
          peak * (1 - math.exp(-3.5 * p) * math.cos(5 * math.pi * p) * (1 - p));
    }

    final wait = ((nowMs - (start - 400)) / 400).clamp(0.0, 1.0);
    final nudge = nowMs < start ? 0.038 * math.sin(wait * math.pi) : 0.0;

    final held = nowMs >= start && nowMs <= end;
    final wave = held
        ? math.sin(nowMs * 0.006 + i * 0.4) *
              3.24 *
              ((nowMs - start) / 200).clamp(0.0, 1.0) *
              ((end - nowMs) / 200).clamp(0.0, 1.0)
        : 0.0;

    springs.add(
      _WordSpring(
        // Paint-only transforms: uncapped they would let a word overlap its
        // neighbour instead of widening the line.
        scaleX: (1 + push + nudge * 0.3).clamp(1.0, 1.07),
        scaleY: (1 + push + nudge).clamp(1.0, 1.07),
        dy: wave,
      ),
    );
  }
  return springs;
}

/// Instrumental break: three small dots instead of a fake text line.
class _GapDots extends StatelessWidget {
  final bool active;
  final double alpha;
  final Color accent;
  final VoidCallback onTap;

  const _GapDots({
    required this.active,
    required this.alpha,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            for (var i = 0; i < 3; i++)
              Container(
                width: 5,
                height: 5,
                margin: const EdgeInsets.only(right: 5),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent.withValues(
                    alpha: active ? alpha : alpha * 0.25,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _BackToLineButton extends StatelessWidget {
  final Color accent;
  final VoidCallback onPressed;

  const _BackToLineButton({required this.accent, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: accent,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 16, 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 18,
                color: Theme.of(context).colorScheme.onPrimary,
              ),
              const SizedBox(width: 4),
              Text(
                'К текущей строке',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
