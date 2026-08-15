import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/auth/providers/auth_provider.dart';
import 'package:yayma/src/features/core/providers/navigation_provider.dart';
import 'package:yayma/src/features/core/providers/notification_provider.dart';
import 'package:yayma/src/features/core/theme/app_tokens.dart';
import 'package:yayma/src/features/core/views/widgets/app_context_menu.dart';
import 'package:yayma/src/features/core/views/widgets/common_ui.dart';
import 'package:yayma/src/features/core/views/widgets/lyrics_view.dart';
import 'package:yayma/src/features/core/views/widgets/responsive.dart';
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
  });

  @override
  State<CommonTrackTile> createState() => _CommonTrackTileState();
}

class _CommonTrackTileState extends State<CommonTrackTile> {
  final ValueNotifier<bool> _isHovered = ValueNotifier(false);
  final ValueNotifier<bool> _isPressed = ValueNotifier(false);
  final ValueNotifier<bool> _isTitleHovered = ValueNotifier(false);
  final ValueNotifier<bool> _isMenuOpen = ValueNotifier(false);
  final GlobalKey _coverKey = GlobalKey();

  @override
  void dispose() {
    _isHovered.dispose();
    _isPressed.dispose();
    _isTitleHovered.dispose();
    _isMenuOpen.dispose();
    super.dispose();
  }

  void _handleTap() {
    if (widget.leading is TrackCover) {
      final cover = widget.leading! as TrackCover;
      flyCoverToPlayer(
        context,
        coverKey: _coverKey,
        coverUrl: cover.url,
        borderRadius: cover.isCircle ? cover.size / 2 : cover.borderRadius,
      );
    }
    widget.onTap?.call();
  }

  Widget _adjustLeading(Widget leading, bool isNarrow) {
    if (isNarrow && leading is TrackCover && leading.size == 64) {
      return TrackCover(
        url: leading.url,
        size: 48,
        borderRadius: leading.borderRadius,
        isCircle: leading.isCircle,
        canExpand: leading.canExpand,
        heroTag: leading.heroTag,
      );
    }
    return leading;
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
              final playlists = playlistsSignal.value;
              return AppContextMenu<String>(
                onOpen: () => _isMenuOpen.value = true,
                onClose: () {
                  _isMenuOpen.value = false;
                  _isHovered.value = false;
                },
                onSelected: (value) async {
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
                        showAppSuccess(
                          'Добавлено в плейлист',
                        );
                      } else {
                        showAppError(
                          'Ошибка при добавлении',
                        );
                      }
                    }
                    return;
                  }

                  switch (value) {
                    case 'go_to_album':
                      if (widget.albumId != null) {
                        navigateTo(
                          AppSection.album,
                          widget.albumId,
                        );
                      }
                    case 'lyrics':
                      LyricsReaderDialog.show(
                        context,
                        widget.trackId,
                        widget.title,
                      );
                    case 'wave':
                      unawaited(
                        PlaybackController.startTrackWave(
                          widget.trackId,
                          widget.title,
                        ),
                      );
                    case 'about':
                      TrackDetailsDialog.show(
                        context,
                        widget.trackId,
                      );
                    case 'copy_link':
                      final link = widget.albumId != null
                          ? 'https://music.yandex.ru/album/${widget.albumId}/track/${widget.trackId}'
                          : 'https://music.yandex.ru/track/${widget.trackId}';
                      await Clipboard.setData(
                        ClipboardData(text: link),
                      );
                      showAppSuccess(
                        'Ссылка скопирована',
                      );
                    case 'download':
                      showAppSuccess('Скачивание началось...');
                      final ctx = appContextSignal.value;
                      if (ctx != null) {
                        downloadingTracksSignal.value = {
                          ...downloadingTracksSignal.value,
                          widget.trackId,
                        };
                        try {
                          await rust.downloadTrack(
                            ctx: ctx,
                            trackId: widget.trackId,
                            toCache: true,
                          );
                          showAppSuccess('Трек скачан');
                          unawaited(refreshDownloadedTracks());
                        } on Object catch (e) {
                          showAppError('Ошибка: $e');
                        } finally {
                          final newSet = {...downloadingTracksSignal.value}
                            ..remove(widget.trackId);
                          downloadingTracksSignal.value = newSet;
                        }
                      }
                    case 'delete_downloaded':
                      final ctx = appContextSignal.value;
                      if (ctx != null) {
                        try {
                          await rust.deleteDownloadedTrack(
                            ctx: ctx,
                            trackId: widget.trackId,
                          );
                          showAppSuccess('Трек удален из загрузок');
                          unawaited(refreshDownloadedTracks());
                        } on Object catch (e) {
                          showAppError('Ошибка: $e');
                        }
                      }
                    case 'download_to_file':
                      showAppSuccess('Скачивание в файл началось...');
                      final ctx = appContextSignal.value;
                      if (ctx != null) {
                        downloadingTracksSignal.value = {
                          ...downloadingTracksSignal.value,
                          widget.trackId,
                        };
                        try {
                          final path = await rust.downloadTrack(
                            ctx: ctx,
                            trackId: widget.trackId,
                            toCache: false,
                          );
                          showAppSuccess('Трек сохранен: $path');
                        } on Object catch (e) {
                          showAppError('Ошибка: $e');
                        } finally {
                          final newSet = {...downloadingTracksSignal.value}
                            ..remove(widget.trackId);
                          downloadingTracksSignal.value = newSet;
                        }
                      }
                  }
                },
                items: [
                  AppContextMenuItem(
                    label: 'Добавить в плейлист',
                    icon: Icons.playlist_add_rounded,
                    subItems: playlists
                        .map(
                          (p) => AppContextMenuItem(
                            value: 'add_to_${p.kind}',
                            label: p.title,
                            icon: Icons.library_music_rounded,
                          ),
                        )
                        .toList(),
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
                  if (downloadedTracksSignal.value.contains(widget.trackId))
                    const AppContextMenuItem(
                      value: 'delete_downloaded',
                      label: 'Удалить из загрузок',
                      icon: Icons.remove_circle_outline_rounded,
                    )
                  else
                    const AppContextMenuItem(
                      value: 'download',
                      label: 'Скачать',
                      icon: Icons.download_done_rounded,
                    ),
                  const AppContextMenuItem(
                    value: 'download_to_file',
                    label: 'Скачать в файл',
                    icon: Icons.file_download_rounded,
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
                                  ? Theme.of(
                                      context,
                                    ).colorScheme.onSurface.withValues(
                                      alpha: 0.08,
                                    )
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(
                                AppRadius.sm,
                              ),
                            ),
                            child: Row(
                              children: [
                                if (widget.leading != null) ...[
                                  KeyedSubtree(
                                    key: _coverKey,
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
                                                    final currentTrackId =
                                                        currentTrackIdSignal
                                                            .value;
                                                    final isPlaying =
                                                        currentTrackId ==
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
                                                                color: isPlaying
                                                                    ? Theme.of(
                                                                        context,
                                                                      ).colorScheme.primary
                                                                    : Theme.of(
                                                                        context,
                                                                      ).colorScheme.onSurface,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .bold,
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
                                              final isDownloading =
                                                  downloadingTracksSignal.value
                                                      .contains(widget.trackId);
                                              final isDownloaded =
                                                  downloadedTracksSignal.value
                                                      .contains(widget.trackId);

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
                                      buildContextMenu()
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
