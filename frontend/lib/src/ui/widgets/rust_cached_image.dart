import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:yayma/src/rust/api/simple.dart';

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
  });

  @override
  State<RustCachedImage> createState() => _RustCachedImageState();
}

class _RustCachedImageState extends State<RustCachedImage> {
  static final Map<String, String> _pathCache = {};
  String? _resolvedPath;
  late bool _isLoading;
  bool _imageReady = false;
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

    if (_pathCache.containsKey(url)) {
      _resolvedPath = _pathCache[url];
      _isLoading = false;
      return;
    }

    _isLoading = true;
    _lastUrl = url;
    unawaited(_resolvePathAsync(url));
  }

  Future<void> _resolvePathAsync(String url) async {
    try {
      final path = await getCachedImagePath(url: url);
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
      _imageReady = false;
      _initPath();
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget content;

    if (widget.imageUrl == null || widget.imageUrl!.isEmpty) {
      content = widget.placeholder ?? _buildPlaceholder();
    } else if (_resolvedPath != null) {
      content = Stack(
        fit: StackFit.passthrough,
        children: [
          if (widget.placeholder != null)
            AnimatedOpacity(
              opacity: _imageReady ? 0.0 : 1.0,
              duration: const Duration(milliseconds: 300),
              child: widget.placeholder!,
            )
          else if (!_imageReady)
            _buildShimmer(),
          Image.file(
            File(_resolvedPath!),
            width: widget.width,
            height: widget.height,
            fit: widget.fit,
            color: widget.color,
            colorBlendMode: widget.colorBlendMode,
            frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
              if (frame != null && !_imageReady) {
                _imageReady = true;
                unawaited(
                  Future.microtask(() {
                    if (mounted) {
                      setState(() {});
                    }
                  }),
                );
              }

              if (wasSynchronouslyLoaded) {
                return child;
              }

              return TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: _imageReady ? 1.0 : 0.0),
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
                builder: (context, opacity, innerChild) {
                  return Opacity(opacity: opacity, child: innerChild);
                },
                child: child,
              );
            },
            errorBuilder: (context, error, stackTrace) =>
                widget.errorWidget ?? _buildError(),
          ),
        ],
      );
    } else if (_isLoading) {
      content = widget.placeholder ?? _buildShimmer();
    } else {
      content = widget.errorWidget ?? _buildError();
    }

    if (widget.borderRadius > 0) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        child: content,
      );
    }

    return content;
  }

  Widget _buildPlaceholder() {
    return Container(
      width: widget.width,
      height: widget.height,
      color: Colors.grey[900],
      child: const Icon(Icons.image, color: Colors.grey),
    );
  }

  Widget _buildShimmer() {
    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: Colors.grey[850],
        borderRadius: widget.borderRadius > 0
            ? BorderRadius.circular(widget.borderRadius)
            : null,
      ),
      child: _ShimmerLoader(
        width: widget.width,
        height: widget.height,
        borderRadius: widget.borderRadius,
      ),
    );
  }

  Widget _buildError() {
    return Container(
      width: widget.width,
      height: widget.height,
      color: Colors.grey[900],
      child: const Icon(Icons.broken_image, color: Colors.grey),
    );
  }
}

class _ShimmerLoader extends StatefulWidget {
  final double? width;
  final double? height;
  final double borderRadius;

  const _ShimmerLoader({
    this.width,
    this.height,
    this.borderRadius = 0,
  });

  @override
  State<_ShimmerLoader> createState() => _ShimmerLoaderState();
}

class _ShimmerLoaderState extends State<_ShimmerLoader>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    unawaited(_controller.repeat());
    _animation = Tween<double>(begin: -2, end: 2).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeInOut,
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: widget.borderRadius > 0
          ? BorderRadius.circular(widget.borderRadius)
          : BorderRadius.zero,
      child: AnimatedBuilder(
        animation: _animation,
        builder: (context, child) {
          return Container(
            width: widget.width,
            height: widget.height,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment(_animation.value, 0),
                end: Alignment(_animation.value + 0.5, 0),
                colors: const [
                  Color(0xFF2A2A2A),
                  Color(0xFF3A3A3A),
                  Color(0xFF4A4A4A),
                  Color(0xFF3A3A3A),
                  Color(0xFF2A2A2A),
                ],
                stops: const [0.0, 0.35, 0.5, 0.65, 1.0],
              ),
            ),
          );
        },
      ),
    );
  }
}
