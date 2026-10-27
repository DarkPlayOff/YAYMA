import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:yayma/src/features/core/providers/navigation_provider.dart';
import 'package:yayma/src/rust/api/models.dart';

/// Title with the track version appended after a space, so both share one line
/// and one ellipsis. The version keeps the muted colour, which still marks it
/// as secondary without needing a slot of its own.
TextSpan trackTitleSpan(
  BuildContext context, {
  required String title,
  required TextStyle style,
  String? version,
  double? versionFontSize,
}) {
  return TextSpan(
    text: title,
    style: style,
    children: [
      if (version != null && version.isNotEmpty)
        TextSpan(
          text: ' $version',
          style: TextStyle(
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.38),
            fontSize: versionFontSize,
            fontWeight: FontWeight.w400,
          ),
        ),
    ],
  );
}

class ArtistNamesWidget extends StatelessWidget {
  final List<TrackArtistDto> artists;
  final double fontSize;
  final Color? color;
  final Color? hoverColor;
  final WrapAlignment alignment;
  final int? maxLines;

  /// Overrides the default navigation, e.g. to close a sheet first.
  final void Function(String artistId)? onArtistTap;

  const ArtistNamesWidget({
    required this.artists,
    super.key,
    this.fontSize = 14,
    this.color,
    this.hoverColor,
    this.alignment = WrapAlignment.start,
    this.maxLines,
    this.onArtistTap,
  });

  void _openArtist(String artistId) => onArtistTap != null
      ? onArtistTap!(artistId)
      : navigateTo(AppSection.artist, artistId);

  @override
  Widget build(BuildContext context) {
    if (artists.isEmpty) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final resolvedColor = color ?? scheme.onSurface.withValues(alpha: 0.55);
    final resolvedHoverColor = hoverColor ?? scheme.onSurface;

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
                  onTap: () => _openArtist(artists[i].id),
                  fontSize: fontSize,
                  color: resolvedColor,
                  hoverColor: resolvedHoverColor,
                ),
              ),
              if (i < artists.length - 1)
                TextSpan(
                  text: ', ',
                  style: TextStyle(color: resolvedColor, fontSize: fontSize),
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
          onTap: () => _openArtist(artist.id),
          fontSize: fontSize,
          color: resolvedColor,
          hoverColor: resolvedHoverColor,
        ),
      );
      if (i < artists.length - 1) {
        children.add(
          Text(
            ', ',
            style: TextStyle(color: resolvedColor, fontSize: fontSize),
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

class TrackPlayingIndicator extends StatefulWidget {
  final bool isPlaying;
  final double height;
  final Color? color;

  const TrackPlayingIndicator({
    required this.isPlaying,
    super.key,
    this.height = 16,
    this.color,
  });

  @override
  State<TrackPlayingIndicator> createState() => _TrackPlayingIndicatorState();
}

class _TrackPlayingIndicatorState extends State<TrackPlayingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    if (widget.isPlaying) _controller.repeat();
  }

  @override
  void didUpdateWidget(TrackPlayingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.isPlaying && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    if (!widget.isPlaying) {
      // Paused: static bars at minimum height, fixed size.
      return SizedBox(
        height: widget.height,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: List.generate(
            3,
            (i) => Container(
              width: 3,
              height: i == 1 ? widget.height * 0.5 : widget.height * 0.3,
              margin: EdgeInsets.only(left: i == 0 ? 0 : 2),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      );
    }
    return SizedBox(
      height: widget.height,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(3, (i) {
              // Smooth calm wave: small amplitude, sine curve,
              // slight phase offset between bars.
              final phase = _controller.value * 2 * math.pi + i * 1.4;
              final scale = 0.55 + 0.2 * math.sin(phase);
              return Container(
                width: 3,
                height: widget.height * scale.clamp(0.35, 0.75),
                margin: EdgeInsets.only(left: i == 0 ? 0 : 2),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}
