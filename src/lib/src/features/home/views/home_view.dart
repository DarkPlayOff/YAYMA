import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/core/providers/navigation_provider.dart';
import 'package:yayma/src/features/core/views/widgets/common_ui.dart';
import 'package:yayma/src/features/core/views/widgets/home_cover_widget.dart';
import 'package:yayma/src/features/core/views/widgets/lyrics_view.dart';
import 'package:yayma/src/features/core/views/widgets/quality_selector.dart';
import 'package:yayma/src/features/core/views/widgets/responsive.dart';
import 'package:yayma/src/features/core/views/widgets/tab_visibility.dart';
import 'package:yayma/src/features/core/views/widgets/track_elements.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/models.dart';

class HomeView extends StatelessWidget {
  const HomeView({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SignalBuilder(
          builder: (context) {
            // No subscription while the tab is hidden.
            final showLyrics = visibleSignal(context, showLyricsSignal);
            final width = constraints.maxWidth;

            return Stack(
              children: [
                _buildPlayerSide(context, showLyrics, constraints),
                _buildLyricsSide(context, showLyrics, width),
              ],
            );
          },
        );
      },
    );
  }

  /// Vertical spacing shrinks on short screens so the block still fits.
  ({double vertical, double header, double controls}) _spacingFor(
    double height,
  ) {
    if (height < 650) return (vertical: 16, header: 16, controls: 16);
    if (height < 800) return (vertical: 24, header: 24, controls: 24);
    return (vertical: 40, header: 32, controls: 32);
  }

  Widget _buildPlayerSide(
    BuildContext context,
    bool showLyrics,
    BoxConstraints constraints,
  ) {
    final width = constraints.maxWidth;
    final height = constraints.maxHeight;
    final spacing = _spacingFor(height);
    final isNarrow = context.isNarrow;
    final narrowContentWidth = (width - 48).clamp(0.0, double.infinity);
    final headerMaxWidth = (width - 48).clamp(320.0, 1400.0);

    return AnimatedPositioned(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOutCubic,
      left: showLyrics ? -width : 0,
      right: showLyrics ? width : 0,
      top: 0,
      bottom: 0,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: isNarrow && !showLyrics
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Center(child: HomeCoverWidget()),
                    SizedBox(height: spacing.vertical * 1.5),
                    _HomeTrackHeader(
                      small: height < 750,
                      isNarrow: true,
                      maxWidth: narrowContentWidth,
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: narrowContentWidth,
                      child: CommonProgressSlider(maxWidth: narrowContentWidth),
                    ),
                    const SizedBox(height: 12),
                    _HomeMainControls(
                      showLyrics: showLyrics,
                      small: height < 750,
                      isNarrow: true,
                    ),
                  ],
                )
              : FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const HomeCoverWidget(),
                      SizedBox(height: spacing.vertical),
                      _HomeTrackHeader(
                        small: height < 750,
                        maxWidth: headerMaxWidth,
                      ),
                      SizedBox(height: spacing.header),
                      const SizedBox(
                        width: 500,
                        child: CommonProgressSlider(maxWidth: 500),
                      ),
                      SizedBox(height: spacing.controls),
                      _HomeMainControls(
                        showLyrics: showLyrics,
                        small: height < 750,
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  Widget _buildLyricsSide(BuildContext context, bool showLyrics, double width) {
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOutCubic,
      left: showLyrics ? 0 : width,
      right: showLyrics ? 0 : -width,
      top: 0,
      bottom: 0,
      child: Container(
        padding: EdgeInsets.only(
          left: Platform.isAndroid ? 20 : 60,
          right: Platform.isAndroid ? 20 : 60,
          top: Platform.isAndroid ? 20 : 40,
          bottom:
              (Platform.isAndroid ? 100 : 40) +
              MediaQuery.viewPaddingOf(context).bottom,
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: SignalBuilder(
                builder: (context) {
                  final trackId = visibleSignal(
                    context,
                    trackMetadataSignal,
                  ).id;
                  if (trackId == null) {
                    return Center(
                      child: Text(
                        'Выберите трек',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    );
                  }
                  return LyricsWidget(trackId: trackId, visible: showLyrics);
                },
              ),
            ),
            if (Platform.isAndroid)
              Positioned(
                top: 10,
                left: 0,
                child: SafeArea(
                  child: IconButton(
                    icon: Icon(
                      Icons.arrow_back_ios_new_rounded,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      size: 24,
                    ),
                    onPressed: () {
                      showLyricsSignal.value = false;
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _HomeTrackHeader extends StatefulWidget {
  final bool small;
  final bool isNarrow;
  final double maxWidth;
  const _HomeTrackHeader({
    required this.small,
    required this.maxWidth,
    this.isNarrow = false,
  });

  @override
  State<_HomeTrackHeader> createState() => _HomeTrackHeaderState();
}

class _HomeTrackHeaderState extends State<_HomeTrackHeader> {
  final ValueNotifier<bool> _isTitleHovered = ValueNotifier(false);

  @override
  void dispose() {
    _isTitleHovered.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        // No subscription while the tab is hidden.
        final meta = visibleSignal(context, trackMetadataSignal);

        return Column(
          crossAxisAlignment: widget.isNarrow
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.center,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: widget.maxWidth),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: widget.isNarrow
                    ? MainAxisAlignment.start
                    : MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Flexible(
                    flex: 3,
                    child: MouseRegion(
                      onEnter: (_) => _isTitleHovered.value = true,
                      onExit: (_) => _isTitleHovered.value = false,
                      cursor: meta.albumId != null
                          ? SystemMouseCursors.click
                          : SystemMouseCursors.basic,
                      child: ValueListenableBuilder<bool>(
                        valueListenable: _isTitleHovered,
                        builder: (context, hovered, _) {
                          return GestureDetector(
                            onTap: () {
                              if (meta.albumId != null) {
                                navigateTo(AppSection.album, meta.albumId);
                              }
                            },
                            child: Tooltip(
                              message: meta.version == null
                                  ? meta.title
                                  : '${meta.title} ${meta.version}',
                              waitDuration: const Duration(milliseconds: 500),
                              child: Text.rich(
                                trackTitleSpan(
                                  context,
                                  title: meta.title,
                                  version: meta.version,
                                  versionFontSize: widget.small
                                      ? (widget.isNarrow ? 12 : 16)
                                      : (widget.isNarrow ? 14 : 20),
                                  style: TextStyle(
                                    fontSize: widget.small
                                        ? (widget.isNarrow ? 18 : 32)
                                        : (widget.isNarrow ? 22 : 42),
                                    fontWeight: FontWeight.w900,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurface,
                                    letterSpacing: -1,
                                    height: 1.05,
                                    decoration: hovered && meta.albumId != null
                                        ? TextDecoration.underline
                                        : null,
                                    shadows: widget.isNarrow
                                        ? null
                                        : const [Shadow(blurRadius: 20)],
                                  ),
                                ),
                                maxLines: 1,
                                softWrap: false,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            ArtistNamesWidget(
              artists: meta.artists,
              fontSize: widget.small
                  ? (widget.isNarrow ? 12 : 16)
                  : (widget.isNarrow ? 14 : 22),
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ],
        );
      },
    );
  }
}

class _HomeMainControls extends StatelessWidget {
  final bool showLyrics;
  final bool small;
  final bool isNarrow;

  const _HomeMainControls({
    required this.showLyrics,
    required this.small,
    this.isNarrow = false,
  });

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) => isNarrow
          ? _buildNarrowControls(context)
          : _buildWideControls(context),
    );
  }

  /// Repeat button icon and colour for the current mode.
  (IconData, Color) _repeatGlyph(
    RepeatModeDto mode,
    Color accent,
    Color muted,
  ) {
    return switch (mode) {
      RepeatModeDto.all => (Icons.repeat, accent),
      RepeatModeDto.single => (Icons.repeat_one, accent),
      _ => (Icons.repeat, muted),
    };
  }

  Widget _buildNarrowControls(BuildContext context) {
    // No subscriptions while the tab is hidden; fresh values are picked up by
    // the single rebuild when the tab opens.
    final trackId = visibleSignal(context, trackMetadataSignal).id;
    final isPlaying = visibleSignal(context, isPlayingSignal);
    final isLiked = visibleSignal(context, isLikedSignal);
    final isDisliked = visibleSignal(context, isDislikedSignal);
    final isShuffled = visibleSignal(context, isShuffledSignal);
    final accentColor = visibleSignal<Color>(context, accentColorSignal);
    final scheme = Theme.of(context).colorScheme;
    final onSurface = scheme.onSurface;
    final onSurfaceVariant = scheme.onSurfaceVariant;
    final (repeatIcon, repeatColor) = _repeatGlyph(
      visibleSignal(context, repeatModeSignal),
      accentColor,
      onSurfaceVariant,
    );

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            IconButton(
              icon: Icon(
                isDisliked ? Icons.heart_broken : Icons.heart_broken_outlined,
                size: 24,
                color: isDisliked ? Colors.blueGrey : onSurfaceVariant,
              ),
              onPressed: () => trackId != null
                  ? unawaited(
                      PlaybackController.toggleDislike(trackId: trackId),
                    )
                  : null,
            ),
            IconButton(
              icon: Icon(
                Icons.skip_previous_rounded,
                size: 42,
                color: onSurface,
              ),
              onPressed: () => unawaited(PlaybackController.prev()),
            ),
            IconButton(
              iconSize: 84,
              icon: Icon(
                isPlaying
                    ? Icons.pause_circle_filled_rounded
                    : Icons.play_circle_filled_rounded,
              ),
              color: onSurface,
              onPressed: () => unawaited(PlaybackController.togglePlay()),
            ),
            IconButton(
              icon: Icon(Icons.skip_next_rounded, size: 42, color: onSurface),
              onPressed: () => unawaited(PlaybackController.next()),
            ),
            SizedBox(
              width: 48,
              height: 48,
              child: Center(
                child: AnimatedLikeButton(
                  isLiked: isLiked,
                  size: 26,
                  onTap: trackId != null
                      ? () => unawaited(
                          PlaybackController.toggleLike(trackId: trackId),
                        )
                      : null,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                IconButton(
                  icon: Icon(
                    Icons.lyrics_rounded,
                    size: 24,
                    color: showLyrics ? accentColor : onSurfaceVariant,
                  ),
                  onPressed: () =>
                      showLyricsSignal.value = !showLyricsSignal.value,
                ),
                IconButton(
                  icon: Icon(
                    Icons.shuffle,
                    size: 24,
                    color: isShuffled ? accentColor : onSurfaceVariant,
                  ),
                  onPressed: () =>
                      unawaited(PlaybackController.toggleShuffle()),
                ),
              ],
            ),
            Row(
              children: [
                IconButton(
                  icon: Icon(repeatIcon, size: 24, color: repeatColor),
                  onPressed: () => unawaited(PlaybackController.toggleRepeat()),
                ),
                const SizedBox(
                  width: 48,
                  child: Center(child: CommonQualitySelector(iconSize: 24)),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildWideControls(BuildContext context) {
    // No subscriptions while the tab is hidden; fresh values are picked up by
    // the single rebuild when the tab opens.
    final trackId = visibleSignal(context, trackMetadataSignal).id;
    final isPlaying = visibleSignal(context, isPlayingSignal);
    final isLiked = visibleSignal(context, isLikedSignal);
    final isDisliked = visibleSignal(context, isDislikedSignal);
    final isShuffled = visibleSignal(context, isShuffledSignal);
    final accentColor = visibleSignal<Color>(context, accentColorSignal);
    final scheme = Theme.of(context).colorScheme;
    final onSurface = scheme.onSurface;
    final onSurfaceVariant = scheme.onSurfaceVariant;
    final (repeatIcon, repeatColor) = _repeatGlyph(
      visibleSignal(context, repeatModeSignal),
      accentColor,
      onSurfaceVariant,
    );

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              icon: Icon(
                Icons.lyrics_rounded,
                size: small ? 20 : 24,
                color: showLyrics ? accentColor : onSurfaceVariant,
              ),
              onPressed: () => showLyricsSignal.value = !showLyricsSignal.value,
            ),
            SizedBox(width: small ? 8 : 12),
            IconButton(
              icon: Icon(
                Icons.shuffle,
                size: small ? 20 : 24,
                color: isShuffled ? accentColor : onSurfaceVariant,
              ),
              onPressed: () => unawaited(PlaybackController.toggleShuffle()),
            ),
            SizedBox(width: small ? 8 : 12),
            IconButton(
              icon: Icon(
                isDisliked ? Icons.heart_broken : Icons.heart_broken_outlined,
                size: small ? 20 : 24,
                color: isDisliked ? Colors.blueGrey : onSurfaceVariant,
              ),
              onPressed: () => trackId != null
                  ? unawaited(
                      PlaybackController.toggleDislike(trackId: trackId),
                    )
                  : null,
            ),
            SizedBox(width: small ? 12 : 20),
            IconButton(
              icon: Icon(
                Icons.skip_previous_rounded,
                size: small ? 32 : 42,
                color: onSurface,
              ),
              onPressed: () => unawaited(PlaybackController.prev()),
            ),
            SizedBox(width: small ? 16 : 24),
            IconButton(
              iconSize: small ? 56 : 72,
              icon: Icon(
                isPlaying
                    ? Icons.pause_circle_filled_rounded
                    : Icons.play_circle_filled_rounded,
              ),
              color: onSurface,
              onPressed: () => unawaited(PlaybackController.togglePlay()),
            ),
            SizedBox(width: small ? 16 : 24),
            IconButton(
              icon: Icon(
                Icons.skip_next_rounded,
                size: small ? 32 : 42,
                color: onSurface,
              ),
              onPressed: () => unawaited(PlaybackController.next()),
            ),
            SizedBox(width: small ? 12 : 20),
            AnimatedLikeButton(
              isLiked: isLiked,
              size: small ? 22 : 26,
              onTap: trackId != null
                  ? () => unawaited(
                      PlaybackController.toggleLike(trackId: trackId),
                    )
                  : null,
            ),
            SizedBox(width: small ? 8 : 12),
            IconButton(
              icon: Icon(repeatIcon, size: small ? 20 : 24, color: repeatColor),
              onPressed: () => unawaited(PlaybackController.toggleRepeat()),
            ),
            SizedBox(width: small ? 8 : 12),
            CommonQualitySelector(iconSize: small ? 20 : 24),
          ],
        ),
        if (!Platform.isAndroid) ...[
          SizedBox(height: small ? 20 : 32),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.volume_down, color: onSurfaceVariant, size: 18),
              const SizedBox(width: 12),
              CommonVolumeSlider(
                width: small ? 180 : 240,
                activeColor: accentColor,
              ),
              const SizedBox(width: 12),
              Icon(Icons.volume_up, color: onSurfaceVariant, size: 18),
              const SizedBox(width: 8),
              const AudioDeviceButton(),
            ],
          ),
        ],
      ],
    );
  }
}
