import 'dart:async';
import 'dart:io';

import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:yayma/src/features/core/views/widgets/fullscreen_cover.dart';
import 'package:yayma/src/features/core/views/widgets/hover_scale.dart';
import 'package:yayma/src/features/core/views/widgets/rust_cached_image.dart';

/// Single shared cover placeholder. All other placeholders delegate here.
///
/// Replaces 3 duplicates:
/// - track_elements.dart `_CoverPlaceholder`
/// - home_cover_widget.dart `CoverErrorPlaceholder`
/// - player_bar.dart inline `Container(color: onSurface 0.1)`
class CoverPlaceholder extends StatelessWidget {
  final bool circle;
  final double? size;
  final IconData? icon;

  const CoverPlaceholder({
    super.key,
    this.circle = false,
    this.size,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return ColoredBox(
      color: onSurface.withValues(alpha: 0.1),
      child: Center(
        child: Icon(
          icon ?? (circle ? Icons.person : Icons.music_note),
          color: onSurface.withValues(alpha: 0.24),
          size: size != null ? size! * 0.5 : 120,
        ),
      ),
    );
  }
}

/// Single cover widget: image resolution (local file vs remote) + placeholder +
/// hover-scale animation in one place.
///
/// - [coverUrl] — primary remote URL ([url] alias kept for compatibility).
/// - [localUri] — local `file://` URI (already downloaded/cached file)
///   or a remote URI; `file://` is rendered via `Image.file` (FileImage),
///   everything else goes through [RustCachedImage] (Rust cache -> File -> Image.file).
/// - [size] — square side in logical pixels.
/// - [radius]/[borderRadius] — corner radius (`radius` takes precedence).
/// - [hoverEnabled]/[hoverScale] — built-in hover-scale via [HoverScale].
/// - [circle]/[shape]/[heroTag]/[canExpand]/[onTap]/[fit] — as before.
class AppCover extends StatelessWidget {
  final String? coverUrl;
  final String? url;
  final Uri? localUri;
  final double size;
  final bool circle;
  final String? heroTag;
  final VoidCallback? onTap;
  final double borderRadius;
  final double? radius;
  final Shapes? shape;
  final bool canExpand;
  final bool hoverEnabled;
  final double hoverScale;
  final BoxFit fit;
  final IconData? placeholderIcon;

  const AppCover({
    this.coverUrl,
    this.url,
    super.key,
    this.localUri,
    this.size = 64,
    this.circle = false,
    this.heroTag,
    this.onTap,
    this.borderRadius = 8,
    this.radius,
    this.shape,
    this.canExpand = false,
    this.hoverEnabled = false,
    this.hoverScale = 1.05,
    this.fit = BoxFit.cover,
    this.placeholderIcon,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveRadius = radius ?? borderRadius;
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final targetPx = (size * pixelRatio).round();
    final placeholder = CoverPlaceholder(
      circle: circle,
      size: size,
      icon: placeholderIcon,
    );

    // Single image resolution point: local file vs remote.
    var effectiveUrl = coverUrl ?? url;
    File? localFile;
    if (localUri != null) {
      if (localUri!.scheme == 'file') {
        try {
          localFile = File.fromUri(localUri!);
        } on Object catch (_) {
          localFile = null;
        }
      } else {
        effectiveUrl = localUri.toString();
      }
    }

    final resolvedUrl = effectiveUrl != null
        ? resolveCoverUrl(effectiveUrl, targetPx)
        : null;

    final Widget image;
    if (localFile != null) {
      image = Image.file(
        localFile,
        width: size,
        height: size,
        fit: fit,
        cacheWidth: targetPx,
        cacheHeight: targetPx,
        errorBuilder: (context, error, stackTrace) => placeholder,
      );
    } else if (resolvedUrl != null) {
      image = RustCachedImage(
        imageUrl: resolvedUrl,
        width: size,
        height: size,
        fit: fit,
        cacheWidth: targetPx,
        cacheHeight: targetPx,
        errorWidget: placeholder,
      );
    } else {
      image = placeholder;
    }

    final Widget content;
    final placeholderColor = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.1);
    if (shape != null && !circle) {
      content = M3EContainer(
        shape!,
        width: size,
        height: size,
        color: placeholderColor,
        child: image,
      );
    } else {
      content = Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: placeholderColor,
          borderRadius: circle ? null : BorderRadius.circular(effectiveRadius),
          shape: circle ? BoxShape.circle : BoxShape.rectangle,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(
            circle ? size / 2 : effectiveRadius,
          ),
          child: image,
        ),
      );
    }

    var cover = content;

    if (heroTag != null && (effectiveUrl != null || localFile != null)) {
      cover = Hero(tag: heroTag!, child: cover);
    }

    final effectiveOnTap = onTap ?? _expandTap(context, effectiveUrl);

    if (hoverEnabled) {
      return HoverScale(
        hoverScale: hoverScale,
        cursor: effectiveOnTap != null
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onTap: effectiveOnTap,
        child: cover,
      );
    }

    if (effectiveOnTap != null) {
      cover = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(onTap: effectiveOnTap, child: cover),
      );
    }

    return cover;
  }

  /// Tap handler to expand fullscreen. Extracted into a method so the nullable
  /// [effectiveUrl] is correctly promoted to `String` inside the closure.
  VoidCallback? _expandTap(BuildContext context, String? effectiveUrl) {
    if (!canExpand) return null;
    final u = effectiveUrl;
    if (u == null) return null;
    return () => unawaited(
      FullscreenCoverDialog.show(context, u, heroTag: heroTag ?? u),
    );
  }
}
