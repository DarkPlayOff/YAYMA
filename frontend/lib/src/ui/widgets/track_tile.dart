import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/providers/auth_provider.dart';
import 'package:yayma/src/providers/library_provider.dart';
import 'package:yayma/src/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/content.dart' as rust;
import 'package:yayma/src/rust/api/models.dart';
import 'package:yayma/src/ui/widgets/app_context_menu.dart';
import 'package:yayma/src/ui/widgets/lyrics_view.dart';
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
  final EdgeInsetsGeometry contentPadding;
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
    this.contentPadding = const EdgeInsets.symmetric(
      horizontal: 40,
      vertical: 8,
    ),
    this.albumId,
  });

  @override
  State<CommonTrackTile> createState() => _CommonTrackTileState();
}

class _CommonTrackTileState extends State<CommonTrackTile> {
  bool _isHovered = false;
  bool _isTitleHovered = false;
  bool _isMenuOpen = false;

  @override
  Widget build(BuildContext context) {
    final showHighlighted = _isHovered || _isMenuOpen;

    return Watch((context) {
      final currentTrackId = currentTrackIdSignal.watch(context);
      final isPlaying = currentTrackId == widget.trackId;

      return MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(12),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: widget.contentPadding,
              decoration: BoxDecoration(
                color: showHighlighted
                    ? Colors.white.withValues(alpha: 0.05)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  if (widget.leading != null) ...[
                    widget.leading!,
                    const SizedBox(width: 16),
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
                                    setState(() => _isTitleHovered = true),
                                onExit: (_) =>
                                    setState(() => _isTitleHovered = false),
                                cursor: widget.onTitleTap != null
                                    ? SystemMouseCursors.click
                                    : SystemMouseCursors.basic,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: widget.onTitleTap,
                                  child: Text(
                                    widget.title,
                                    style: TextStyle(
                                      color: isPlaying
                                          ? Theme.of(
                                              context,
                                            ).colorScheme.primary
                                          : Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                      decoration:
                                          _isTitleHovered &&
                                              widget.onTitleTap != null
                                          ? TextDecoration.underline
                                          : null,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            ),
                            TrackVersionWidget(version: widget.version),
                          ],
                        ),
                        const SizedBox(height: 4),
                        ArtistNamesWidget(
                          artists: widget.artists,
                          fontSize: 15,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!showHighlighted && widget.trailing != null)
                        widget.trailing!,
                      if (showHighlighted) ...[
                        if (widget.hoverActions != null)
                          ...widget.hoverActions!,
                        Watch((watchContext) {
                          final playlists = playlistsSignal.watch(watchContext);
                          return AppContextMenu<String>(
                            onOpen: () => setState(() => _isMenuOpen = true),
                            onClose: () => setState(() => _isMenuOpen = false),
                            onSelected: (value) async {
                              if (!mounted) return;

                              // Store the messenger from a stable component context
                              final messenger = ScaffoldMessenger.of(context);

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
                                  messenger.showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        success
                                            ? 'Добавлено в плейлист'
                                            : 'Ошибка при добавлении',
                                      ),
                                      backgroundColor: success
                                          ? Colors.green
                                          : Colors.red,
                                    ),
                                  );
                                }
                                return;
                              }

                              switch (value) {
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
                                  await Clipboard.setData(ClipboardData(text: link));
                                  if (mounted) {
                                    messenger.showSnackBar(
                                      const SnackBar(content: Text('Ссылка скопирована')),
                                    );
                                  }
                                case 'download':
                                  messenger.showSnackBar(
                                    const SnackBar(
                                      content: Text('Скачивание началось...'),
                                    ),
                                  );
                                  final ctx = appContextSignal.value;
                                  if (ctx != null) {
                                    try {
                                      final path = await rust.downloadTrack(
                                        ctx: ctx,
                                        trackId: widget.trackId,
                                      );
                                      messenger.showSnackBar(
                                        SnackBar(
                                          content: Text('Трек сохранен: $path'),
                                        ),
                                      );
                                    } on Object catch (e) {
                                      messenger.showSnackBar(
                                        SnackBar(content: Text('Ошибка: $e')),
                                      );
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
            ),
          ),
        ),
      );
    });
  }
}
