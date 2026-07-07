import 'package:flutter/material.dart';
import 'package:yayma/src/features/core/views/widgets/track_elements.dart';
import 'package:yayma/src/rust/api/models.dart';

class CommonMediaCard extends StatefulWidget {
  final String title;
  final List<TrackArtistDto>? artists;
  final String? subtitle;
  final String? coverUrl;
  final VoidCallback onTap;
  final double size;
  final bool isCircle;

  const CommonMediaCard({
    required this.title,
    required this.onTap,
    super.key,
    this.artists,
    this.subtitle,
    this.coverUrl,
    this.size = 160,
    this.isCircle = false,
  });

  @override
  State<CommonMediaCard> createState() => _CommonMediaCardState();
}

class _CommonMediaCardState extends State<CommonMediaCard> {
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
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(
          widget.isCircle ? widget.size / 2 : 20,
        ),
        child: Container(
          width: widget.size,
          padding: const EdgeInsets.all(8),
          child: ValueListenableBuilder<bool>(
            valueListenable: _isHovered,
            builder: (context, hovered, _) {
              return Column(
                crossAxisAlignment: widget.isCircle
                    ? CrossAxisAlignment.center
                    : CrossAxisAlignment.start,
                children: [
                  AnimatedScale(
                    duration: const Duration(milliseconds: 150),
                    scale: hovered ? 1.04 : 1.0,
                    child: TrackCover(
                      url: widget.coverUrl,
                      size: widget.size - 16,
                      borderRadius: 16,
                      isCircle: widget.isCircle,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    widget.title,
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      decoration: hovered ? TextDecoration.underline : null,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: widget.isCircle
                        ? TextAlign.center
                        : TextAlign.start,
                  ),
                  if (widget.artists != null) ...[
                    const SizedBox(height: 4),
                    ArtistNamesWidget(
                      artists: widget.artists!,
                      fontSize: 13,
                      color: Colors.white38,
                    ),
                  ] else if (widget.subtitle != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      widget.subtitle!,
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 13,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: widget.isCircle
                          ? TextAlign.center
                          : TextAlign.start,
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
