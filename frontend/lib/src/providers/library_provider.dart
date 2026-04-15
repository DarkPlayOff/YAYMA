import 'dart:async';

import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/providers/auth_provider.dart';
import 'package:yayma/src/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/library.dart';
import 'package:yayma/src/rust/api/models.dart';

// Сигналы
final FlutterSignal<List<SimpleTrackDto>> likedTracksSignal =
    signal<List<SimpleTrackDto>>([]);
final FlutterSignal<List<SimplePlaylistDto>> playlistsSignal =
    signal<List<SimplePlaylistDto>>([]);
final FlutterSignal<bool> isLibraryLoadingSignal = signal<bool>(false);
final FlutterSignal<String> librarySearchQuerySignal = signal<String>('');

StreamSubscription<List<SimpleTrackDto>>? _likedSub;
Timer? _librarySearchDebounce;

Future<void> initLibrary() async {
  // Грузим только плейлисты, так как они легкие и могут быть нужны в навигации
  await refreshPlaylists();
  // Лайки НЕ ГРУЗИМ при старте. refreshLikedTracks() вызовет сам экран библиотеки при открытии.
}

Future<void> refreshPlaylists() async {
  final playlists = await runRustFetch((ctx) => getPlaylists(ctx: ctx));
  if (playlists != null) {
    playlistsSignal.value = playlists;
  }
}

Future<void> refreshLikedTracks({String? query, bool force = false}) async {
  if (!force &&
      query == null &&
      likedTracksSignal.value.isNotEmpty &&
      _likedSub != null) return;

  final ctx = appContextSignal.value;
  if (ctx == null) return;

  await _likedSub?.cancel();
  likedTracksSignal.value = [];
  isLibraryLoadingSignal.value = true;

  _likedSub = likedTracksStream(ctx: ctx, query: query).listen(
    (chunk) {
      if (chunk.isEmpty) {
        // Пустой чанк служит сигналом сброса (reset) от Rust
        likedTracksSignal.value = [];
      } else {
        likedTracksSignal.value = [...likedTracksSignal.value, ...chunk];
      }
    },
    onDone: () {
      isLibraryLoadingSignal.value = false;
    },
    onError: (_) {
      isLibraryLoadingSignal.value = false;
    },
  );
}

void setLibrarySearchQuery(String query) {
  librarySearchQuerySignal.value = query;

  _librarySearchDebounce?.cancel();

  if (query.trim().isEmpty) {
    unawaited(refreshLikedTracks(force: true));
    return;
  }

  _librarySearchDebounce = Timer(const Duration(milliseconds: 500), () {
    unawaited(
      refreshLikedTracks(
        query: query.trim().isEmpty ? null : query,
        force: true,
      ),
    );
  });
}

Future<void> playTrackById(String trackId) async {
  await PlaybackController.playTrack(trackId);
}

Future<void> playLikedTrackById(String trackId) async {
  await PlaybackController.playLikedTrack(trackId);
}

// Экшены
Future<bool> addTrackToPlaylistAction(
  int kind,
  String trackId,
  String? albumId,
) => runRustAction(
  (ctx) => addTrackToPlaylist(
    ctx: ctx,
    kind: kind,
    trackId: trackId,
    albumId: albumId,
  ),
);

Future<bool> removeTrackFromPlaylistAction(
  int kind,
  String trackId,
  String? albumId,
) => runRustAction(
  (ctx) => removeTrackFromPlaylist(
    ctx: ctx,
    kind: kind,
    trackId: trackId,
    albumId: albumId,
  ),
);

Future<bool> moveTrackInPlaylistAction(
  int kind,
  int fromIndex,
  int toIndex,
  String trackId,
  String? albumId,
) => runRustAction(
  (ctx) => moveTrackInPlaylist(
    ctx: ctx,
    kind: kind,
    fromIndex: fromIndex,
    toIndex: toIndex,
    trackId: trackId,
    albumId: albumId ?? '',
  ),
);

Future<bool> createPlaylistAction(
  String title, {
  required bool isPublic,
}) async {
  final success = await runRustAction(
    (ctx) => createPlaylist(ctx: ctx, title: title, isPublic: isPublic),
  );
  if (success) await refreshPlaylists();
  return success;
}

Future<bool> deletePlaylistAction(int kind) async {
  final success = await runRustAction(
    (ctx) => deletePlaylist(ctx: ctx, kind: kind),
  );
  if (success) await refreshPlaylists();
  return success;
}

Future<bool> renamePlaylistAction(int kind, String newTitle) async {
  final success = await runRustAction(
    (ctx) => renamePlaylist(ctx: ctx, kind: kind, newTitle: newTitle),
  );
  if (success) await refreshPlaylists();
  return success;
}

Future<bool> setPlaylistVisibilityAction(
  int kind, {
  required bool isPublic,
}) async {
  final success = await runRustAction(
    (ctx) => setPlaylistVisibility(ctx: ctx, kind: kind, isPublic: isPublic),
  );
  if (success) await refreshPlaylists();
  return success;
}

Future<bool> uploadTrackAction(String filePath, {int? playlistKind}) async {
  final success = await runRustAction(
    (ctx) => uploadUserTrack(
      ctx: ctx,
      filePath: filePath,
      playlistKind: playlistKind,
    ),
  );
  return success;
}
