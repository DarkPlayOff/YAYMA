import 'dart:async';

import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/core/views/widgets/app_cover.dart';
import 'package:yayma/src/features/core/views/widgets/common_ui.dart';
import 'package:yayma/src/features/core/views/widgets/responsive.dart';
import 'package:yayma/src/features/core/views/widgets/smooth_scroll.dart';
import 'package:yayma/src/features/core/views/widgets/tab_visibility.dart';
import 'package:yayma/src/features/core/views/widgets/track_tile.dart';
import 'package:yayma/src/features/history/providers/history_provider.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/models.dart';

/// Server-side listening history (the `/plays` reports), shown as a library
/// tab and loaded 50 entries at a time while scrolling.
class HistoryView extends StatefulWidget {
  const HistoryView({super.key});

  @override
  State<HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends State<HistoryView> {
  final ScrollController _scrollController = SmoothScrollController(
    debugLabel: 'history',
  );

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    unawaited(refreshHistory());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 500) {
      unawaited(loadMoreHistory());
    }
  }

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final tracks = visibleSignal(context, historyTracksSignal);
        final isLoading = visibleSignal(context, isHistoryLoadingSignal);
        final isNarrow = context.isNarrow;

        return Stack(
          children: [
            AppRefreshIndicator(
              onRefresh: refreshHistory,
              child: CustomScrollView(
                controller: _scrollController,
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  if (tracks.isEmpty && !isLoading)
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
                    itemBuilder: (context, i) => _HistoryTile(track: tracks[i]),
                  ),
                  const SliverPadding(padding: EdgeInsets.only(bottom: 140)),
                ],
              ),
            ),
            if (tracks.isEmpty && isLoading)
              const Positioned.fill(
                // Must not eat the list's drags.
                child: IgnorePointer(
                  child: Center(child: CommonLoadingWidget()),
                ),
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
