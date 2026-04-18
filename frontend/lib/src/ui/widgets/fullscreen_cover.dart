import 'package:flutter/material.dart';
import 'package:yayma/src/ui/widgets/rust_cached_image.dart';

class FullscreenCoverDialog extends StatelessWidget {
  final String imageUrl;
  final String heroTag;

  const FullscreenCoverDialog({
    required this.imageUrl,
    required this.heroTag,
    super.key,
  });

  static Future<void> show(
    BuildContext context,
    String imageUrl, {
    String? heroTag,
  }) {
    // Пытаемся получить версию высокого качества
    final highResUrl = imageUrl
        .replaceFirst('200x200', '1000x1000')
        .replaceFirst('400x400', '1000x1000');

    return Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black.withValues(alpha: 0.9),
        barrierDismissible: true,
        pageBuilder: (context, animation, secondaryAnimation) {
          return FadeTransition(
            opacity: animation,
            child: FullscreenCoverDialog(
              imageUrl: highResUrl,
              heroTag: heroTag ?? imageUrl,
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // В качестве placeholder'а используем оригинальную (low-res) обложку,
    // чтобы при загрузке high-res не было мерцания
    final placeholder = RustCachedImage(
      imageUrl: heroTag, // heroTag contains the original low-res url
      fit: BoxFit.contain,
    );

    return GestureDetector(
      onTap: () => Navigator.of(context).pop(),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: Hero(
                    tag: heroTag,
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: RustCachedImage(
                          imageUrl: imageUrl,
                          placeholder: placeholder,
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 24,
              right: 24,
              child: IconButton(
                icon: const Icon(
                  Icons.close_rounded,
                  size: 32,
                  color: Colors.white70,
                ),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
