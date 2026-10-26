import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/app/session.dart';
import 'package:yayma/src/features/core/providers/navigation_provider.dart';
import 'package:yayma/src/features/core/providers/notification_provider.dart';
import 'package:yayma/src/features/core/services/rust_bridge.dart';
import 'package:yayma/src/features/core/views/widgets/app_cover.dart';
import 'package:yayma/src/features/core/views/widgets/audio_quality_sheet.dart';
import 'package:yayma/src/features/core/views/widgets/download_menu.dart';
import 'package:yayma/src/features/core/views/widgets/lyrics_view.dart';
import 'package:yayma/src/features/core/views/widgets/track_context_sheet.dart';
import 'package:yayma/src/features/core/views/widgets/track_details_dialog.dart';
import 'package:yayma/src/features/library/providers/library_provider.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/content.dart' as rust;
import 'package:yayma/src/rust/api/library.dart' as rust_library;
import 'package:yayma/src/rust/api/models.dart';

/// Bumped when playlist membership is refreshed, so an open "add to
/// playlist" sub-sheet redraws with fresh checkmarks. A single instance is
/// enough because the sheets are modal and only one can be open at a time.
final ValueNotifier<int> _membershipVersion = ValueNotifier(0);

/// Track actions shared by library tiles and the full player, so both show
/// the same context menu.
class TrackContextActions {
  final String trackId;
  final String title;
  final String? version;
  final List<TrackArtistDto> artists;
  final String? albumId;
  final String? coverUrl;
  final Uri? localCoverUri;

  const TrackContextActions({
    required this.trackId,
    required this.title,
    required this.artists,
    this.version,
    this.albumId,
    this.coverUrl,
    this.localCoverUri,
  });

  /// Opens the bottom action sheet for this track.
  Future<void> showSheet(BuildContext context) async {
    final downloaded = downloadedTracksSignal.value;

    Future<void> refreshMembership() {
      // Refresh the cache in the background; increment the version on
      // completion so the open sub-sheet redraws with up-to-date checkmarks.
      return refreshTrackPlaylistMembership(trackId).then((_) {
        if (context.mounted) _membershipVersion.value++;
      });
    }

    List<TrackSheetAction> buildPlaylistSubActions() {
      final membershipKinds =
          trackPlaylistMembershipSignal.value[trackId] ?? const <int>{};
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

    final initialLiked = await runRustFetch(
      (ctx) => rust_library.trackIsLiked(ctx: ctx, trackId: trackId),
    );
    final initialDisliked =
        await runRustFetch(
          (ctx) => rust_library.trackIsDisliked(ctx: ctx, trackId: trackId),
        ) ??
        false;
    if (!context.mounted) return;
    final likedOverride = signal<bool?>(initialLiked);

    await showTrackContextSheet(
      context,
      header: TrackContextSheetHeader(
        title: title,
        version: version,
        artists: artists,
        coverUrl: coverUrl,
        localCoverUri: localCoverUri,
      ),
      subSheetRebuildOn: _membershipVersion,
      onSelected: (value) {
        if (value == 'like') {
          likedOverride.value = !(likedOverride.value ?? false);
          unawaited(
            handle(context, value).then((_) async {
              final liked = await runRustFetch(
                (ctx) => rust_library.trackIsLiked(ctx: ctx, trackId: trackId),
              );
              if (liked != null) likedOverride.value = liked;
            }),
          );
          return;
        }
        unawaited(handle(context, value));
      },
      quickActions: () {
        // Rust is the only owner of the liked state; the override starts from
        // the value fetched on open and is re-read after every toggle.
        final isLiked = likedOverride.value ?? false;
        return [
          TrackSheetAction(
            label: 'В плейлист',
            icon: Icons.playlist_add_rounded,
            subSheetTitle: 'Добавить в плейлист',
            onSubSheetOpen: refreshMembership,
            subActions: buildPlaylistSubActions,
          ),
          TrackSheetAction(
            value: 'like',
            label: isLiked ? 'В любимых' : 'Нравится',
            icon: isLiked
                ? Icons.favorite_rounded
                : Icons.favorite_border_rounded,
            isSelected: isLiked,
            keepOpen: true,
          ),
          const TrackSheetAction(
            label: 'Скачать',
            icon: Icons.download_rounded,
            subSheetTitle: 'Скачать',
            subActions: _downloadSubActionsGetter,
          ),
          const TrackSheetAction(
            value: 'wave',
            label: 'Моя волна',
            icon: Icons.waves_rounded,
          ),
        ];
      },
      actions: [
        TrackSheetAction(
          value: 'dislike',
          label: initialDisliked ? 'Убрать дизлайк' : 'Не нравится',
          icon: initialDisliked
              ? Icons.heart_broken_rounded
              : Icons.heart_broken_outlined,
        ),
        if (albumId != null)
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
          value: 'about',
          label: 'О треке',
          icon: Icons.info_outline_rounded,
        ),
        const TrackSheetAction(
          value: 'audio_settings',
          label: 'Настройки звука',
          icon: Icons.tune_rounded,
        ),
        if (downloaded.contains(trackId))
          const TrackSheetAction(
            value: 'delete_downloaded',
            label: 'Удалить из загрузок',
            icon: Icons.remove_circle_outline_rounded,
            color: Color(0xFFE57373),
          ),
      ],
    );
    // Not disposed: the dismissed sheet's SignalBuilder may still rebuild
    // right after the pop. Without listeners the signal is just GC'd.
  }

  Future<void> handle(BuildContext context, String value) async {
    if (!context.mounted) return;

    if (value.startsWith('add_to_')) {
      final kindStr = value.substring(7);
      final kind = int.tryParse(kindStr);
      if (kind != null) {
        final success = await addTrackToPlaylistAction(kind, trackId, albumId);
        if (success) {
          showAppSuccess('Добавлено в плейлист');
        } else {
          showAppError('Ошибка при добавлении');
        }
      }
      return;
    }

    switch (value) {
      case 'like':
        await PlaybackController.toggleLike(trackId: trackId);
      case 'dislike':
        await PlaybackController.toggleDislike(trackId: trackId);
        // The disliked list is a snapshot, not a stream: refresh it so the
        // library tab reflects the change without a manual pull.
        unawaited(refreshDislikedTracks());
      case 'go_to_album':
        if (albumId != null) {
          navigateTo(AppSection.album, albumId);
        }
      case 'lyrics':
        LyricsReaderDialog.show(context, trackId, title);
      case 'wave':
        unawaited(PlaybackController.startTrackWave(trackId, title));
      case 'create_playlist':
        await _createPlaylistAndAddTrack(context);
      case 'about':
        TrackDetailsDialog.show(context, trackId);
      case 'audio_settings':
        await showAudioQualitySheet(context);
      case 'copy_link':
        final link = albumId != null
            ? 'https://music.yandex.ru/album/$albumId/track/$trackId'
            : 'https://music.yandex.ru/track/$trackId';
        await Clipboard.setData(ClipboardData(text: link));
        showAppSuccess('Ссылка скопирована');
      case 'download_cache':
        await _downloadTrack(DownloadMode.cache);
      case 'delete_downloaded':
        final ctx = appContextSignal.value;
        if (ctx != null) {
          try {
            await rust.deleteDownloadedTrack(ctx: ctx, trackId: trackId);
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

  Future<String?> _promptPlaylistTitle(BuildContext context) {
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
  Future<void> _createPlaylistAndAddTrack(BuildContext context) async {
    final title = await _promptPlaylistTitle(context);
    final trimmed = title?.trim();
    if (trimmed == null || trimmed.isEmpty || !context.mounted) return;

    final existingKinds = playlistsSignal.value.map((p) => p.kind).toSet();
    final success = await createPlaylistAction(trimmed, isPublic: false);
    if (!context.mounted) return;
    if (!success) {
      showAppError('Ошибка при создании плейлиста');
      return;
    }

    final created = playlistsSignal.value
        .where((p) => !existingKinds.contains(p.kind))
        .toList();
    if (created.isNotEmpty) {
      await addTrackToPlaylistAction(created.first.kind, trackId, albumId);
      if (context.mounted) showAppSuccess("Создан плейлист '$trimmed'");
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
    downloadingTracksSignal.value = {...downloadingTracksSignal.value, trackId};

    try {
      final paths = await rust.downloadTracks(
        ctx: ctx,
        trackIds: [trackId],
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
      final newSet = {...downloadingTracksSignal.value}..remove(trackId);
      downloadingTracksSignal.value = newSet;
    }
  }
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
