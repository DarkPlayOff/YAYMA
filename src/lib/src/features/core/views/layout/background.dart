import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/app/session.dart';
import 'package:yayma/src/features/core/providers/visual_effects_provider.dart';
import 'package:yayma/src/features/core/utils/lru_map.dart';
import 'package:yayma/src/features/core/views/widgets/rust_cached_image.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/audio_fx.dart' as rust_api;
import 'package:yayma/src/rust/api/simple.dart';
import 'package:yayma/src/rust/lib.dart';

/// Wraps a blurred backdrop raster so its disposal is idempotent: the LRU
/// evictor and the fade-out timer can both decide the image is dead, but
/// only the first call actually disposes it.
final class _BlurredEntry {
  _BlurredEntry(this.image);
  final ui.Image image;
  bool disposed = false;

  void dispose() {
    if (disposed) return;
    disposed = true;
    image.dispose();
  }
}

/// Full-screen backdrop behind the UI: the current cover, downscaled,
/// blurred and dimmed **once per track**, cached as a tiny [ui.Image] and
/// drawn as a single bilinear upscale.
///
/// Why not `ImageFiltered` inside a full-screen `FittedBox` anymore: the
/// filter's `saveLayer` is rasterized at screen size (the FittedBox scale
/// is part of the layer's matrix), so each re-rasterization was a
/// screen-sized Gaussian blur with the sigma amplified by the same scale —
/// paid on the first frames of every AnimatedSwitcher transition whenever
/// the raster cache missed (common on Impeller/mobile).
class BlurredCoverBackground extends StatefulWidget {
  const BlurredCoverBackground({super.key});

  @override
  State<BlurredCoverBackground> createState() => _BlurredCoverBackgroundState();
}

class _BlurredCoverBackgroundState extends State<BlurredCoverBackground> {
  /// Cover URL -> cached file path, mirroring `_RustCachedImageState`'s
  /// private path cache.
  static final LruMap<String, String> _pathCache = LruMap(maximumSize: 64);

  /// Resolved cover URL -> blurred raster.
  late final LruMap<String, _BlurredEntry> _blurCache = LruMap(
    maximumSize: 24,
    // Eviction can happen while the entry is still the outgoing child of
    // the AnimatedSwitcher below (its fade-out lasts 1s), so disposal is
    // deferred past the transition instead of racing the raster thread.
    onEvict: (_, entry) => _scheduleDispose(entry),
  );

  static const _sourcePx = 48;
  static const _blurSigma = 5.0;
  static const _dimAlpha = 0.3;
  static const _crossfadeMs = 1000;

  _BlurredEntry? _currentEntry;
  ui.Image? _displayedImage;
  String? _pendingUrl;
  String? _loadedUrl;
  int _seq = 0;

  @override
  void dispose() {
    for (final entry in _blurCache.values) {
      entry.dispose();
    }
    _blurCache.clear();
    _currentEntry = null;
    _displayedImage = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SignalBuilder(
        builder: (context) {
          final coverUrl = currentCoverUrlSignal.value;

          if (coverUrl == null || coverUrl.isEmpty) {
            return Container(key: const ValueKey('none'), color: Colors.black);
          }
          _ensureLoaded(coverUrl);

          final entry = _loadedUrl == coverUrl ? _currentEntry : null;
          return AnimatedSwitcher(
            duration: const Duration(milliseconds: _crossfadeMs),
            child: entry != null
                ? SizedBox.expand(
                    key: ValueKey(coverUrl),
                    child: CustomPaint(painter: _BlurredCoverPainter(entry)),
                  )
                : Container(
                    key: const ValueKey('loading'),
                    color: Colors.black,
                  ),
          );
        },
      ),
    );
  }

  void _ensureLoaded(String rawUrl) {
    if (_loadedUrl == rawUrl || _pendingUrl == rawUrl) return;
    _pendingUrl = rawUrl;
    final seq = ++_seq;
    unawaited(_loadAsync(rawUrl, seq));
  }

  Future<void> _loadAsync(String rawUrl, int seq) async {
    try {
      final resolved = resolveCoverUrl(rawUrl, _sourcePx);
      final cached = _blurCache.peek(resolved);
      if (cached != null && !cached.disposed) {
        // The hit path reaches `_show` without an intermediate `await`, so it
        // would run synchronously inside the build phase and trip the
        // framework's `setState() called during build` assertion — defer it
        // to a later event-loop turn.
        if (seq == _seq && mounted) {
          await Future<void>.delayed(Duration.zero);
          if (seq == _seq && mounted) _show(cached, rawUrl);
        }
        return;
      }

      var path = _pathCache[resolved];
      if (path == null) {
        final ctx = appContextSignal.value;
        path = ctx == null
            ? null
            : await getCachedImagePath(ctx: ctx, url: resolved);
        if (path != null) _pathCache[resolved] = path;
      }
      if (path == null) return; // keep the black placeholder

      final bytes = await File(path).readAsBytes();
      final image = await _rasterizeBlurred(bytes);
      if (seq != _seq || !mounted) {
        image.dispose();
        return;
      }
      final entry = _BlurredEntry(image);
      final existing = _blurCache.peek(resolved);
      if (existing != null && !existing.disposed) {
        // A concurrent load for the same resolved cover won the race; drop
        // the duplicate raster and display the cached one.
        entry.dispose();
        _show(existing, rawUrl);
      } else {
        // `[]=` replacement does not fire onEvict, which is exactly what a
        // disposed tombstone needs — its raster is already gone.
        _blurCache[resolved] = entry;
        _show(entry, rawUrl);
      }
    } on Object catch (e) {
      debugPrint('blurred cover background failed for $rawUrl: $e');
    } finally {
      if (seq == _seq) _pendingUrl = null;
    }
  }

  void _show(_BlurredEntry entry, String rawUrl) {
    setState(() {
      _currentEntry = entry;
      _displayedImage = entry.image;
      _loadedUrl = rawUrl;
    });
    // Disposal of [old] is owned by the LRU's onEvict: if it is still cached
    // it stays valid for future tracks, if it was evicted the evictor's own
    // deferred dispose already ran past the fade-out window.
  }

  /// Disposes [entry] after the crossfade window, unless it is still the
  /// displayed image (that entry's later eviction/replacement owns it; the
  /// worst case is a bounded few-KB leak).
  void _scheduleDispose(_BlurredEntry entry) {
    unawaited(
      Future<void>.delayed(
        const Duration(milliseconds: _crossfadeMs + 500),
        () {
          if (entry.disposed) return;
          if (identical(entry.image, _displayedImage)) return;
          entry.dispose();
        },
      ),
    );
  }

  /// Downscale-decodes [bytes] to ~[_sourcePx], then blurs (sigma
  /// [_blurSigma], mirrored edges) and dims it in one small offscreen pass —
  /// both passes run once per track change and cost well under a frame.
  static Future<ui.Image> _rasterizeBlurred(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    final src = frame.image;
    try {
      return _blurSmall(src);
    } finally {
      src.dispose();
    }
  }

  static ui.Image _blurSmall(ui.Image src) {
    final srcW = src.width.toDouble();
    final srcH = src.height.toDouble();
    final scale = _sourcePx / math.max(srcW, srcH);
    final w = math.max(1, (srcW * scale).round());
    final h = math.max(1, (srcH * scale).round());
    final dst = Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());

    // Pass 1: downscale to the small raster (aspect-preserving; the painter
    // cover-crops at display time).
    final downRecorder = ui.PictureRecorder();
    ui.Canvas(downRecorder).drawImageRect(
      src,
      Rect.fromLTWH(0, 0, srcW, srcH),
      dst,
      Paint()..filterQuality = FilterQuality.medium,
    );
    final downPicture = downRecorder.endRecording();
    final small = downPicture.toImageSync(w, h);
    downPicture.dispose();

    // Pass 2: blur + dim. The color filter sits inside the blurred layer, so
    // the result matches the old `ImageFiltered(blur) > Image(darken)` look,
    // including the mirrored edge sampling.
    final blurRecorder = ui.PictureRecorder();
    ui.Canvas(blurRecorder)
      ..saveLayer(
        dst,
        Paint()
          ..imageFilter = ui.ImageFilter.blur(
            sigmaX: _blurSigma,
            sigmaY: _blurSigma,
            tileMode: ui.TileMode.mirror,
          ),
      )
      ..drawImage(
        small,
        Offset.zero,
        Paint()
          ..colorFilter = ColorFilter.mode(
            Colors.black.withValues(alpha: _dimAlpha),
            BlendMode.darken,
          ),
      )
      ..restore();
    final blurPicture = blurRecorder.endRecording();
    final blurred = blurPicture.toImageSync(w, h);
    blurPicture.dispose();
    small.dispose();
    return blurred;
  }
}

/// Draws the cached blurred raster stretched to cover the widget, cropping
/// like [BoxFit.cover]. A single bilinear `drawImageRect` — no saveLayer,
/// no live blur filter in the frame.
class _BlurredCoverPainter extends CustomPainter {
  _BlurredCoverPainter(this.entry);

  final _BlurredEntry entry;

  final Paint _paint = Paint()..filterQuality = FilterQuality.medium;

  @override
  void paint(Canvas canvas, Size size) {
    final image = entry.image;
    final src = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    final fitted = applyBoxFit(BoxFit.cover, src.size, size);
    final dst = Alignment.center.inscribe(
      fitted.destination,
      Offset.zero & size,
    );
    canvas
      ..clipRect(Offset.zero & size)
      ..drawImageRect(image, src, dst, _paint);
  }

  @override
  bool shouldRepaint(_BlurredCoverPainter oldDelegate) =>
      !identical(oldDelegate.entry, entry);
}

class WaveBackground extends StatefulWidget {
  const WaveBackground({super.key});
  @override
  State<WaveBackground> createState() => _WaveBackgroundState();
}

class _WaveBackgroundState extends State<WaveBackground> {
  ui.FragmentShader? _shader;
  late List<double>? _cachedThemePalette;
  double _devicePixelRatio = 1;

  @override
  void initState() {
    super.initState();
    unawaited(_loadShader());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _devicePixelRatio = MediaQuery.of(context).devicePixelRatio;
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
    return SignalBuilder(
      builder: (context) {
        if (!vibeVisibleSignal.value) return const SizedBox.shrink();
        final renderScale = vibeRenderScaleSignal.value;
        return RepaintBoundary(
          child: CustomPaint(
            painter: PixelPerfectVibePainter(
              shader: shader,
              signal: vibeTickSignal,
              devicePixelRatio: _devicePixelRatio,
              renderScale: renderScale,
            ),
          ),
        );
      },
    );
  }
}

class PixelPerfectVibePainter extends CustomPainter {
  final ui.FragmentShader shader;
  final FlutterSignal<F32Array26> signal;
  final double devicePixelRatio;
  final double renderScale;
  static const _rotData = [-0.3, 0.3, 0.4, -0.3, -0.3, -0.4, -0.3, -0.3, 0.4];
  static const _viewScale = 0.4;

  // Fraction of *physical* pixels to shade before upscaling. Applied against
  // size * devicePixelRatio (not raw logical size) so screens with a high
  // DPR (phones) get the same effective sharpness as ~1x desktop displays
  // instead of a much blurrier result for the same nominal scale.
  PixelPerfectVibePainter({
    required this.shader,
    required this.signal,
    required this.devicePixelRatio,
    required this.renderScale,
  }) : super(repaint: signal);

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

    final physicalScale = devicePixelRatio * renderScale;
    final lowWidth = math.max(1, (size.width * physicalScale).round());
    final lowHeight = math.max(1, (size.height * physicalScale).round());
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
      final boost = math.max(react, audio * 0.6) * 35.0;

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

      // Conservative bound: transformed spark <= 1.2 * SPARK_GAIN (0.48),
      // blob noise wobble <= 0.35.
      // Must stay in sync with the outer-radius formula in vibe.frag,
      // including its direct AUDIO_PUMP_GAIN term.
      const sparkMax = 1.2 * 0.4; // polynomial maximum * SPARK_GAIN
      final brMax = sparkMax * (1.0 - 0.3 * i);
      final outer =
          1.9 - 0.25 * i + brMax * (1.0 + boost * brMax) + boost * 0.008;
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
  bool shouldRepaint(covariant PixelPerfectVibePainter oldDelegate) =>
      oldDelegate.renderScale != renderScale ||
      oldDelegate.devicePixelRatio != devicePixelRatio;
}
