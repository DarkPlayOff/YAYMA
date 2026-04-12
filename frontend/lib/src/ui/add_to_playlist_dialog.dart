import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/providers/library_provider.dart';
import 'package:yayma/src/rust/api/models.dart';
import 'package:yayma/src/ui/widgets/rust_cached_image.dart';

class AddToPlaylistDialog extends StatelessWidget {
  final SimpleTrackDto track;

  const AddToPlaylistDialog({required this.track, super.key});

  static Future<void> show(BuildContext context, SimpleTrackDto track) {
    return showDialog(
      context: context,
      builder: (context) => AddToPlaylistDialog(track: track),
    );
  }

  @override
  Widget build(BuildContext context) {
    final playlists = playlistsSignal.watch(context);

    return AlertDialog(
      backgroundColor: const Color(0xFF1E1E1E),
      title: const Text(
        'Добавить в плейлист',
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ),
      content: SizedBox(
        width: 400,
        height: 500,
        child: playlists.isEmpty
            ? const Center(
                child: Text(
                  'У вас пока нет плейлистов',
                  style: TextStyle(color: Colors.white54),
                ),
              )
            : ListView.builder(
                itemCount: playlists.length,
                itemBuilder: (context, index) {
                  final playlist = playlists[index];
                  return ListTile(
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: playlist.coverUrl != null
                          ? RustCachedImage(
                              imageUrl: playlist.coverUrl,
                              width: 48,
                              height: 48,
                              errorWidget: Container(
                                width: 48,
                                height: 48,
                                color: Colors.white10,
                                child: const Icon(
                                  Icons.library_music_rounded,
                                  color: Colors.white24,
                                ),
                              ),
                            )
                          : Container(
                              width: 48,
                              height: 48,
                              color: Colors.white10,
                              child: const Icon(
                                Icons.library_music_rounded,
                                color: Colors.white24,
                              ),
                            ),
                    ),
                    title: Text(
                      playlist.title,
                      style: const TextStyle(color: Colors.white),
                    ),
                    onTap: () async {
                      final success = await addTrackToPlaylistAction(
                        playlist.kind,
                        track.id,
                        track.albumId,
                      );

                      if (context.mounted) {
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              success
                                  ? "Трек добавлен в '${playlist.title}'"
                                  : 'Ошибка при добавлении трека',
                            ),
                            backgroundColor: success
                                ? Colors.green
                                : Colors.red,
                          ),
                        );
                      }
                    },
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена', style: TextStyle(color: Colors.white54)),
        ),
      ],
    );
  }
}
