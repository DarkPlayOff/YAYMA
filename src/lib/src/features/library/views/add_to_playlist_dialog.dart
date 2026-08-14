import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/core/providers/notification_provider.dart';
import 'package:yayma/src/features/core/theme/app_tokens.dart';
import 'package:yayma/src/features/core/views/widgets/rust_cached_image.dart';
import 'package:yayma/src/features/library/providers/library_provider.dart';
import 'package:yayma/src/rust/api/models.dart';

class AddToPlaylistDialog extends SignalWidget {
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
    final cs = Theme.of(context).colorScheme;
    final playlists = playlistsSignal.value;

    return AlertDialog(
      title: Text(
        'Добавить в плейлист',
        style: TextStyle(
          color: cs.onSurface,
          fontWeight: FontWeight.bold,
        ),
      ),
      content: SizedBox(
        width: 400,
        height: 500,
        child: playlists.isEmpty
            ? Center(
                child: Text(
                  'У вас пока нет плейлистов',
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
              )
            : ListView.builder(
                itemCount: playlists.length,
                itemBuilder: (context, index) {
                  final playlist = playlists[index];
                  return ListTile(
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.xs),
                      child: playlist.coverUrl != null
                          ? RustCachedImage(
                              imageUrl: playlist.coverUrl,
                              width: 48,
                              height: 48,
                              errorWidget: Container(
                                width: 48,
                                height: 48,
                                color: cs.onSurface.withValues(alpha: 0.1),
                                child: Icon(
                                  Icons.library_music_rounded,
                                  color: cs.onSurface.withValues(alpha: 0.24),
                                ),
                              ),
                            )
                          : Container(
                              width: 48,
                              height: 48,
                              color: cs.onSurface.withValues(alpha: 0.1),
                              child: Icon(
                                Icons.library_music_rounded,
                                color: cs.onSurface.withValues(alpha: 0.24),
                              ),
                            ),
                    ),
                    title: Text(
                      playlist.title,
                      style: TextStyle(color: cs.onSurface),
                    ),
                    onTap: () async {
                      final success = await addTrackToPlaylistAction(
                        playlist.kind,
                        track.id,
                        track.albumId,
                      );

                      if (context.mounted) {
                        Navigator.pop(context);
                        if (success) {
                          showAppSuccess("Трек добавлен в '${playlist.title}'");
                        } else {
                          showAppError('Ошибка при добавлении трека');
                        }
                      }
                    },
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            'Отмена',
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
