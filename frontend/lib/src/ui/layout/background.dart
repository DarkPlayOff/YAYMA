import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/providers/auth_provider.dart';
import 'package:yayma/src/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/audio_fx.dart' as rust_api;
import 'package:yayma/src/ui/widgets/rust_cached_image.dart';

class BlurredCoverBackground extends StatelessWidget {
  const BlurredCoverBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Watch((context) {
        final coverUrl = currentCoverUrlSignal.watch(context);

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
                        sigmaX: 25,
                        sigmaY: 25,
                        tileMode: ui.TileMode.mirror,
                      ),
                      child: RustCachedImage(
                        imageUrl: coverUrl,
                        width: 160,
                        height: 160,
                        color: Colors.black.withValues(alpha: 0.3),
                        colorBlendMode: BlendMode.darken,
                        errorWidget:
                            Container(color: Colors.black),
                      ),
                    ),
                  ),
                )
              : Container(key: const ValueKey('none'), color: Colors.black),
        );
      }),
    );
  }
}

class WaveBackground extends StatefulWidget {
  const WaveBackground({super.key});
  @override
  State<WaveBackground> createState() => _WaveBackgroundState();
}

class _WaveBackgroundState extends State<WaveBackground> {
  ui.FragmentProgram? _shaderProgram;
  late final ValueNotifier<Float32List?> _vibeNotifier;
  late EffectCleanup _vibeEffectCleanup;
  late List<double>? _cachedThemePalette;

  @override
  void initState() {
    super.initState();
    _vibeNotifier = ValueNotifier(null);
    unawaited(_loadShader());
    _vibeEffectCleanup = effect(() {
      _vibeNotifier.value = vibeTickSignal.value;
    });
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
      unawaited(rust_api.setVibePalette(ctx: ctx, colors: _cachedThemePalette!));
    }
  }

  Future<void> _loadShader() async {
    try {
      final program = await ui.FragmentProgram.fromAsset('shaders/vibe.frag');
      if (mounted) setState(() => _shaderProgram = program);
    } on Object catch (_) {}
  }

  @override
  void dispose() {
    _vibeEffectCleanup();
    _vibeNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_shaderProgram == null) return Container(color: Colors.black);
    return RepaintBoundary(
      child: CustomPaint(
        painter: PixelPerfectVibePainter(
          shader: _shaderProgram!.fragmentShader(),
          notifier: _vibeNotifier,
        ),
      ),
    );
  }
}

class PixelPerfectVibePainter extends CustomPainter {
  final ui.FragmentShader shader;
  final ValueNotifier<Float32List?> notifier;
  static const _rotData = [-0.3, 0.3, 0.4, -0.3, -0.3, -0.4, -0.3, -0.3, 0.4];
  PixelPerfectVibePainter({required this.shader, required this.notifier})
    : super(repaint: notifier);
  @override
  void paint(Canvas canvas, Size size) {
    final u = notifier.value;
    if (u == null || u.length < 26) return;
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, u[0])
      ..setFloat(3, 0.4)
      ..setFloat(4, 0)
      ..setFloat(5, 0)
      ..setFloat(6, 0);
    for (var i = 0; i < 18; i++) {
      shader.setFloat(7 + i, u[8 + i]);
    }
    for (var i = 0; i < 9; i++) {
      shader.setFloat(25 + i, _rotData[i]);
    }
    shader
      ..setFloat(34, u[2])
      ..setFloat(35, u[3])
      ..setFloat(36, u[4])
      ..setFloat(37, u[5])
      ..setFloat(38, u[6])
      ..setFloat(39, u[7]);

    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = shader
        ..blendMode = BlendMode.screen,
    );
  }

  @override
  bool shouldRepaint(covariant PixelPerfectVibePainter oldDelegate) => false;
}
