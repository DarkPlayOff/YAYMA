import 'package:flutter/material.dart';
import 'package:yayma/src/rust/api/models.dart';
import 'package:yayma/src/ui/widgets/track_elements.dart';

class CommonMediaCard extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(isCircle ? size / 2 : 20),
      child: Container(
        width: size,
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: isCircle
              ? CrossAxisAlignment.center
              : CrossAxisAlignment.start,
          children: [
            TrackCover(
              url: coverUrl,
              size: size - 16,
              borderRadius: 16,
              isCircle: isCircle,
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 15,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: isCircle ? TextAlign.center : TextAlign.start,
            ),
            if (artists != null) ...[
              const SizedBox(height: 4),
              ArtistNamesWidget(
                artists: artists!,
                fontSize: 13,
                color: Colors.white38,
              ),
            ] else if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(
                subtitle!,
                style: const TextStyle(color: Colors.white38, fontSize: 13),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: isCircle ? TextAlign.center : TextAlign.start,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
