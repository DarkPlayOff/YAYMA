import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/providers/auth_provider.dart';
import 'package:yayma/src/providers/navigation_provider.dart';
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
  }

  @override
  Widget build(BuildContext context) {
    if (widget.albumId == null) {
      return const Center(child: Text('Альбом не выбран'));
    }

    return Watch((context) {
      return CommonAsyncView<AlbumDetailsDto?>(
        state: _albumAsync.value,
        isEmpty: (album) => album == null,
        empty: const Center(child: Text('Альбом не найден')),
        builder: (context, album) {
          return CommonDetailSliverLayout(
            header: CommonDetailHeader(
              type: 'Альбом',
              title: album!.title,
              artists: album.artists,
              secondarySubtitle: album.year?.toString(),
              coverUrl: album.coverUrl,
            ),
            slivers: [
              SliverFixedExtentList(
                itemExtent: 84,
                delegate: SliverChildBuilderDelegate((context, index) {
                  final track = album.tracks[index];
                  return CommonTrackTile(
                    trackId: track.id,
                    title: track.title,
                    version: track.version,
                    artists: track.artists,
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
                        onPressed: () => PlaybackController.playAlbumTrack(
                          int.parse(album.id),
                          track.id,
                        ),
                      ),
                    ],
                    onTap: () => PlaybackController.playAlbumTrack(
                      int.parse(album.id),
                      track.id,
                    ),
                    onTitleTap: () => navigateTo(AppSection.album, album.id),
                  );
                }, childCount: album.tracks.length),
              ),
            ],
          );
        },
      );
    });
  }
}
