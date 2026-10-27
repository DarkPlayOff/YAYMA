import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/core/providers/navigation_provider.dart';
import 'package:yayma/src/features/core/theme/app_tokens.dart';
import 'package:yayma/src/features/core/views/widgets/app_cover.dart';
import 'package:yayma/src/features/core/views/widgets/hover_scale.dart';
import 'package:yayma/src/features/core/views/widgets/tab_visibility.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';

class HomeCoverWidget extends StatefulWidget {
  const HomeCoverWidget({super.key});

  @override
  State<HomeCoverWidget> createState() => _HomeCoverWidgetState();
}

class _HomeCoverWidgetState extends State<HomeCoverWidget> {
  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        // No subscriptions while the tab is hidden.
        final meta = visibleSignal(context, trackMetadataSignal);
        final showLyrics = visibleSignal(context, showLyricsSignal);
        final isPlaying = visibleSignal(context, isPlayingSignal);
        final height = MediaQuery.of(context).size.height;
        final width = MediaQuery.of(context).size.width;
        final isNarrow = width < 600;

        var size = showLyrics ? 320.0 : 420.0;
        if (height < 800) size = showLyrics ? 280.0 : 360.0;
        if (height < 650) size = showLyrics ? 200.0 : 260.0;
        if (isNarrow && !showLyrics) size = width * 0.8;

        return HoverScale(
          hoverScale: 1.035,
          duration: const Duration(milliseconds: 400),
          cursor: meta.albumId != null
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onTap: meta.albumId != null
              ? () => navigateTo(AppSection.album, meta.albumId)
              : null,
          child: AnimatedScale(
            scale: isPlaying ? 1.0 : AppCoverMotion.largePausedScale,
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOutBack,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeInOutCubic,
              width: size,
              height: size,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 500),
                transitionBuilder: (child, animation) {
                  return FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(
                      scale: Tween<double>(
                        begin: 0.9,
                        end: 1,
                      ).animate(animation),
                      child: child,
                    ),
                  );
                },
                child: AppCover(
                  key: ValueKey(meta.coverUrl),
                  coverUrl: meta.coverUrl,
                  size: size,
                  radius: AppRadius.md,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
