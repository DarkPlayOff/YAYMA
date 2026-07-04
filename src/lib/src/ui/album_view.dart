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
import 'package:yayma/src/ui/widgets/common_ui.dart';
import 'package:yayma/src/ui/widgets/track_tile.dart';

class AlbumView extends StatefulWidget {
  final String? albumId;
  const AlbumView({super.key, this.albumId});

  @override
  State<AlbumView> createState() => _AlbumViewState();
}

class _AlbumViewState extends State<AlbumView> {
  late final FutureSignal<AlbumDetailsDto?> _albumAsync;
  final FlutterSignal<bool> _isDownloadingAlbum = signal(false);

  @override
  void initState() {
    super.initState();
    final idStr = widget.albumId;
    _albumAsync = futureSignal(() async {
      if (idStr == null) return null;
      final id = int.tryParse(idStr);
      if (id == null) return null;
      final ctx = appContextSignal.value;
      if (ctx == null) return null;
      return rust.getAlbumDetails(albumId: id, ctx: ctx);
    });
    unawaited(refreshLikedAlbums());
  }

  Future<void> _toggleAlbumLike(AlbumDetailsDto album, bool isLiked) async {
    final success = isLiked
        ? await removeLikedAlbumAction(album.id)
        : await addLikedAlbumAction(album.id);

    if (!mounted) return;
    if (success) {
      final current = likedAlbumsSignal.value;
      if (isLiked) {
        likedAlbumsSignal.value = current
            .where((a) => a.id != album.id)
            .toList();
      } else if (!current.any((a) => a.id == album.id)) {
        likedAlbumsSignal.value = [
          SimpleAlbumDto(
            id: album.id,
            title: album.title,
            artists: album.artists,
            year: album.year,
            coverUrl: album.coverUrl,
          ),
          ...current,
        ];
      }

      showAppSuccess(
        isLiked ? 'Альбом удалён из любимых' : 'Альбом добавлен в любимые',
      );
    } else {
      showAppError('Ошибка при обновлении любимых альбомов');
    }
  }

  Future<void> _copyAlbumLink(AlbumDetailsDto album) async {
    await Clipboard.setData(
      ClipboardData(text: 'https://music.yandex.ru/album/${album.id}'),
    );
    showAppSuccess('Ссылка скопирована');
  }

  Future<void> _downloadAlbum(AlbumDetailsDto album) async {
    if (_isDownloadingAlbum.value) return;

    final ctx = appContextSignal.value;
    if (ctx == null) return;

    _isDownloadingAlbum.value = true;
    showAppSuccess('Скачивание альбома началось...');

    try {
      final trackIds = album.tracks
          .where((t) => !downloadedTracksSignal.value.contains(t.id))
          .map((t) => t.id)
          .toList();

      if (trackIds.isNotEmpty) {
        await rust.downloadTracksBatch(ctx: ctx, trackIds: trackIds);
        unawaited(refreshDownloadedTracks());
      }
      
      if (!mounted) return;
      showAppSuccess('Альбом сохранён');
    } on Object catch (e) {
      if (!mounted) return;
      showAppError('Ошибка при скачивании: $e');
    } finally {
      _isDownloadingAlbum.value = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.albumId == null) {
      return const Center(child: Text('Альбом не выбран'));
    }

    return SignalBuilder(
      builder: (context) {
        return CommonAsyncView<AlbumDetailsDto?>(
          state: _albumAsync.value,
          isEmpty: (album) => album == null,
          empty: const Center(child: Text('Альбом не найден')),
          builder: (context, album) {
            final albumData = album!;
            return SignalBuilder(
              builder: (context) {
                final isLiked = likedAlbumsSignal.value.any(
                  (likedAlbum) => likedAlbum.id == albumData.id,
                );
                final isDownloading = _isDownloadingAlbum.value;

                return CommonDetailSliverLayout(
                  header: CommonDetailHeader(
                    type: 'Альбом',
                    title: albumData.title,
                    artists: albumData.artists,
                    secondarySubtitle: albumData.year?.toString(),
                    coverUrl: albumData.coverUrl,
                    actions: [
                      ElevatedButton.icon(
                        onPressed: () => unawaited(
                          _toggleAlbumLike(albumData, isLiked),
                        ),
                        icon: Icon(
                          isLiked
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                        ),
                        label: Text(isLiked ? 'В любимых' : 'В любимые'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: isLiked
                              ? Theme.of(context).colorScheme.primary
                              : Colors.white.withValues(alpha: 0.1),
                          foregroundColor: isLiked
                              ? Colors.black
                              : Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 14,
                          ),
                        ),
                      ),
                      ElevatedButton.icon(
                        onPressed: () => unawaited(_copyAlbumLink(albumData)),
                        icon: const Icon(Icons.link_rounded),
                        label: const Text('Ссылка'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white.withValues(alpha: 0.1),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 14,
                          ),
                        ),
                      ),
                      ElevatedButton.icon(
                        onPressed: isDownloading
                            ? null
                            : () => unawaited(_downloadAlbum(albumData)),
                        icon: isDownloading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.download_rounded),
                        label: const Text('Скачать альбом'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white.withValues(alpha: 0.1),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 14,
                          ),
                        ),
                      ),
                    ],
                  ),
                  slivers: [
                    SliverFixedExtentList(
                      itemExtent: 84,
                      delegate: SliverChildBuilderDelegate((context, index) {
                        final track = albumData.tracks[index];
                        return CommonTrackTile(
                          trackId: track.id,
                          title: track.title,
                          version: track.version,
                          artists: track.artists,
                          albumId: albumData.id,
                          leading: SizedBox(
                            width: 32,
                            child: Center(
                              child: Text(
                                '${index + 1}',
                                style: const TextStyle(
                                  color: Colors.white38,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                          ),
                          trailing: Text(
                            formatDuration(track.durationMs),
                            style: const TextStyle(color: Colors.white38),
                          ),
                          hoverActions: [
                            IconButton(
                              icon: Icon(
                                Icons.play_arrow_rounded,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              onPressed: () =>
                                  PlaybackController.playAlbumTrack(
                                    int.parse(albumData.id),
                                    track.id,
                                  ),
                            ),
                          ],
                          onTap: () => PlaybackController.playAlbumTrack(
                            int.parse(albumData.id),
                            track.id,
                          ),
                          onTitleTap: () =>
                              navigateTo(AppSection.album, albumData.id),
                        );
                      }, childCount: albumData.tracks.length),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }
}
