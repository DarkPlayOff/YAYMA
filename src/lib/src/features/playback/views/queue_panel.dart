import 'dart:async';
import 'dart:io';
import 'dart:ui' show FontFeature, lerpDouble;

import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/core/services/app_error.dart';
import 'package:yayma/src/features/core/theme/app_tokens.dart';
import 'package:yayma/src/features/core/views/widgets/app_cover.dart';
import 'package:yayma/src/features/core/views/widgets/common_ui.dart';
import 'package:yayma/src/features/core/views/widgets/smooth_scroll.dart';
import 'package:yayma/src/features/core/views/widgets/track_elements.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/models.dart';

/// Opens the "Очередь воспроизведения" panel. Follows the app-wide overlay
/// split (see AudioSettingsDialog): a drag-sheet on Android, a dialog on
/// desktop.
Future<void> showQueuePanel(BuildContext context) {
  if (Platform.isAndroid) {
    return showAppBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        snap: true,
        expand: false,
        builder: (context, scrollController) =>
            QueuePanel(bottomSheet: true, scrollController: scrollController),
      ),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (context) => const QueuePanel(),
  );
}

/// Playback queue as one flat list in play order: already-played tracks, the
/// current one (highlighted and scrolled into view on open), then everything
/// that plays next, with tap-to-jump, per-row remove and drag&drop reorder.
class QueuePanel extends StatefulWidget {
  /// Sheet mode: the panel is embedded into a [DraggableScrollableSheet] and
  /// its scroll view must be driven by the sheet-provided controller.
  final bool bottomSheet;
  final ScrollController? scrollController;

  const QueuePanel({
    super.key,
    this.bottomSheet = false,
    this.scrollController,
  });

  @override
  State<QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends State<QueuePanel> {
  /// Only used in the dialog branch, where no sheet controller is passed.
  SmoothScrollController? _ownScrollController;

  /// Optimistic order for local-first reorders: set the moment the user
  /// drops a dragged track so the drop animation lands without waiting for
  /// the Rust roundtrip. Lives in the State on purpose — closing the panel
  /// drops it, so it can never outlive the view and freeze the list.
  List<SimpleTrackDto>? _override;

  /// The queue revision and window start at the moment [_override] was
  /// applied; it is dropped once a fetch that started after it (new revision
  /// or moved window) has completed.
  int? _overrideRevision;
  int? _overrideWindowStart;

  /// The current-track row, scrolled into view once when the panel opens so
  /// the playing track is what the user sees first.
  final GlobalKey _currentRowKey = GlobalKey();
  bool _scrolledToCurrent = false;

  ScrollController get _scrollController =>
      widget.scrollController ??
      (_ownScrollController ??= SmoothScrollController(debugLabel: 'queue'));

  @override
  void dispose() {
    _ownScrollController?.dispose();
    _ownScrollController = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final cs = Theme.of(context).colorScheme;
        final queueState = queueWindowSignal();
        // Narrow signals only: subscribing to the whole playerStateSignal
        // would rebuild this O(n) list on every volume/pause tick.
        final currentTrack = currentTrackSignal();
        final isPlaying = isPlayingSignal();

        // Data branch first: a background refresh keeps the old value, and
        // matching on isLoading first would blank the panel on every refetch.
        final fetched = queueState.hasValue
            ? (queueState.value ?? const <SimpleTrackDto>[])
            : const <SimpleTrackDto>[];
        final queueIndex = queueIndexSignal();
        final queueCount = queueCountSignal();
        final upcomingCount = queueCount - queueIndex - 1;
        // Already-played rows carry their absolute start index; the count is
        // clamped to the playhead so a stale window (kept while a move
        // refetches) never duplicates the current/upcoming rows.
        final playedWindow = queuePlayedWindowSignal().value;
        final playedTracks = playedWindow?.tracks ?? const <SimpleTrackDto>[];
        final playedStart = playedWindow?.start ?? 0;
        final playedCount = (queueIndex - playedStart).clamp(
          0,
          playedTracks.length,
        );
        // Local-first reorder: while an override is active the panel shows
        // the order the user dropped into place; the refetch triggered by the
        // revision bump confirms it right after, and the override is dropped
        // — the swap is invisible because the content matches.
        final override = _override;
        final tracks = override ?? fetched;
        final revision = queueRevisionSignal();
        if (override != null &&
            _overrideRevision != null &&
            queueState.hasValue &&
            !queueState.isLoading &&
            (revision != _overrideRevision ||
                queueIndex + 1 != _overrideWindowStart)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() {
                _override = null;
                _overrideRevision = null;
                _overrideWindowStart = null;
              });
            }
          });
        }

        // Stable row keys: a per-track occurrence count inside the window
        // instead of the absolute index, which changes on every reorder and
        // would otherwise rebuild the rows mid-drag.
        final ordinals = <int>[];
        final seenIds = <String, int>{};
        for (final track in tracks) {
          final n = seenIds[track.id] ?? 0;
          ordinals.add(n);
          seenIds[track.id] = n + 1;
        }

        // One flat queue list in play order — played tracks, the current one,
        // then upcoming — scrolled to the current row on open.
        final content = CustomScrollView(
          controller: _scrollController,
          slivers: [
            if (widget.bottomSheet)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(24, 12, 16, 0),
                sliver: SliverToBoxAdapter(
                  child: _buildHeader(context, canClear: upcomingCount > 0),
                ),
              ),
            if (playedCount > 0)
              SliverPadding(
                padding: const EdgeInsets.only(top: 12),
                sliver: SliverList.builder(
                  itemCount: playedCount,
                  itemBuilder: (context, index) => _QueueTrackRow(
                    track: playedTracks[index],
                    absoluteIndex: playedStart + index,
                    isPlayed: true,
                  ),
                ),
              ),
            if (currentTrack != null)
              SliverPadding(
                padding: const EdgeInsets.only(top: 12),
                sliver: SliverToBoxAdapter(
                  child: KeyedSubtree(
                    key: _currentRowKey,
                    child: _QueueTrackRow(
                      track: currentTrack,
                      isCurrent: true,
                      isPlaying: isPlaying,
                    ),
                  ),
                ),
              ),
            if (queueState.hasError && !queueState.hasValue)
              SliverToBoxAdapter(child: _ErrorRow(error: queueState.error!))
            else if (!queueState.hasValue && queueState.isLoading)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Center(child: M3ELoadingIndicator()),
                ),
              )
            else if (queueCount == 0)
              const SliverToBoxAdapter(child: _EmptyQueue())
            else if (upcomingCount <= 0)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 24, 0),
                  child: Text(
                    'Это последний трек в очереди',
                    style: TextStyle(
                      color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                      fontSize: 13,
                    ),
                  ),
                ),
              )
            else ...[
              SliverPadding(
                padding: const EdgeInsets.only(top: 4),
                sliver: SliverReorderableList(
                  itemCount: tracks.length,
                  // Reorder without a handle: long-press the row on touch,
                  // drag by the cover on desktop (see _QueueTrackRow).
                  onReorderItem: (oldIndex, newIndex) {
                    // onReorderItem already shifts newIndex down for items
                    // moved downward; the window list starts right after the
                    // current track, so visible offsets shift back to
                    // absolute queue indices by a constant (removal happens
                    // first, so the final index equals the pre-removal
                    // position of the target).
                    final first = queueIndex + 1;
                    // Local-first: apply the same remove+insert the Rust
                    // reorder will do, so the drop animation lands on the
                    // final order immediately instead of snapping when the
                    // refetch arrives.
                    final list = [...tracks];
                    final moved = list.removeAt(oldIndex);
                    list.insert(newIndex, moved);
                    setState(() {
                      _override = list;
                      _overrideRevision = queueRevisionSignal.peek();
                      _overrideWindowStart = first;
                    });
                    unawaited(
                      PlaybackController.reorderQueue(
                        first + oldIndex,
                        first + newIndex,
                      ),
                    );
                  },
                  proxyDecorator: (child, index, animation) {
                    return AnimatedBuilder(
                      animation: animation,
                      builder: (context, _) {
                        final t = Curves.easeOut.transform(animation.value);
                        final elevation = lerpDouble(0, 6, t)!;
                        return Material(
                          color: cs.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                          elevation: elevation,
                          shadowColor: Colors.black.withValues(alpha: 0.3),
                          child: child,
                        );
                      },
                    );
                  },
                  itemBuilder: (context, index) {
                    final track = tracks[index];
                    final absoluteIndex = queueIndex + 1 + index;
                    return KeyedSubtree(
                      key: ValueKey('queue_${track.id}#${ordinals[index]}'),
                      child: ReorderableDelayedDragStartListener(
                        index: index,
                        child: _QueueTrackRow(
                          track: track,
                          absoluteIndex: absoluteIndex,
                          dragIndex: index,
                        ),
                      ),
                    );
                  },
                ),
              ),
              if (upcomingCount > tracks.length)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 24, 0),
                    child: Text(
                      'Ещё ${plural(upcomingCount - tracks.length, 'трек', 'трека', 'треков')} '
                      'в очереди',
                      style: TextStyle(
                        color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
            ],
            SliverToBoxAdapter(
              child: SizedBox(
                height: MediaQuery.paddingOf(context).bottom + 24,
              ),
            ),
          ],
        );

        // Wait for the played window too: it sits above the current row, so
        // centering before it lands would leave the list far above the track.
        if (!_scrolledToCurrent &&
            currentTrack != null &&
            playedWindow != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || _scrolledToCurrent) return;
            _scrolledToCurrent = true;
            final rowContext = _currentRowKey.currentContext;
            if (rowContext == null) return;
            Scrollable.ensureVisible(
              rowContext,
              alignment: 0.4,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
            );
          });
        }

        if (widget.bottomSheet) {
          return Material(color: Colors.transparent, child: content);
        }

        return AppDialog(
          titlePadding: EdgeInsets.zero,
          titleWidget: Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 16, 0),
            child: _buildHeader(context, canClear: upcomingCount > 0),
          ),
          content: SizedBox(width: 460, height: 480, child: content),
          contentPadding: EdgeInsets.zero,
          actions: [
            M3ETextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Закрыть'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, {required bool canClear}) {
    final cs = Theme.of(context).colorScheme;
    final contextLabel = describePlaybackContext(playbackContextSignal());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Очередь воспроизведения',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.5,
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: Icon(
                Icons.delete_sweep_rounded,
                color: cs.onSurfaceVariant,
                size: 22,
              ),
              onPressed: canClear
                  ? () => unawaited(_confirmClearQueue(context))
                  : null,
            ),
          ],
        ),
        if (contextLabel != null) ...[
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Text(
              contextLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: cs.onSurfaceVariant.withValues(alpha: 0.8),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// Asks before dropping every upcoming track; the current one keeps
  /// playing. Same dialog shell as the playlist-delete confirmation.
  Future<void> _confirmClearQueue(BuildContext context) async {
    final cs = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AppDialog(
        title: 'Очистить очередь?',
        content: Text(
          'Из очереди будут удалены все треки после текущего. Это действие '
          'нельзя отменить.',
          style: TextStyle(color: cs.onSurfaceVariant),
        ),
        actions: [
          AppDialog.cancelButton(dialogContext),
          M3ETextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              'Очистить',
              style: TextStyle(color: cs.error, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      unawaited(PlaybackController.clearQueue());
    }
  }
}

/// Human-readable "Сейчас играет из …" line for the queue source context,
/// or null when the playback state carries no context. The kind words match
/// the desktop client's wording (genitive: "из плейлиста/альбома/…").
String? describePlaybackContext(PlaybackContextDto? context) {
  if (context == null) return null;
  final source = switch (context.kind) {
    'playlist' => 'плейлиста',
    'album' => 'альбома',
    'artist' => 'исполнителя',
    'track' => 'поиска',
    'wave' => 'Моей волны',
    _ => 'очереди',
  };
  final title = context.title;
  return (title == null || title.isEmpty)
      ? 'Сейчас играет из $source'
      : 'Сейчас играет из $source · $title';
}

/// True on touch-first platforms, where long-press is the natural reorder
/// gesture; desktop drags by the cover instead.
final bool _isTouchPlatform = Platform.isAndroid || Platform.isIOS;

/// One queue row. Full-width card: cover, title/artists, duration. The current
/// track is highlighted and shows a live indicator instead of the duration;
/// it has no remove button. Tapping a row jumps to it.
class _QueueTrackRow extends StatelessWidget {
  final SimpleTrackDto track;

  /// Jump target; null for the current track (it is already playing).
  final int? absoluteIndex;

  final bool isCurrent;
  final bool isPlaying;

  /// Already played: dimmed, tapping replays it.
  final bool isPlayed;

  /// Offset inside the reorderable list; set for upcoming rows only. On
  /// desktop the cover doubles as the drag handle (long-press drag is not
  /// discoverable with a mouse).
  final int? dragIndex;

  const _QueueTrackRow({
    required this.track,
    this.absoluteIndex,
    this.isCurrent = false,
    this.isPlaying = false,
    this.isPlayed = false,
    this.dragIndex,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    Widget cover = AppCover(
      coverUrl: track.coverUrl,
      size: 52,
      radius: AppRadius.sm,
      // A 52px row lands on the coarse 80px preset at 1x; floor at 2x.
      minPixelRatio: 2,
    );
    final dragIndex = this.dragIndex;
    if (dragIndex != null && !_isTouchPlatform) {
      cover = MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: ReorderableDragStartListener(index: dragIndex, child: cover),
      );
    }

    final row = Row(
      children: [
        cover,
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text.rich(
                trackTitleSpan(
                  context,
                  title: track.title,
                  version: track.version,
                  versionFontSize: 12,
                  style: TextStyle(
                    color: isCurrent
                        ? cs.primary
                        : isPlayed
                        ? cs.onSurfaceVariant
                        : cs.onSurface,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    height: 1.15,
                  ),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 3),
              ArtistNamesWidget(
                artists: track.artists,
                fontSize: 13,
                color: cs.onSurfaceVariant,
                maxLines: 1,
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        if (isCurrent)
          TrackPlayingIndicator(isPlaying: isPlaying, color: cs.primary)
        else ...[
          Text(
            formatDuration(track.durationMs),
            style: TextStyle(
              color: cs.onSurfaceVariant,
              fontSize: 13,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          IconButton(
            icon: Icon(
              Icons.close_rounded,
              size: 18,
              color: cs.onSurfaceVariant,
            ),
            onPressed: () =>
                unawaited(PlaybackController.removeFromQueueAt(absoluteIndex!)),
          ),
        ],
      ],
    );

    if (isCurrent) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(color: cs.primary.withValues(alpha: 0.08)),
        child: row,
      );
    }
    return InkWell(
      onTap: absoluteIndex == null
          ? null
          : () =>
                unawaited(PlaybackController.jumpToQueueIndex(absoluteIndex!)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: row,
      ),
    );
  }
}

class _EmptyQueue extends StatelessWidget {
  const _EmptyQueue();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          Icon(
            Icons.queue_music_rounded,
            size: 40,
            color: cs.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            'Очередь пуста',
            style: TextStyle(
              color: cs.onSurface,
              fontWeight: FontWeight.w800,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Запустите трек — здесь появится очередь воспроизведения',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: cs.onSurfaceVariant.withValues(alpha: 0.6),
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorRow extends StatelessWidget {
  final Object error;
  const _ErrorRow({required this.error});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: cs.error, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Не удалось загрузить очередь: ${humanizeError(error)}',
              style: TextStyle(color: cs.error, fontSize: 13),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          M3ETextButton(
            onPressed: () => unawaited(queueWindowSignal.refresh()),
            child: const Text('Повторить'),
          ),
        ],
      ),
    );
  }
}
