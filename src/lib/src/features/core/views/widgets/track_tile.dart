import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/app/session.dart';
import 'package:yayma/src/features/core/providers/navigation_provider.dart';
import 'package:yayma/src/features/core/providers/notification_provider.dart';
import 'package:yayma/src/features/core/theme/app_tokens.dart';
import 'package:yayma/src/features/core/views/widgets/app_context_menu.dart';
import 'package:yayma/src/features/core/views/widgets/app_cover.dart';
import 'package:yayma/src/features/core/views/widgets/download_menu.dart';
import 'package:yayma/src/features/core/views/widgets/lyrics_view.dart';
import 'package:yayma/src/features/core/views/widgets/responsive.dart';
import 'package:yayma/src/features/core/views/widgets/tab_visibility.dart';
import 'package:yayma/src/features/core/views/widgets/track_context_sheet.dart';
import 'package:yayma/src/features/core/views/widgets/track_details_dialog.dart';
import 'package:yayma/src/features/core/views/widgets/track_elements.dart';
import 'package:yayma/src/features/library/providers/library_provider.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/content.dart' as rust;
import 'package:yayma/src/rust/api/models.dart';

class CommonTrackTile extends StatefulWidget {
  final String trackId;
  final String title;
  final String? version;
  final List<TrackArtistDto> artists;
  final Widget? leading;
  final Widget? trailing;
  final List<Widget>? hoverActions;
  final VoidCallback? onTap;
  final VoidCallback? onTitleTap;
  final EdgeInsetsGeometry? contentPadding;
  final String? albumId;

  /// Cover for the sheet menu header on Android, when [leading] is
  /// not a cover (e.g. the track number in an album).
  final String? sheetCoverUrl;

  const CommonTrackTile({
    required this.trackId,
    required this.title,
    required this.artists,
    super.key,
    this.version,
    this.leading,
    this.trailing,
    this.hoverActions,
    this.onTap,
    this.onTitleTap,
    this.contentPadding,
    this.albumId,
    this.sheetCoverUrl,
  });

  @override
  State<CommonTrackTile> createState() => _CommonTrackTileState();
}

const List<TrackSheetAction> _downloadSubActions = [
  TrackSheetAction(
    value: 'download_cache',
    label: 'В кэш приложения',
    icon: Icons.offline_bolt_rounded,
  ),
  TrackSheetAction(
    value: 'download_files',
    label: 'В отдельный файл',
    icon: Icons.file_download_rounded,
  ),
];

List<TrackSheetAction> _downloadSubActionsGetter() => _downloadSubActions;

class _CommonTrackTileState extends State<CommonTrackTile> {
  final ValueNotifier<bool> _isHovered = ValueNotifier(false);
  final ValueNotifier<bool> _isPressed = ValueNotifier(false);
  final ValueNotifier<bool> _isTitleHovered = ValueNotifier(false);
  final ValueNotifier<bool> _isMenuOpen = ValueNotifier(false);
  final ValueNotifier<int> _membershipVersion = ValueNotifier(0);

  @override
  void dispose() {
    _isHovered.dispose();
    _isPressed.dispose();
    _isTitleHovered.dispose();
    _isMenuOpen.dispose();
    _membershipVersion.dispose();
    super.dispose();
  }

  void _handleTap() {
    widget.onTap?.call();
  }

  Widget _adjustLeading(Widget leading, bool isNarrow) {
    if (isNarrow && leading is AppCover && leading.size == 64) {
      return AppCover(
        key: leading.key,
        coverUrl: leading.coverUrl ?? leading.url,
        url: leading.url,
        localUri: leading.localUri,
        size: 48,
        circle: leading.circle,
        heroTag: leading.heroTag,
        onTap: leading.onTap,
        borderRadius: leading.borderRadius,
        radius: leading.radius,
        shape: leading.shape,
        canExpand: leading.canExpand,
        hoverEnabled: leading.hoverEnabled,
        hoverScale: leading.hoverScale,
        fit: leading.fit,
        placeholderIcon: leading.placeholderIcon,
      );
    }
    return leading;
  }

  /// Open the bottom menu (sheet) with actions on a track.
  Future<void> _showTrackBottomSheet() async {
    final leading = widget.leading;
    final cover = leading is AppCover ? leading : null;

    final header = TrackContextSheetHeader(
      title: widget.title,
      version: widget.version,
      artists: widget.artists,
      coverUrl: cover?.coverUrl ?? cover?.url ?? widget.sheetCoverUrl,
      localCoverUri: cover?.localUri,
    );
    final downloaded = downloadedTracksSignal.value;

    Future<void> refreshMembership() {
      // Refresh the cache in the background; increment the version on
      // completion so the open sub-sheet redraws with up-to-date checkmarks.
      return refreshTrackPlaylistMembership(widget.trackId).then((_) {
        if (mounted) _membershipVersion.value++;
      });
    }

    List<TrackSheetAction> buildPlaylistSubActions() {
      final membershipKinds =
          trackPlaylistMembershipSignal.value[widget.trackId] ?? const <int>{};
      return [
        ...playlistsSignal.value.map(
          (p) => TrackSheetAction(
            value: 'add_to_${p.kind}',
            label: p.title,
            icon: Icons.library_music_rounded,
            isSelected: membershipKinds.contains(p.kind),
            leading: p.coverUrl == null
                ? null
                : AppCover(coverUrl: p.coverUrl, url: p.coverUrl, size: 48),
          ),
        ),
        const TrackSheetAction(
          value: 'create_playlist',
          label: 'Создать новый плейлист',
          icon: Icons.add_rounded,
        ),
      ];
    }

    await showTrackContextSheet(
      context,
      header: header,
      subSheetRebuildOn: _membershipVersion,
      onSelected: (value) {
        if (!mounted) return;
        unawaited(_handleMenuAction(value));
      },
      actions: [
        if (playlistsSignal.value.isNotEmpty)
          TrackSheetAction(
            label: 'Добавить в плейлист',
            icon: Icons.playlist_add_rounded,
            subSheetTitle: 'Добавить в плейлист',
            onSubSheetOpen: refreshMembership,
            subActions: buildPlaylistSubActions,
          ),
        if (widget.albumId != null)
          const TrackSheetAction(
            value: 'go_to_album',
            label: 'Перейти к альбому',
            icon: Icons.album_rounded,
          ),
        const TrackSheetAction(
          value: 'lyrics',
          label: 'Открыть текст',
          icon: Icons.lyrics_rounded,
        ),
        const TrackSheetAction(
          value: 'copy_link',
          label: 'Скопировать ссылку',
          icon: Icons.link_rounded,
        ),
        const TrackSheetAction(
          value: 'wave',
          label: 'Моя волна по треку',
          icon: Icons.waves_rounded,
        ),
        const TrackSheetAction(
          value: 'about',
          label: 'О треке',
          icon: Icons.info_outline_rounded,
        ),
        if (downloaded.contains(widget.trackId))
          const TrackSheetAction(
            value: 'delete_downloaded',
            label: 'Удалить из загрузок',
            icon: Icons.remove_circle_outline_rounded,
            color: Color(0xFFE57373),
          )
        else
          const TrackSheetAction(
            label: 'Скачать',
            icon: Icons.download_rounded,
            subSheetTitle: 'Скачать',
            subActions: _downloadSubActionsGetter,
          ),
      ],
    );
  }

  Future<void> _handleMenuAction(String value) async {
    if (!mounted) return;
    _isHovered.value = false;

    if (value.startsWith('add_to_')) {
      final kindStr = value.substring(7);
      final kind = int.tryParse(kindStr);
      if (kind != null) {
        final success = await addTrackToPlaylistAction(
          kind,
          widget.trackId,
          widget.albumId,
        );
        if (success) {
          showAppSuccess('Добавлено в плейлист');
        } else {
          showAppError('Ошибка при добавлении');
        }
      }
      return;
    }

    switch (value) {
      case 'go_to_album':
        if (widget.albumId != null) {
          navigateTo(AppSection.album, widget.albumId);
        }
      case 'lyrics':
        LyricsReaderDialog.show(context, widget.trackId, widget.title);
      case 'wave':
        unawaited(
          PlaybackController.startTrackWave(widget.trackId, widget.title),
        );
      case 'create_playlist':
        await _createPlaylistAndAddTrack();
      case 'about':
        TrackDetailsDialog.show(context, widget.trackId);
      case 'copy_link':
        final link = widget.albumId != null
            ? 'https://music.yandex.ru/album/${widget.albumId}/track/${widget.trackId}'
            : 'https://music.yandex.ru/track/${widget.trackId}';
        await Clipboard.setData(ClipboardData(text: link));
        showAppSuccess('Ссылка скопирована');
      case 'download_cache':
        await _downloadTrack(DownloadMode.cache);
      case 'delete_downloaded':
        final ctx = appContextSignal.value;
        if (ctx != null) {
          try {
            await rust.deleteDownloadedTrack(ctx: ctx, trackId: widget.trackId);
            showAppSuccess('Трек удален из загрузок');
            unawaited(refreshDownloadedTracks());
          } on Object catch (e) {
            showAppError('Ошибка: $e');
          }
        }
      case 'download_files':
        await _downloadTrack(DownloadMode.files);
    }
  }

  Future<String?> _promptPlaylistTitle() {
    final controller = TextEditingController();
    Future<void> close([String? value]) async {
      Navigator.of(context, rootNavigator: true).pop<String>(value);
    }

    return showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Новый плейлист'),
          content: TextField(
            controller: controller,
            maxLength: 64,
            decoration: const InputDecoration(hintText: 'Название'),
            onSubmitted: close,
          ),
          actions: [
            TextButton(onPressed: close, child: const Text('Отмена')),
            FilledButton(
              onPressed: () => close(controller.text),
              child: const Text('Создать'),
            ),
          ],
        );
      },
    ).whenComplete(controller.dispose);
  }

  /// Creates a private playlist with the entered name and immediately adds
  /// the current track to it.
  Future<void> _createPlaylistAndAddTrack() async {
    final title = await _promptPlaylistTitle();
    final trimmed = title?.trim();
    if (trimmed == null || trimmed.isEmpty || !mounted) return;

    final existingKinds = playlistsSignal.value.map((p) => p.kind).toSet();
    final success = await createPlaylistAction(trimmed, isPublic: false);
    if (!mounted) return;
    if (!success) {
      showAppError('Ошибка при создании плейлиста');
      return;
    }

    final created = playlistsSignal.value
        .where((p) => !existingKinds.contains(p.kind))
        .toList();
    if (created.isNotEmpty) {
      await addTrackToPlaylistAction(
        created.first.kind,
        widget.trackId,
        widget.albumId,
      );
      if (mounted) showAppSuccess("Создан плейлист '$trimmed'");
    }
  }

  Future<void> _downloadTrack(DownloadMode mode) async {
    final ctx = appContextSignal.value;
    if (ctx == null) return;

    showAppSuccess(
      mode == DownloadMode.cache
          ? 'Скачивание в кэш началось...'
          : 'Скачивание в файл началось...',
    );
    downloadingTracksSignal.value = {
      ...downloadingTracksSignal.value,
      widget.trackId,
    };

    try {
      final paths = await rust.downloadTracks(
        ctx: ctx,
        trackIds: [widget.trackId],
        toCache: mode == DownloadMode.cache,
      );
      if (mode == DownloadMode.cache) {
        showAppSuccess('Трек скачан');
        unawaited(refreshDownloadedTracks());
      } else {
        final path = paths.isEmpty ? '' : paths.first;
        showAppSuccess('Трек сохранен: $path');
      }
    } on Object catch (e) {
      showAppError('Ошибка: $e');
    } finally {
      final newSet = {...downloadingTracksSignal.value}..remove(widget.trackId);
      downloadingTracksSignal.value = newSet;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final isNarrow = context.isNarrow;

        final effectivePadding =
            widget.contentPadding ??
            EdgeInsets.symmetric(
              horizontal: isNarrow ? 8 : 12,
              vertical: isNarrow ? 4 : 8,
            );

        Widget buildContextMenu() {
          return SignalBuilder(
            builder: (watchContext) {
              // Menu content is built lazily here; no subscription while
              // the hosting tab is hidden.
              final playlists = visibleSignal(watchContext, playlistsSignal);
              final membershipKinds =
                  visibleSignal(
                    watchContext,
                    trackPlaylistMembershipSignal,
                  )[widget.trackId] ??
                  const <int>{};
              return AppContextMenu<String>(
                onOpen: () {
                  _isMenuOpen.value = true;
                  unawaited(refreshTrackPlaylistMembership(widget.trackId));
                },
                onClose: () {
                  _isMenuOpen.value = false;
                  _isHovered.value = false;
                },
                onSelected: (value) async {
                  if (!mounted) return;
                  await _handleMenuAction(value);
                },
                items: [
                  AppContextMenuItem(
                    label: 'Добавить в плейлист',
                    icon: Icons.playlist_add_rounded,
                    subItems: [
                      ...playlists.map(
                        (p) => AppContextMenuItem(
                          value: 'add_to_${p.kind}',
                          label: p.title,
                          icon: Icons.library_music_rounded,
                          isSelected: membershipKinds.contains(p.kind),
                          leading: p.coverUrl == null
                              ? null
                              : AppCover(
                                  coverUrl: p.coverUrl,
                                  url: p.coverUrl,
                                  size: 40,
                                ),
                        ),
                      ),
                      const AppContextMenuItem(
                        value: 'create_playlist',
                        label: 'Создать новый плейлист',
                        icon: Icons.add_rounded,
                      ),
                    ],
                  ),
                  if (widget.albumId != null)
                    const AppContextMenuItem(
                      value: 'go_to_album',
                      label: 'Перейти к альбому',
                      icon: Icons.album_rounded,
                    ),
                  const AppContextMenuItem(
                    value: 'lyrics',
                    label: 'Открыть текст',
                    icon: Icons.lyrics_rounded,
                  ),
                  const AppContextMenuItem(
                    value: 'copy_link',
                    label: 'Скопировать ссылку',
                    icon: Icons.link_rounded,
                  ),
                  const AppContextMenuItem(
                    value: 'wave',
                    label: 'Моя волна по треку',
                    icon: Icons.waves_rounded,
                  ),
                  const AppContextMenuItem(
                    value: 'about',
                    label: 'О треке',
                    icon: Icons.info_outline_rounded,
                  ),
                  const AppContextMenuItem(
                    label: 'Скачать',
                    icon: Icons.download_rounded,
                    subItems: [
                      AppContextMenuItem(
                        value: 'download_cache',
                        label: 'В кэш приложения',
                        icon: Icons.offline_bolt_rounded,
                      ),
                      AppContextMenuItem(
                        value: 'download_files',
                        label: 'В отдельный файл',
                        icon: Icons.file_download_rounded,
                      ),
                    ],
                  ),
                  if (visibleSignal(
                    watchContext,
                    downloadedTracksSignal,
                  ).contains(widget.trackId))
                    const AppContextMenuItem(
                      value: 'delete_downloaded',
                      label: 'Удалить из загрузок',
                      icon: Icons.remove_circle_outline_rounded,
                    ),
                ],
                child: IconButton(
                  icon: Icon(
                    Icons.more_horiz_rounded,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  onPressed: null,
                  tooltip: 'Действия',
                ),
              );
            },
          );
        }

        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: _handleTap,
            onHover: (value) => _isHovered.value = value,
            onHighlightChanged: (value) => _isPressed.value = value,
            hoverColor: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.06),
            focusColor: Colors.transparent,
            highlightColor: Colors.transparent,
            splashColor: Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(AppRadius.sm),
            child: ValueListenableBuilder<bool>(
              valueListenable: _isHovered,
              builder: (context, isHovered, child) {
                return ValueListenableBuilder<bool>(
                  valueListenable: _isMenuOpen,
                  builder: (context, isMenuOpen, child) {
                    final showHighlighted = isHovered || isMenuOpen;
                    return ValueListenableBuilder<bool>(
                      valueListenable: _isPressed,
                      builder: (context, isPressed, child) {
                        return AnimatedScale(
                          scale: isPressed ? 0.98 : 1.0,
                          duration: Duration(
                            milliseconds: isPressed ? 80 : 180,
                          ),
                          curve: isPressed
                              ? Curves.easeOutCubic
                              : Curves.easeOutBack,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            padding: effectivePadding,
                            decoration: BoxDecoration(
                              color: isMenuOpen
                                  ? Theme.of(context).colorScheme.onSurface
                                        .withValues(alpha: 0.08)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(AppRadius.sm),
                            ),
                            child: Row(
                              children: [
                                if (widget.leading != null) ...[
                                  _LeadingPlayingBadge(
                                    trackId: widget.trackId,
                                    child: _adjustLeading(
                                      widget.leading!,
                                      isNarrow,
                                    ),
                                  ),
                                  SizedBox(width: isNarrow ? 12 : 16),
                                ],
                                Expanded(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Flexible(
                                            child: MouseRegion(
                                              onEnter: (_) =>
                                                  _isTitleHovered.value = true,
                                              onExit: (_) =>
                                                  _isTitleHovered.value = false,
                                              cursor: widget.onTitleTap != null
                                                  ? SystemMouseCursors.click
                                                  : SystemMouseCursors.basic,
                                              child: GestureDetector(
                                                behavior:
                                                    HitTestBehavior.opaque,
                                                onTap: widget.onTitleTap,
                                                child: SignalBuilder(
                                                  builder: (context) {
                                                    // No subscription while the hosting tab is hidden.
                                                    final isCurrent =
                                                        visibleSignal(
                                                          context,
                                                          currentTrackIdSignal,
                                                        ) ==
                                                        widget.trackId;

                                                    return ValueListenableBuilder<
                                                      bool
                                                    >(
                                                      valueListenable:
                                                          _isTitleHovered,
                                                      builder:
                                                          (
                                                            context,
                                                            isTitleHovered,
                                                            child,
                                                          ) {
                                                            return Text(
                                                              widget.title,
                                                              style: TextStyle(
                                                                color: isCurrent
                                                                    ? Theme.of(
                                                                        context,
                                                                      ).colorScheme.primary
                                                                    : Theme.of(
                                                                        context,
                                                                      ).colorScheme.onSurface,
                                                                fontWeight:
                                                                    isCurrent
                                                                    ? FontWeight
                                                                          .bold
                                                                    : FontWeight
                                                                          .w400,
                                                                fontSize:
                                                                    isNarrow
                                                                    ? 14
                                                                    : 16,
                                                                decoration:
                                                                    isTitleHovered &&
                                                                        widget.onTitleTap !=
                                                                            null
                                                                    ? TextDecoration
                                                                          .underline
                                                                    : null,
                                                              ),
                                                              maxLines: 1,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                            );
                                                          },
                                                    );
                                                  },
                                                ),
                                              ),
                                            ),
                                          ),
                                          SignalBuilder(
                                            builder: (context) {
                                              // No subscriptions while the hosting tab is hidden.
                                              final isDownloading =
                                                  visibleSignal(
                                                    context,
                                                    downloadingTracksSignal,
                                                  ).contains(widget.trackId);
                                              final isDownloaded =
                                                  visibleSignal(
                                                    context,
                                                    downloadedTracksSignal,
                                                  ).contains(widget.trackId);

                                              if (!isDownloading &&
                                                  !isDownloaded) {
                                                return const SizedBox.shrink();
                                              }

                                              return Padding(
                                                padding: const EdgeInsets.only(
                                                  left: 6,
                                                ),
                                                child: isDownloading
                                                    ? M3ECircularWavyProgressIndicator(
                                                        strokeWidth: 2,
                                                        size: isNarrow
                                                            ? 12
                                                            : 14,
                                                      )
                                                    : Icon(
                                                        Icons
                                                            .download_done_rounded,
                                                        size: isNarrow
                                                            ? 14
                                                            : 16,
                                                        color: Theme.of(
                                                          context,
                                                        ).colorScheme.primary,
                                                      ),
                                              );
                                            },
                                          ),
                                          TrackVersionWidget(
                                            version: widget.version,
                                            fontSize: isNarrow ? 12 : 14,
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                      ArtistNamesWidget(
                                        artists: widget.artists,
                                        fontSize: isNarrow ? 13 : 15,
                                      ),
                                    ],
                                  ),
                                ),
                                SizedBox(width: isNarrow ? 12 : 16),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (Platform.isAndroid)
                                      IconButton(
                                        icon: Icon(
                                          Icons.more_horiz_rounded,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                        ),
                                        tooltip: 'Действия',
                                        onPressed: _showTrackBottomSheet,
                                      )
                                    else ...[
                                      if (!showHighlighted &&
                                          widget.trailing != null)
                                        widget.trailing!,
                                      if (showHighlighted) ...[
                                        if (widget.hoverActions != null)
                                          ...widget.hoverActions!,
                                        buildContextMenu(),
                                      ],
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
        );
      },
    );
  }
}

/// Badge over leading (usually the cover): visible only on the current track.
/// While playing — animated equalizer, while paused — static.
class _LeadingPlayingBadge extends StatelessWidget {
  final String trackId;
  final Widget child;

  const _LeadingPlayingBadge({required this.trackId, required this.child});

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        // No subscriptions while the hosting tab is hidden.
        final isCurrent =
            visibleSignal(context, currentTrackIdSignal) == trackId;
        if (!isCurrent) return child;
        final isPlaying = visibleSignal(context, isPlayingSignal);
        final scheme = Theme.of(context).colorScheme;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            child,
            Positioned(
              right: -6,
              bottom: -6,
              child: Tooltip(
                message: isPlaying ? 'Сейчас играет' : 'Текущий трек на паузе',
                child: Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: scheme.surface, width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: TrackPlayingIndicator(
                    isPlaying: isPlaying,
                    height: 12,
                    color: scheme.onPrimary,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
