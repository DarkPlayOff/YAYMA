import 'dart:math' as math;

import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';

/// Shapes the play/pause button cycles through, one per press.
const playButtonShapes = <Shapes>[
  Shapes.circle,
  Shapes.square,
  Shapes.slanted,
  Shapes.arch,
  Shapes.oval,
  Shapes.pill,
  Shapes.diamond,
  Shapes.gem,
  Shapes.sunny,
  Shapes.c4SidedCookie,
  Shapes.l4LeafClover,
  Shapes.softBurst,
  Shapes.flower,
  Shapes.puffy,
  Shapes.bun,
  Shapes.heart,
];

/// Shape currently shared by every play/pause button.
///
/// Keeping it global makes the mini and full player change together instead
/// of drifting apart after one of them is pressed.
final FlutterSignal<int> playButtonShapeIndex = signal(0);

/// Points per silhouette. Dense enough that spike tips and round edges keep
/// their shape once the outline is drawn as a curve through them.
const int _sampleCount = 128;

/// Outline points walked per direction bin while sampling. Four is enough for
/// every M3 shape to hit each of the [_sampleCount] bins at least once.
const int _oversample = 4;

/// Silhouettes are sampled once per shape and reused by every button.
final Map<Shapes, List<Offset>> _silhouettes = {};

/// [shape]'s outline as a closed curve through [_sampleCount] points in the unit
/// square.
///
/// The M3 shapes are SVG paths, and there is no path interpolation in Flutter,
/// so each outline is sampled by direction from the centre: point `i` looks the
/// same way on every shape. The blend then grows and shrinks radially — it never
/// spins, which is what an arc-length correspondence does on symmetric shapes.
///
/// Each shape is then scaled to the circle's area, because area is what the eye
/// reads as size: a square with the circle's diameter looks half again as big.
/// Shapes that would need more room than the box gives stop at its edge.
List<Offset> _silhouette(Shapes shape) {
  return _silhouettes.putIfAbsent(shape, () {
    final raw = _rawSilhouette(shape);
    var reach = 0.0;
    for (final point in raw) {
      reach = math.max(
        reach,
        math.max((point.dx - 0.5).abs(), (point.dy - 0.5).abs()),
      );
    }
    final scale = math.min(
      math.sqrt(_circleArea / _area(raw)),
      // The M3 paths are drawn for a 100×100 box and a few overshoot it a little,
      // so this is the box edge, not a fixed constant.
      1 / 2 / reach,
    );
    return [
      for (final point in raw)
        const Offset(0.5, 0.5) + (point - const Offset(0.5, 0.5)) * scale,
    ];
  });
}

/// Area of the circle, the reference every other shape is matched to.
double? _circle;

double get _circleArea => _circle ??= _area(_rawSilhouette(Shapes.circle));

/// Area enclosed by a closed polyline.
double _area(List<Offset> points) {
  var sum = 0.0;
  for (var i = 0; i < points.length; i++) {
    final a = points[i];
    final b = points[(i + 1) % points.length];
    sum += a.dx * b.dy - b.dx * a.dy;
  }
  return sum.abs() / 2;
}

/// [shape]'s outline sampled by direction, in the unit square it was drawn in.
List<Offset> _rawSilhouette(Shapes shape) {
  const size = Size(100, 100);
  const centre = Offset(50, 50);
  final metric = M3EClipper(shape).getClip(size).computeMetrics().first;

  // Walk the outline densely and keep the farthest hit per direction bin.
  final radius = List<double>.filled(_sampleCount, 0);
  const steps = _sampleCount * _oversample;
  for (var i = 0; i < steps; i++) {
    final delta =
        metric.getTangentForOffset(metric.length * i / steps)!.position -
        centre;
    final index = (delta.direction / (2 * math.pi) * _sampleCount).round() %
        _sampleCount;
    if (delta.distance > radius[index]) radius[index] = delta.distance;
  }

  // A direction can slip between samples; borrow the neighbour's radius so no
  // point collapses to the centre.
  for (var i = 0; i < _sampleCount; i++) {
    if (radius[i] == 0) {
      radius[i] = radius[(i - 1 + _sampleCount) % _sampleCount];
    }
  }

  return [
    for (var i = 0; i < _sampleCount; i++)
      Offset(
        0.5 + radius[i] / size.width * math.cos(i * 2 * math.pi / _sampleCount),
        0.5 + radius[i] / size.width * math.sin(i * 2 * math.pi / _sampleCount),
      ),
  ];
}

/// Share of `size` the filled silhouette covers. The rest is the transparent
/// inset the material icon glyphs it replaced had, so the button reads the same
/// size it did before while keeping the full box tappable.
const double _fillScale = 0.9;

/// Play/pause button that melts into the next Material shape on every press.
class MorphingPlayPauseButton extends StatefulWidget {
  final bool isPlaying;
  final bool isBuffering;
  final double size;
  final double iconSize;
  final Color color;
  final VoidCallback onPressed;

  const MorphingPlayPauseButton({
    required this.isPlaying,
    required this.size,
    required this.color,
    required this.onPressed,
    super.key,
    this.isBuffering = false,
    this.iconSize = 24,
  });

  @override
  State<MorphingPlayPauseButton> createState() =>
      _MorphingPlayPauseButtonState();
}

class _MorphingPlayPauseButtonState extends State<MorphingPlayPauseButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _morph;
  late final EffectCleanup _shapeEffect;

  var _shapeIndex = 0;
  late List<Offset> _from;
  late List<Offset> _to;
  var _pressed = false;

  @override
  void initState() {
    super.initState();
    _shapeIndex = playButtonShapeIndex.value;
    _from = _to = _silhouette(playButtonShapes[_shapeIndex]);
    _morph = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
      value: 1,
    );
    _shapeEffect = effect(() {
      final index = playButtonShapeIndex.value;
      if (index == _shapeIndex) return;
      // Start from the outline on screen, so a press during a morph
      // continues from there instead of jumping.
      setState(() {
        _from = _currentOutline();
        _to = _silhouette(playButtonShapes[index]);
        _shapeIndex = index;
      });
      _morph.forward(from: 0);
    });
  }

  @override
  void dispose() {
    _shapeEffect();
    _morph.dispose();
    super.dispose();
  }

  double get _progress => Curves.easeOutCubic.transform(_morph.value);

  List<Offset> _currentOutline() {
    final t = _progress;
    return [
      for (var i = 0; i < _from.length; i++)
        Offset.lerp(_from[i], _to[i], t)!,
    ];
  }

  void _handlePress() {
    playButtonShapeIndex.value =
        (playButtonShapeIndex.value + 1) % playButtonShapes.length;
    widget.onPressed();
  }

  @override
  Widget build(BuildContext context) {
    final iconColor =
        ThemeData.estimateBrightnessForColor(widget.color) == Brightness.dark
        ? Colors.white
        : Colors.black;

    final glyph = widget.isBuffering
        ? M3ECircularWavyProgressIndicator(
            strokeWidth: 3,
            size: widget.size * 0.63,
            color: iconColor,
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
              widget.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              key: ValueKey<bool>(widget.isPlaying),
              size: widget.iconSize,
              color: iconColor,
            ),
          );

    return Semantics(
      button: true,
      label: widget.isPlaying ? 'Пауза' : 'Воспроизвести',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _handlePress,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          child: AnimatedScale(
            scale: _pressed ? 0.9 : 1,
            duration: const Duration(milliseconds: 120),
            child: SizedBox.square(
              dimension: widget.size,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  RepaintBoundary(
                    child: AnimatedBuilder(
                      animation: _morph,
                      builder: (context, _) => CustomPaint(
                        size: Size.square(widget.size * _fillScale),
                        painter: ShapeMorphPainter(
                          from: _from,
                          to: _to,
                          t: _progress,
                          color: widget.color,
                        ),
                      ),
                    ),
                  ),
                  glyph,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Fills the outline blended between [from] and [to] at [t].
class ShapeMorphPainter extends CustomPainter {
  final List<Offset> from;
  final List<Offset> to;
  final double t;
  final Color color;

  const ShapeMorphPainter({
    required this.from,
    required this.to,
    required this.t,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final points = [
      for (var i = 0; i < from.length; i++)
        Offset.lerp(from[i], to[i], t)! * size.width,
    ];
    // Curves through the samples, not straight chords between them: chords show
    // as facets on the round shapes and as needles on the spiky ones.
    final path = Path();
    final start = (points.last + points.first) / 2;
    path.moveTo(start.dx, start.dy);
    for (var i = 0; i < points.length; i++) {
      final point = points[i];
      final next = points[(i + 1) % points.length];
      final mid = (point + next) / 2;
      path.quadraticBezierTo(point.dx, point.dy, mid.dx, mid.dy);
    }
    canvas.drawPath(
      path..close(),
      Paint()
        ..color = color
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(ShapeMorphPainter oldDelegate) =>
      oldDelegate.t != t ||
      oldDelegate.color != color ||
      oldDelegate.from != from ||
      oldDelegate.to != to;
}
