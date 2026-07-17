import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/auth/providers/auth_provider.dart';
import 'package:yayma/src/features/core/views/widgets/rust_cached_image.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/audio_fx.dart' as rust_api;
import 'package:yayma/src/rust/lib.dart';

class BlurredCoverBackground extends SignalWidget {
  const BlurredCoverBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SignalBuilder(
        builder: (context) {
          final coverUrl = currentCoverUrlSignal.value;

          return AnimatedSwitcher(
            duration: const Duration(seconds: 1),
            child: coverUrl != null
                ? SizedBox.expand(
                    key: ValueKey(coverUrl),
                    child: FittedBox(
                      fit: BoxFit.cover,
                      clipBehavior: Clip.hardEdge,
                      child: ImageFiltered(
                        imageFilter: ui.ImageFilter.blur(
                          sigmaX: 5,
                          sigmaY: 5,
                          tileMode: ui.TileMode.mirror,
                        ),
                        child: RustCachedImage(
                          imageUrl: coverUrl,
                          width: 60,
                          height: 60,
                          cacheWidth: 60,
                          cacheHeight: 60,
                          color: Colors.black.withValues(alpha: 0.3),
                          colorBlendMode: BlendMode.darken,
                          errorWidget: Container(color: Colors.black),
                        ),
                      ),
                    ),
                  )
                : Container(key: const ValueKey('none'), color: Colors.black),
          );
        },
      ),
    );
  }
}

class WaveBackground extends StatefulWidget {
  const WaveBackground({super.key});
  @override
  State<WaveBackground> createState() => _WaveBackgroundState();
}

class _WaveBackgroundState extends State<WaveBackground> {
  ui.FragmentShader? _shader;
  late List<double>? _cachedThemePalette;

  @override
  void initState() {
    super.initState();
    unawaited(_loadShader());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scheme = Theme.of(context).colorScheme;
    List<double> c(ui.Color col) => [
      (col.r * 255.0).round().clamp(0, 255) / 255.0,
      (col.g * 255.0).round().clamp(0, 255) / 255.0,
      (col.b * 255.0).round().clamp(0, 255) / 255.0,
    ];
    _cachedThemePalette = [
      ...c(scheme.primary),
      ...c(scheme.secondary),
      ...c(scheme.tertiary),
      ...c(scheme.primaryContainer),
      ...c(scheme.secondaryContainer),
      ...c(scheme.tertiaryContainer),
    ];
    final ctx = appContextSignal.value;
    if (trackMetadataSignal().id == null && ctx != null) {
      unawaited(
        rust_api.setVibePalette(ctx: ctx, colors: _cachedThemePalette!),
      );
    }
  }

  Future<void> _loadShader() async {
    try {
      final program = await ui.FragmentProgram.fromAsset('shaders/vibe.frag');
      if (mounted) setState(() => _shader = program.fragmentShader());
    } on Object catch (e) {
      debugPrint('vibe shader load failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final shader = _shader;
    if (shader == null) return Container(color: Colors.black);
    return RepaintBoundary(
      child: CustomPaint(
        painter: PixelPerfectVibePainter(
          shader: shader,
          signal: vibeTickSignal,
        ),
      ),
    );
  }
}

class PixelPerfectVibePainter extends CustomPainter {
  final ui.FragmentShader shader;
  final FlutterSignal<F32Array26> signal;
  static const _rotData = [-0.3, 0.3, 0.4, -0.3, -0.3, -0.4, -0.3, -0.3, 0.4];
  static const _viewScale = 0.4;

  // The shader is soft/blurry by construction (noise blobs, no sharp edges),
  // so shading it at half resolution and upscaling with bilinear filtering
  // is visually indistinguishable while cutting fragment invocations ~4x.
  static const _renderScale = 0.5;

  PixelPerfectVibePainter({required this.shader, required this.signal})
    : super(repaint: signal);

  final Paint _shaderPaint = Paint();
  final Paint _upscalePaint = Paint()
    ..filterQuality = FilterQuality.medium
    ..blendMode = BlendMode.screen;

  // Uniform indices must match the declaration order in shaders/vibe.frag.
  // All per-frame constants (rotations, sin phases, reaction coefficients)
  // are computed here once per tick instead of per fragment.
  @override
  void paint(Canvas canvas, Size size) {
    final u = signal.value;
    if (u.length < 26) return;
    final t = u[0];

    final lowWidth = math.max(1, (size.width * _renderScale).round());
    final lowHeight = math.max(1, (size.height * _renderScale).round());
    final lowW = lowWidth.toDouble();
    final lowH = lowHeight.toDouble();

    final f = 1.0 / (math.min(lowW, lowH) * _viewScale);
    shader
      ..setFloat(0, lowW * f)
      ..setFloat(1, lowH * f)
      ..setFloat(2, 2.0 * f)
      ..setFloat(3, t * 0.5)
      ..setFloat(4, t * 0.01);
    for (var i = 0; i < 18; i++) {
      shader.setFloat(6 + i, u[8 + i]);
    }

    var maxOuter = 0.0;
    for (var i = 0; i < 3; i++) {
      final audio = u[2 + i];
      final react = u[5 + i];
      final phase = 1.57 * i;
      final angle = t * _rotData[i * 3 + 2];
      final ca = math.cos(angle);
      final sa = math.sin(angle);
      final rx = _rotData[i * 3];
      final ry = _rotData[i * 3 + 1];
      final boost = math.max(react, audio * 0.6) * 50.0;

      final a = 24 + i * 4;
      shader
        ..setFloat(a, rx * ca - ry * sa)
        ..setFloat(a + 1, rx * sa + ry * ca)
        ..setFloat(a + 2, t * 0.5 + phase)
        ..setFloat(a + 3, 1.0 - react * 0.5);

      final b = 36 + i * 4;
      shader
        ..setFloat(b, 1.1 + math.sin(t + phase))
        ..setFloat(
          b + 1,
          0.15 -
              0.1125 * math.sin(t * 2.0 + phase * 0.5) +
              0.3 * math.max(react, audio),
        )
        ..setFloat(b + 2, boost)
        ..setFloat(b + 3, 0.6 * react);

      // Conservative bound: spark <= 1.2, blob noise wobble <= 0.35.
      final brMax = 1.2 * (1.0 - 0.3 * i);
      final outer = 1.9 - 0.25 * i + brMax * (1.0 + boost * brMax);
      if (outer > maxOuter) maxOuter = outer;
    }
    shader.setFloat(5, maxOuter);

    _shaderPaint.shader = shader;
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(Rect.fromLTWH(0, 0, lowW, lowH), _shaderPaint);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(lowWidth, lowHeight);
    picture.dispose();

    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, lowW, lowH),
      Offset.zero & size,
      _upscalePaint,
    );
    image.dispose();
  }

  @override
  bool shouldRepaint(covariant PixelPerfectVibePainter oldDelegate) => false;
}
