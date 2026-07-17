import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:yayma/src/features/core/providers/navigation_provider.dart';
import 'package:yayma/src/features/core/views/widgets/fullscreen_cover.dart';
import 'package:yayma/src/features/core/views/widgets/rust_cached_image.dart';
import 'package:yayma/src/rust/api/models.dart';

class TrackVersionWidget extends StatelessWidget {
  final String? version;
  final double fontSize;
  final Color color;
  final EdgeInsets padding;

  const TrackVersionWidget({
    required this.version,
    super.key,
    this.fontSize = 14,
    this.color = Colors.white38,
    this.padding = const EdgeInsets.only(left: 8),
  });

  @override
  Widget build(BuildContext context) {
    if (version == null) return const SizedBox.shrink();
    return Padding(
      padding: padding,
      child: Text(
        version!,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: FontWeight.w400,
        ),
      ),
    );
  }
}

class ArtistNamesWidget extends StatelessWidget {
  final List<TrackArtistDto> artists;
  final double fontSize;
  final Color color;
  final Color hoverColor;
  final WrapAlignment alignment;
  final int? maxLines;

  const ArtistNamesWidget({
    required this.artists,
    super.key,
    this.fontSize = 14,
    this.color = Colors.white54,
    this.hoverColor = Colors.white,
    this.alignment = WrapAlignment.start,
    this.maxLines,
  });

  @override
  Widget build(BuildContext context) {
    if (artists.isEmpty) return const SizedBox.shrink();

    if (maxLines == 1) {
      return Text.rich(
        TextSpan(
          children: [
            for (var i = 0; i < artists.length; i++) ...[
              WidgetSpan(
                alignment: ui.PlaceholderAlignment.baseline,
                baseline: TextBaseline.alphabetic,
                child: _SingleArtistName(
                  key: ValueKey('nav_artist_${artists[i].id}_$i'),
                  artist: artists[i],
                  onTap: () => navigateTo(AppSection.artist, artists[i].id),
                  fontSize: fontSize,
                  color: color,
                  hoverColor: hoverColor,
                ),
              ),
              if (i < artists.length - 1)
                TextSpan(
                  text: ', ',
                  style: TextStyle(color: color, fontSize: fontSize),
                ),
            ],
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: alignment == WrapAlignment.center
            ? TextAlign.center
            : TextAlign.start,
      );
    }

    final children = <Widget>[];
    for (var i = 0; i < artists.length; i++) {
      final artist = artists[i];
      children.add(
        _SingleArtistName(
          key: ValueKey('nav_artist_${artist.id}_$i'),
          artist: artist,
          onTap: () => navigateTo(AppSection.artist, artist.id),
          fontSize: fontSize,
          color: color,
          hoverColor: hoverColor,
        ),
      );
      if (i < artists.length - 1) {
        children.add(
          Text(
            ', ',
            style: TextStyle(color: color, fontSize: fontSize),
          ),
        );
      }
    }

    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      alignment: alignment,
      children: children,
    );
  }
}

class _SingleArtistName extends StatefulWidget {
  final TrackArtistDto artist;
  final VoidCallback? onTap;
  final double fontSize;
  final Color color;
  final Color hoverColor;

  const _SingleArtistName({
    required this.artist,
    required this.fontSize,
    required this.color,
    required this.hoverColor,
    super.key,
    this.onTap,
  });

  @override
  State<_SingleArtistName> createState() => _SingleArtistNameState();
}

class _SingleArtistNameState extends State<_SingleArtistName> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Text(
          widget.artist.name,
          style: TextStyle(
            color: _isHovered && widget.onTap != null
                ? widget.hoverColor
                : widget.color,
            fontSize: widget.fontSize,
            decoration: _isHovered && widget.onTap != null
                ? TextDecoration.underline
                : null,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

class TrackCover extends StatelessWidget {
  final String? url;
  final double size;
  final double borderRadius;
  final bool isCircle;
  final bool canExpand;
  final String? heroTag;

  const TrackCover({
    required this.url,
    super.key,
    this.size = 64,
    this.borderRadius = 8,
    this.isCircle = false,
    this.canExpand = false,
    this.heroTag,
  });

  @override
  Widget build(BuildContext context) {
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final targetPx = (size * pixelRatio).round();
    final resolvedUrl = url != null ? resolveCoverUrl(url!, targetPx) : null;
    final image = resolvedUrl != null
        ? RustCachedImage(
            imageUrl: resolvedUrl,
            width: size,
            height: size,
            cacheWidth: targetPx,
            cacheHeight: targetPx,
            errorWidget: _CoverPlaceholder(isCircle: isCircle, size: size),
          )
        : _CoverPlaceholder(isCircle: isCircle, size: size);

    Widget content = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: isCircle ? null : BorderRadius.circular(borderRadius),
        shape: isCircle ? BoxShape.circle : BoxShape.rectangle,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(isCircle ? size / 2 : borderRadius),
        child: image,
      ),
    );

    if (heroTag != null && url != null) {
      content = Hero(
        tag: heroTag!,
        child: content,
      );
    }

    if (canExpand && url != null) {
      content = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => unawaited(
            FullscreenCoverDialog.show(
              context,
              url!,
              heroTag: heroTag ?? url!,
            ),
          ),
          child: content,
        ),
      );
    }

    return content;
  }
}

class _CoverPlaceholder extends StatelessWidget {
  final bool isCircle;
  final double size;

  const _CoverPlaceholder({required this.isCircle, required this.size});

  @override
  Widget build(BuildContext context) {
    return Icon(
      isCircle ? Icons.person : Icons.music_note,
      color: Colors.white24,
      size: size * 0.5,
    );
  }
}
