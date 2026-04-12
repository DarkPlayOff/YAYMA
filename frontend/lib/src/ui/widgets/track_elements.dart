import 'package:flutter/material.dart';
import 'package:yayma/src/providers/navigation_provider.dart';
import 'package:yayma/src/rust/api/models.dart';
import 'package:yayma/src/ui/widgets/rust_cached_image.dart';

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

  const ArtistNamesWidget({
    required this.artists,
    super.key,
    this.fontSize = 14,
    this.color = Colors.white54,
    this.hoverColor = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    if (artists.isEmpty) return const SizedBox.shrink();

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
  final ValueNotifier<bool> _isHovered = ValueNotifier(false);

  @override
  void dispose() {
    _isHovered.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => _isHovered.value = true,
      onExit: (_) => _isHovered.value = false,
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: ValueListenableBuilder<bool>(
        valueListenable: _isHovered,
        builder: (context, hovered, _) {
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: Text(
              widget.artist.name,
              style: TextStyle(
                color: hovered && widget.onTap != null
                    ? widget.hoverColor
                    : widget.color,
                fontSize: widget.fontSize,
                decoration: hovered && widget.onTap != null
                    ? TextDecoration.underline
                    : null,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          );
        },
      ),
    );
  }
}

class TrackCover extends StatelessWidget {
  final String? url;
  final double size;
  final double borderRadius;
  final bool isCircle;

  const TrackCover({
    required this.url,
    super.key,
    this.size = 64,
    this.borderRadius = 8,
    this.isCircle = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: isCircle ? null : BorderRadius.circular(borderRadius),
        shape: isCircle ? BoxShape.circle : BoxShape.rectangle,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(isCircle ? size / 2 : borderRadius),
        child: url != null
            ? RustCachedImage(
                imageUrl: url,
                width: size,
                height: size,
                errorWidget: _buildPlaceholder(),
              )
            : _buildPlaceholder(),
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Icon(
      isCircle ? Icons.person : Icons.music_note,
      color: Colors.white24,
      size: size * 0.5,
    );
  }
}
