import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/providers/auth_provider.dart';
import 'package:yayma/src/providers/library_provider.dart';
import 'package:yayma/src/providers/navigation_provider.dart';
import 'package:yayma/src/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/content.dart' as rust;
import 'package:yayma/src/rust/api/models.dart';
import 'package:yayma/src/ui/widgets/app_context_menu.dart';
import 'package:yayma/src/ui/widgets/common_ui.dart';
import 'package:yayma/src/ui/widgets/track_elements.dart';
import 'package:yayma/src/ui/widgets/track_tile.dart';

class PlaylistView extends StatefulWidget {
  final String? uid;
  final String? kind;
  const PlaylistView({super.key, this.uid, this.kind});

  @override
  State<PlaylistView> createState() => _PlaylistViewState();
}

class _PlaylistViewState extends State<PlaylistView> {
  late final FutureSignal<PlaylistDetailsDto?> _playlistAsync;
  // Сигнал для хранения метаданных (заголовок), чтобы они не исчезали при поиске
  final FlutterSignal<PlaylistDetailsDto?> _playlistMetadata = signal<PlaylistDetailsDto?>(null);
  final FlutterSignal<String> _searchQuery = signal('');
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final uStr = widget.uid;
    final kStr = widget.kind;

    _playlistAsync = futureSignal(() async {
      if (uStr == null || kStr == null) return null;
      final u = int.tryParse(uStr);
      final k = int.tryParse(kStr);
      if (u == null || k == null) return null;
      final ctx = appContextSignal.value;
      if (ctx == null) return null;

      final query = _searchQuery.value;
      if (query.isNotEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }

      final result = await rust.getPlaylistDetails(
        ctx: ctx,
        uid: u,
        kind: k,
        query: query.isEmpty ? null : query,
      );

      // Сохраняем метаданные, если загрузка успешна
      if (result != null) {
        _playlistMetadata.value = result;
      }

      return result;
    });

    _searchController.addListener(() {
      _searchQuery.value = _searchController.text;
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.uid == null || widget.kind == null) {
      return const Center(child: Text('Плейлист не выбран'));
    }

    return Watch((context) {
      final meta = _playlistMetadata.value;
      final state = _playlistAsync.value;

      // Показываем полный лоадер только если у нас ВООБЩЕ еще нет никаких данных
      if (meta == null && state.isLoading) {
        return const Center(child: CommonLoadingWidget());
      }

      if (state.hasError && meta == null) {
        return Center(child: CommonErrorWidget(error: state.error.toString()));
      }

      if (meta == null) {
        return const Center(child: Text('Плейлист не найден'));
      }

      return _PlaylistContent(
        playlist: meta,
        tracks: state.value?.tracks ?? [],
        isLoading: state.isLoading,
        refresh: () => _playlistAsync.refresh(),
        searchController: _searchController,
      );
    });
  }
}

class _PlaylistContent extends StatefulWidget {
  final PlaylistDetailsDto playlist;
  final List<SimpleTrackDto> tracks;
  final bool isLoading;
  final VoidCallback refresh;
  final TextEditingController searchController;

  const _PlaylistContent({
    required this.playlist,
    required this.tracks,
    required this.isLoading,
    required this.refresh,
    required this.searchController,
  });

  @override
  State<_PlaylistContent> createState() => _PlaylistContentState();
}

class _PlaylistContentState extends State<_PlaylistContent> {
  // Список треков для локальных манипуляций (reorder)
  late List<SimpleTrackDto> _localTracks;

  @override
  void initState() {
    super.initState();
    _localTracks = List.from(widget.tracks);
  }

  @override
  void didUpdateWidget(_PlaylistContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Обновляем локальный список только когда пришли новые данные
    if (widget.tracks != oldWidget.tracks) {
      _localTracks = List.from(widget.tracks);
    }
  }

  Future<void> _handleUpload(BuildContext context) async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp3', 'flac'],
    );

    if (result == null || result.files.single.path == null) return;

    final filePath = result.files.single.path!;
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Загрузка трека началась...')),
      );
    }

    final success = await uploadTrackAction(
      filePath,
      playlistKind: widget.playlist.kind,
    );

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success ? 'Трек успешно загружен' : 'Ошибка при загрузке трека',
          ),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
      if (success) {
        widget.refresh();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final searchActive = widget.searchController.text.isNotEmpty;

    return CommonDetailSliverLayout(
      header: CommonDetailHeader(
        type: 'Плейлист',
        title: widget.playlist.title,
        coverUrl: widget.playlist.coverUrl,
        actions: [
          ElevatedButton.icon(
            onPressed: () => PlaybackController.playPlaylist(
              widget.playlist.uid.toString(),
              widget.playlist.kind,
            ),
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Слушать'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            ),
          ),
          const SizedBox(width: 12),
          AppContextMenu<String>(
            onSelected: (value) async {
              switch (value) {
                case 'rename':
                  await _showRenameDialog(context, widget.playlist);
                case 'visibility':
                  await setPlaylistVisibilityAction(
                    widget.playlist.kind,
                    isPublic: !widget.playlist.isPublic,
                  );
                  widget.refresh();
                case 'delete':
                  await _showDeleteConfirm(context, widget.playlist);
              }
            },
            items: [
              const AppContextMenuItem(
                value: 'rename',
                label: 'Переименовать',
                icon: Icons.edit_rounded,
              ),
              AppContextMenuItem(
                value: 'visibility',
                label: widget.playlist.isPublic
                    ? 'Сделать приватным'
                    : 'Сделать публичным',
                icon: widget.playlist.isPublic
                    ? Icons.lock_outline_rounded
                    : Icons.public_rounded,
              ),
              const AppContextMenuItem(
                value: 'delete',
                label: 'Удалить плейлист',
                icon: Icons.delete_forever_rounded,
                color: Colors.redAccent,
              ),
            ],
            child: const IconButton(
              icon: Icon(
                Icons.more_horiz_rounded,
                color: Colors.white54,
                size: 32,
              ),
              onPressed: null,
              tooltip: 'Опции плейлиста',
            ),
          ),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: () => _handleUpload(context),
            icon: const Icon(Icons.upload_rounded),
            label: const Text('Загрузить трек'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: 0.1),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            ),
          ),
        ],
      ),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(40, 0, 40, 16),
            child: TextField(
              controller: widget.searchController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Поиск в плейлисте...',
                hintStyle: const TextStyle(color: Colors.white24),
                prefixIcon: const Icon(Icons.search, color: Colors.white38),
                suffixIcon:
                    widget.searchController.text.isNotEmpty
                        ? IconButton(
                          icon: const Icon(Icons.clear, color: Colors.white38),
                          onPressed: () {
                            widget.searchController.clear();
                          },
                        )
                        : null,
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.05),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
            ),
          ),
        ),
        if (widget.isLoading)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CommonLoadingWidget()),
          )
        else if (_localTracks.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Text(
                'Ничего не найдено',
                style: TextStyle(color: Colors.white38),
              ),
            ),
          )
        else if (searchActive)
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final track = _localTracks[index];
                return _TrackTile(
                  track: track,
                  index: index,
                  playlist: widget.playlist,
                  onRemove: () async {
                    final success = await removeTrackFromPlaylistAction(
                      widget.playlist.kind,
                      track.id,
                      track.albumId,
                    );
                    if (success) widget.refresh();
                  },
                );
              },
              childCount: _localTracks.length,
            ),
          )
        else
          SliverReorderableList(
            itemBuilder: (context, index) {
              final track = _localTracks[index];
              return ReorderableDragStartListener(
                key: ValueKey('${track.id}_$index'),
                index: index,
                child: _TrackTile(
                  track: track,
                  index: index,
                  playlist: widget.playlist,
                  onRemove: () async {
                    final success = await removeTrackFromPlaylistAction(
                      widget.playlist.kind,
                      track.id,
                      track.albumId,
                    );
                    if (success) widget.refresh();
                  },
                ),
              );
            },
            itemCount: _localTracks.length,
            onReorder: (oldIndex, originalNewIndex) async {
              var newIndex = originalNewIndex;
              setState(() {
                if (newIndex > oldIndex) newIndex -= 1;
                final item = _localTracks.removeAt(oldIndex);
                _localTracks.insert(newIndex, item);
              });

              final track = _localTracks[newIndex];
              final success = await moveTrackInPlaylistAction(
                widget.playlist.kind,
                oldIndex,
                newIndex,
                track.id,
                track.albumId,
              );

              if (!success) {
                widget.refresh();
              }
            },
          ),
      ],
    );
  }

  Future<void> _showRenameDialog(BuildContext context, PlaylistDetailsDto playlist) async {
    final controller = TextEditingController(text: playlist.title);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text(
          'Переименовать плейлист',
          style: TextStyle(color: Colors.white),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            filled: true,
            fillColor: Colors.white.withValues(alpha: 0.05),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (controller.text.isNotEmpty) {
                await renamePlaylistAction(playlist.kind, controller.text);
                widget.refresh();
                if (context.mounted) Navigator.pop(context);
              }
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
  }

  Future<void> _showDeleteConfirm(BuildContext context, PlaylistDetailsDto playlist) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text(
          'Удалить плейлист?',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          "Вы уверены, что хотите удалить '${playlist.title}'? Это действие нельзя отменить.",
          style: const TextStyle(color: Colors.white54),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () async {
              await deletePlaylistAction(playlist.kind);
              if (context.mounted) {
                Navigator.pop(context);
                setSection(AppSection.liked);
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
  }
}

class _TrackTile extends StatelessWidget {
  final SimpleTrackDto track;
  final int index;
  final PlaylistDetailsDto playlist;
  final VoidCallback onRemove;

  const _TrackTile({
    required this.track,
    required this.index,
    required this.playlist,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return CommonTrackTile(
      trackId: track.id,
      title: track.title,
      version: track.version,
      artists: track.artists,
      leading: SizedBox(
        width: 100,
        child: Row(
          children: [
            const Icon(
              Icons.drag_indicator_rounded,
              color: Colors.white38,
              size: 20,
            ),
            const SizedBox(width: 8),
            Text(
              '${index + 1}',
              style: const TextStyle(color: Colors.white38, fontSize: 14),
            ),
            const Spacer(),
            TrackCover(url: track.coverUrl, size: 48, borderRadius: 4),
          ],
        ),
      ),
      trailing: Text(
        formatDuration(track.durationMs),
        style: const TextStyle(color: Colors.white38),
      ),
      hoverActions: [
        IconButton(
          icon: const Icon(Icons.play_arrow_rounded, color: Colors.white54),
          onPressed: () => PlaybackController.playPlaylistTrack(
            playlist.uid.toString(),
            playlist.kind,
            track.id,
          ),
        ),
        IconButton(
          icon: const Icon(Icons.playlist_remove_rounded, color: Colors.redAccent),
          onPressed: onRemove,
          tooltip: 'Удалить из плейлиста',
        ),
      ],
      onTap: () => PlaybackController.playPlaylistTrack(
        playlist.uid.toString(),
        playlist.kind,
        track.id,
      ),
      onTitleTap: () {
        if (track.albumId != null) {
          navigateTo(AppSection.album, track.albumId);
        }
      },
    );
  }
}
