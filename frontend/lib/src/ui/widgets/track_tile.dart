import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/providers/auth_provider.dart';
import 'package:yayma/src/providers/library_provider.dart';
import 'package:yayma/src/providers/navigation_provider.dart';
import 'package:yayma/src/providers/notification_provider.dart';
import 'package:yayma/src/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/content.dart' as rust;
import 'package:yayma/src/rust/api/models.dart';
import 'package:yayma/src/ui/widgets/app_context_menu.dart';
import 'package:yayma/src/ui/widgets/lyrics_view.dart';
import 'package:yayma/src/ui/widgets/responsive.dart';
import 'package:yayma/src/ui/widgets/track_details_dialog.dart';
import 'package:yayma/src/ui/widgets/track_elements.dart';

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
  final ValueNotifier<bool> _isTitleHovered = ValueNotifier(false);
  final ValueNotifier<bool> _isMenuOpen = ValueNotifier(false);

  @override
  void dispose() {
    _isHovered.dispose();
    _isTitleHovered.dispose();
    _isMenuOpen.dispose();
    super.dispose();
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
    final isNarrow = context.isNarrow;

    final effectivePadding =
        widget.contentPadding ??
        EdgeInsets.symmetric(
          horizontal: context.horizontalPadding,
          vertical: isNarrow ? 4 : 8,
        );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.onTap,
        onHover: (value) => _isHovered.value = value,
        hoverColor: Colors.transparent,
        focusColor: Colors.transparent,
        highlightColor: Colors.transparent,
        splashColor: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: ValueListenableBuilder<bool>(
            valueListenable: _isHovered,
            builder: (context, isHovered, child) {
              return ValueListenableBuilder<bool>(
                valueListenable: _isMenuOpen,
                builder: (context, isMenuOpen, child) {
                  final showHighlighted = isHovered || isMenuOpen;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: effectivePadding,
                    decoration: BoxDecoration(
                      color: showHighlighted
                          ? Colors.white.withValues(alpha: 0.05)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        if (widget.leading != null) ...[
                          _adjustLeading(widget.leading!, isNarrow),
                          SizedBox(width: isNarrow ? 12 : 16),
                        ],
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
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
                                        behavior: HitTestBehavior.opaque,
                                        onTap: widget.onTitleTap,
                                        child: Watch((context) {
                                          final currentTrackId =
                                              currentTrackIdSignal.watch(
                                                context,
                                              );
                                          final isPlaying =
                                              currentTrackId == widget.trackId;

                                          return ValueListenableBuilder<bool>(
                                            valueListenable: _isTitleHovered,
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
                                                          ? Theme.of(context)
                                                                .colorScheme
                                                                .primary
                                                          : Colors.white,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      fontSize: isNarrow
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
                                                        TextOverflow.ellipsis,
                                                  );
                                                },
                                          );
                                        }),
                                      ),
                                    ),
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
                            if (!showHighlighted && widget.trailing != null)
                              widget.trailing!,
                            if (showHighlighted) ...[
                              if (widget.hoverActions != null)
                                ...widget.hoverActions!,
                              Watch((watchContext) {
                                final playlists = playlistsSignal.watch(
                                  watchContext,
                                );
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
                                        final success =
                                            await addTrackToPlaylistAction(
                                              kind,
                                              widget.trackId,
                                              widget.albumId,
                                            );
                                        if (success) {
                                          showAppSuccess(
                                            'Добавлено в плейлист',
                                          );
                                        } else {
                                          showAppError('Ошибка при добавлении');
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
                                        showAppSuccess('Ссылка скопирована');
                                      case 'download':
                                        showAppSuccess(
                                          'Скачивание началось...',
                                        );
                                        final ctx = appContextSignal.value;
                                        if (ctx != null) {
                                          try {
                                            final path = await rust
                                                .downloadTrack(
                                                  ctx: ctx,
                                                  trackId: widget.trackId,
                                                );
                                            showAppSuccess(
                                              'Трек сохранен: $path',
                                            );
                                          } on Object catch (e) {
                                            showAppError('Ошибка: $e');
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
                                    const AppContextMenuItem(
                                      value: 'download',
                                      label: 'Скачать',
                                      icon: Icons.download_rounded,
                                    ),
                                  ],
                                  child: const IconButton(
                                    icon: Icon(
                                      Icons.more_horiz_rounded,
                                      color: Colors.white70,
                                    ),
                                    onPressed: null,
                                    tooltip: 'Действия',
                                  ),
                                );
                              }),
                            ],
                          ],
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
      ),
    );
  }
}
