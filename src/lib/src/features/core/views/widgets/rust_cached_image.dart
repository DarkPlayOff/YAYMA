import 'dart:async';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';
import 'package:yayma/src/app/session.dart';
import 'package:yayma/src/features/core/utils/lru_map.dart';
import 'package:yayma/src/rust/api/simple.dart';

const List<int> coverSizePicks = [
  30,
  50,
  80,
  100,
  200,
  300,
  400,
  600,
  800,
  1000,
];

/// Rewrites a Yandex cover URL to the smallest preset that is still large
/// enough to cover [targetPx] device pixels, so covers are never upscaled
/// from a too-small source (blurry) nor pulled at a needlessly large size
/// for a small widget (wasted bandwidth/cache).
String resolveCoverUrl(String url, int targetPx) {
  final preset = coverSizePicks.firstWhere(
    (p) => p >= targetPx,
    orElse: () => coverSizePicks.last,
  );
  var result = url;
  for (final p in coverSizePicks) {
    result = result.replaceFirst('${p}x$p', '${preset}x$preset');
  }
  return result;
}

class RustCachedImage extends StatefulWidget {
  final String? imageUrl;
  final double? width;
  final double? height;
  final BoxFit fit;
  final double borderRadius;
  final Widget? placeholder;
  final Widget? errorWidget;
  final Color? color;
  final BlendMode? colorBlendMode;
  final int? cacheWidth;
  final int? cacheHeight;

  const RustCachedImage({
    required this.imageUrl,
    super.key,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius = 0,
    this.placeholder,
    this.errorWidget,
    this.color,
    this.colorBlendMode,
    this.cacheWidth,
    this.cacheHeight,
  });

  @override
  State<RustCachedImage> createState() => _RustCachedImageState();
}

class _RustCachedImageState extends State<RustCachedImage> {
  static final LruMap<String, String> _pathCache = LruMap(maximumSize: 400);
  String? _resolvedPath;
  late bool _isLoading;
  String? _lastUrl;

  @override
  void initState() {
    super.initState();
    _initPath();
  }

  void _initPath() {
    final url = widget.imageUrl;
    if (url == null || url.isEmpty) {
      _resolvedPath = null;
      _isLoading = false;
      return;
    }

    final cached = _pathCache[url];
    if (cached != null) {
      _resolvedPath = cached;
      _isLoading = false;
      return;
    }

    // Drop the previous artwork right away: keeping it while the new path is
    // resolved shows an unrelated (older) cover for as long as the lookup or
    // download takes.
    _resolvedPath = null;
    _isLoading = true;
    _lastUrl = url;
    unawaited(_resolvePathAsync(url));
  }

  Future<void> _resolvePathAsync(String url) async {
    try {
      final ctx = appContextSignal.value;
      if (ctx == null) {
        if (mounted && _lastUrl == url) {
          setState(() {
            _resolvedPath = null;
            _isLoading = false;
          });
        }
        return;
      }

      final path = await getCachedImagePath(ctx: ctx, url: url);
      if (mounted && _lastUrl == url) {
        if (path != null) {
          _pathCache[url] = path;
        }
        setState(() {
          _resolvedPath = path;
          _isLoading = false;
        });
      }
    } on Object catch (_) {
      if (mounted && _lastUrl == url) {
        setState(() {
          _resolvedPath = null;
          _isLoading = false;
        });
      }
    }
  }

  @override
  void didUpdateWidget(RustCachedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _initPath();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Decode at the size the widget actually occupies on screen: without
    // this every avatar and thumbnail is decoded at the source resolution,
    // which is many times larger than needed on high-DPI phones.
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cacheWidth =
        widget.cacheWidth ??
        (widget.width?.isFinite ?? false
            ? (widget.width! * dpr).round()
            : null);
    final cacheHeight =
        widget.cacheHeight ??
        (widget.height?.isFinite ?? false
            ? (widget.height! * dpr).round()
            : null);
    Widget content;

    if (widget.imageUrl == null || widget.imageUrl!.isEmpty) {
      content =
          widget.placeholder ??
          _ImagePlaceholder(width: widget.width, height: widget.height);
    } else if (_resolvedPath != null) {
      content = Image.file(
        File(_resolvedPath!),
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        color: widget.color,
        colorBlendMode: widget.colorBlendMode,
        cacheWidth: cacheWidth,
        cacheHeight: cacheHeight,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (wasSynchronouslyLoaded || frame != null) {
            return child;
          }

          // No cross-fade: while loading, the placeholder sits behind the
          // image and is dropped once the first frame arrives. Keeping two
          // AnimatedOpacity layers per image cost a saveLayer each, which is
          // the most expensive thing on screen for large covers.
          return Stack(
            fit: StackFit.passthrough,
            children: [
              if (widget.placeholder != null)
                widget.placeholder!
              else
                _ImageShimmer(
                  width: widget.width,
                  height: widget.height,
                  borderRadius: widget.borderRadius,
                ),
              child,
            ],
          );
        },
        errorBuilder: (context, error, stackTrace) =>
            widget.errorWidget ??
            _ImageError(width: widget.width, height: widget.height),
      );
    } else if (_isLoading) {
      content =
          widget.placeholder ??
          _ImageShimmer(
            width: widget.width,
            height: widget.height,
            borderRadius: widget.borderRadius,
          );
    } else {
      content =
          widget.errorWidget ??
          _ImageError(width: widget.width, height: widget.height);
    }

    if (widget.borderRadius > 0) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        child: content,
      );
    }

    return content;
  }
}

class _ImagePlaceholder extends StatelessWidget {
  final double? width;
  final double? height;

  const _ImagePlaceholder({this.width, this.height});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      color: Colors.grey[900],
      child: const Icon(Icons.image, color: Colors.grey),
    );
  }
}

class _ImageShimmer extends StatelessWidget {
  final double? width;
  final double? height;
  final double borderRadius;

  const _ImageShimmer({this.width, this.height, this.borderRadius = 0});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.grey[850],
        borderRadius: borderRadius > 0
            ? BorderRadius.circular(borderRadius)
            : null,
      ),
      child: _ShimmerLoader(
        width: width,
        height: height,
        borderRadius: borderRadius,
      ),
    );
  }
}

class _ImageError extends StatelessWidget {
  final double? width;
  final double? height;

  const _ImageError({this.width, this.height});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      color: Colors.grey[900],
      child: const Icon(Icons.broken_image, color: Colors.grey),
    );
  }
}

class _ShimmerLoader extends StatefulWidget {
  final double? width;
  final double? height;
  final double borderRadius;

  const _ShimmerLoader({this.width, this.height, this.borderRadius = 0});

  @override
  State<_ShimmerLoader> createState() => _ShimmerLoaderState();
}

class _ShimmerLoaderState extends State<_ShimmerLoader> {
  // One ticker for every loading cover in the app: a grid of placeholders
  // would otherwise keep one repeating controller per tile alive. It runs
  // only while at least one placeholder is visible (`TickerMode`), so a
  // hidden tab full of loading covers costs no frames.
  static AnimationController? _shared;
  static int _mounted = 0;
  static int _visible = 0;
  static bool _ticking = false;

  bool _isVisible = false;

  @override
  void initState() {
    super.initState();
    _mounted++;
    _shared ??= AnimationController(
      vsync: const _ShimmerVsync(),
      duration: const Duration(milliseconds: 1500),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible != _isVisible) {
      _isVisible = visible;
      visible ? _visible++ : _visible--;
      _syncTicker();
    }
  }

  @override
  void dispose() {
    if (_isVisible) _visible--;
    _mounted--;
    if (_mounted == 0) {
      _shared?.dispose();
      _shared = null;
      _ticking = false;
    } else {
      _syncTicker();
    }
    super.dispose();
  }

  static void _syncTicker() {
    final shouldTick = _visible > 0;
    if (shouldTick == _ticking) return;
    _ticking = shouldTick;
    if (shouldTick) {
      _shared!.repeat();
    } else {
      _shared!.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: widget.borderRadius > 0
          ? BorderRadius.circular(widget.borderRadius)
          : BorderRadius.zero,
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _ShimmerPainter(animation: _shared!),
          child: Container(
            width: widget.width,
            height: widget.height,
            decoration: const BoxDecoration(),
          ),
        ),
      ),
    );
  }
}

class _ShimmerVsync implements TickerProvider {
  const _ShimmerVsync();

  @override
  Ticker createTicker(TickerCallback onTick) => Ticker(onTick);
}

class _ShimmerPainter extends CustomPainter {
  _ShimmerPainter({required this.animation}) : super(repaint: animation);
  final Animation<double> animation;
  final Paint _paint = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    // The shared controller is linear and spans 0..1; the old per-tile one
    // ran an eased tween from -2 to 2. Same sweep, one less animation object.
    final position =
        -2 + 4 * Curves.easeInOut.transform(animation.value.clamp(0.0, 1.0));
    _paint.shader = LinearGradient(
      begin: Alignment(position, 0),
      end: Alignment(position + 0.5, 0),
      colors: const [
        Color(0xFF2A2A2A),
        Color(0xFF3A3A3A),
        Color(0xFF4A4A4A),
        Color(0xFF3A3A3A),
        Color(0xFF2A2A2A),
      ],
      stops: const [0.0, 0.35, 0.5, 0.65, 1.0],
    ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, _paint);
  }

  @override
  bool shouldRepaint(_ShimmerPainter oldDelegate) => false;
}
