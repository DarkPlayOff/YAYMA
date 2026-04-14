import 'package:flutter/material.dart';
import 'package:yayma/src/ui/widgets/rust_cached_image.dart';

class FullscreenCoverDialog extends StatelessWidget {
  final String imageUrl;

  const FullscreenCoverDialog({required this.imageUrl, super.key});

  static Future<void> show(BuildContext context, String imageUrl) {
    // Пытаемся получить версию высокого качества
    final highResUrl = imageUrl
        .replaceFirst('200x200', '1000x1000')
        .replaceFirst('400x400', '1000x1000');

    return showDialog<void>(
      context: context,
      useSafeArea: false,
      barrierColor: Colors.black.withValues(alpha: 0.9),
      builder: (context) => FullscreenCoverDialog(imageUrl: highResUrl),
    );
  }

  @override
  Widget build(BuildContext context) {
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
                    tag: imageUrl,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: RustCachedImage(
                        imageUrl: imageUrl,
                        width: double.infinity,
                        height: double.infinity,
                        fit: BoxFit.contain,
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
