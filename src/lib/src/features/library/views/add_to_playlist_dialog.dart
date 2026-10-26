import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/core/providers/notification_provider.dart';
import 'package:yayma/src/features/core/theme/app_tokens.dart';
import 'package:yayma/src/features/core/views/widgets/app_cover.dart';
import 'package:yayma/src/features/core/views/widgets/common_ui.dart';
import 'package:yayma/src/features/core/views/widgets/rust_cached_image.dart';
import 'package:yayma/src/features/core/views/widgets/smooth_scroll.dart';
import 'package:yayma/src/features/core/views/widgets/track_context_sheet.dart';
import 'package:yayma/src/features/library/providers/library_provider.dart';
import 'package:yayma/src/rust/api/models.dart';

class AddToPlaylistDialog extends SignalWidget {
  final SimpleTrackDto track;

  const AddToPlaylistDialog({required this.track, super.key});

  static Future<void> show(BuildContext context, SimpleTrackDto track) {
    if (Platform.isAndroid) {
      return _showSubSheet(context, track);
    }
    return showDialog(
      context: context,
      builder: (context) => AddToPlaylistDialog(track: track),
    );
  }

  /// Android: nested sheet with the list of playlists (covers, checkmarks
  /// for tracks already in the playlist, and an item to create a playlist).
  static Future<void> _showSubSheet(
    BuildContext context,
    SimpleTrackDto track,
  ) {
    final version = ValueNotifier<int>(0);
    unawaited(
      refreshTrackPlaylistMembership(track.id).then((_) => version.value++),
    );

    return showTrackSubActionSheet(
      context,
      title: 'Добавить в плейлист',
      rebuildOn: version,
      onSelected: (value) async {
        if (value == 'create_playlist') {
          final kind = await _createPlaylistAndAddTrack(context, track);
          if (kind != null) {
            showAppSuccess('Трек добавлен в плейлист');
          }
          return;
        }
        if (!value.startsWith('add_to_')) return;
        final kind = int.tryParse(value.substring(7));
        if (kind == null) return;
        final success = await addTrackToPlaylistAction(
          kind,
          track.id,
          track.albumId,
        );
        if (success) {
          showAppSuccess('Трек добавлен в плейлист');
        } else {
          showAppError('Ошибка при добавлении трека');
        }
      },
      actionsBuilder: () {
        final membershipKinds =
            trackPlaylistMembershipSignal.value[track.id] ?? const <int>{};
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
      },
    );
  }

  static Future<String?> _promptPlaylistTitle(BuildContext context) {
    return showTextPromptDialog(context, title: 'Новый плейлист');
  }

  /// Creates a private playlist and immediately adds track [track] to it.
  static Future<int?> _createPlaylistAndAddTrack(
    BuildContext context,
    SimpleTrackDto track,
  ) async {
    final trimmed = await _promptPlaylistTitle(context);
    if (trimmed == null || trimmed.isEmpty) return null;

    final existingKinds = playlistsSignal.value.map((p) => p.kind).toSet();
    final success = await createPlaylistAction(trimmed, isPublic: false);
    if (!success) {
      showAppError('Ошибка при создании плейлиста');
      return null;
    }

    final created = playlistsSignal.value
        .where((p) => !existingKinds.contains(p.kind))
        .toList();
    if (created.isEmpty) return null;

    showAppSuccess("Создан плейлист '$trimmed'");
    final added = await addTrackToPlaylistAction(
      created.first.kind,
      track.id,
      track.albumId,
    );
    if (!added) showAppError('Ошибка при добавлении трека');
    return created.first.kind;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final playlists = playlistsSignal.value;

    final dialog = AppDialog(
      title: 'Добавить в плейлист',
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
      actions: [AppDialog.closeButton(context, 'Отмена')],
    );
    return SmoothScroll(child: dialog);
  }
}
