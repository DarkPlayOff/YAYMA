import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/core/views/widgets/app_cover.dart';
import 'package:yayma/src/features/core/views/widgets/common_ui.dart';
import 'package:yayma/src/features/core/views/widgets/responsive.dart';
import 'package:yayma/src/features/core/views/widgets/tab_visibility.dart';
import 'package:yayma/src/features/core/views/widgets/track_tile.dart';
import 'package:yayma/src/features/history/providers/history_provider.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/models.dart';

class HistoryView extends StatelessWidget {
  const HistoryView({super.key});

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final historyAsync = visibleSignal(context, historyTracksSignal);
        final isNarrow = context.isNarrow;
        final tracks = historyAsync.value ?? const <SimpleTrackDto>[];

        final Widget? placeholder = historyAsync.hasError
            ? CommonErrorWidget(error: historyAsync.error!)
            : historyAsync.isLoading && tracks.isEmpty
            ? const CommonLoadingWidget()
            : null;

        return Stack(
          children: [
            AppRefreshIndicator(
              onRefresh: historyTracksSignal.refresh,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: isNarrow
                          ? const EdgeInsets.fromLTRB(20, 16, 20, 8)
                          : context.viewPadding,
                      child: const CommonPageTitle(title: 'История'),
                    ),
                  ),
                  if (tracks.isEmpty && placeholder == null)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: Text(
                          'История пуста',
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                            fontSize: 18,
                          ),
                        ),
                      ),
                    ),
                  SliverM3ESegmentedList(
                    haptic: M3EHapticFeedback.light,
                    itemCount: tracks.length,
                    addAutomaticKeepAlives: false,
                    color: Colors.transparent,
                    padding: EdgeInsets.symmetric(
                      horizontal: isNarrow ? 0 : 32,
                      vertical: 4,
                    ),
                    itemBuilder: (context, i) =>
                        _HistoryTile(track: tracks[i]),
                  ),
                  const SliverPadding(padding: EdgeInsets.only(bottom: 140)),
                ],
              ),
            ),
            if (placeholder != null)
              Positioned.fill(
                // Must not eat the list's drags.
                child: IgnorePointer(child: Center(child: placeholder)),
              ),
          ],
        );
      },
    );
  }
}

class _HistoryTile extends StatelessWidget {
  final SimpleTrackDto track;

  const _HistoryTile({required this.track});

  @override
  Widget build(BuildContext context) {
    return CommonTrackTile(
      trackId: track.id,
      title: track.title,
      version: track.version,
      artists: track.artists,
      albumId: track.albumId,
      leading: AppCover(coverUrl: track.coverUrl),
      trailing: Text(
        formatDuration(track.durationMs),
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      onTap: () => PlaybackController.playTrack(track.id),
    );
  }
}
