import 'dart:async';

import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/providers/auth_provider.dart';
import 'package:yayma/src/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/library.dart';
import 'package:yayma/src/rust/api/models.dart';

final FlutterSignal<List<SimpleTrackDto>> likedTracksSignal =
    signal<List<SimpleTrackDto>>([]);
final FlutterSignal<List<SimplePlaylistDto>> playlistsSignal =
    signal<List<SimplePlaylistDto>>([]);
final FlutterSignal<bool> isLibraryLoadingSignal = signal<bool>(false);
final FlutterSignal<String> librarySearchQuerySignal = signal<String>('');

StreamSubscription<List<SimpleTrackDto>>? _likedSub;
Timer? _librarySearchDebounce;

Future<void> initLibrary() async {
  // Load only playlists as they are lightweight and might be needed for navigation
  await refreshPlaylists();
  // Liked tracks are loaded on demand when the library screen is opened
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
      _likedSub != null) {
    return;
  }

  final ctx = appContextSignal.value;
  if (ctx == null) return;

  // Cancel previous subscription immediately
  final oldSub = _likedSub;
  _likedSub = null;
  unawaited(oldSub?.cancel());

  // Do not clear the list immediately to avoid flickering.
  // It will be cleared upon receiving the first chunk or reset signal.
  isLibraryLoadingSignal.value = true;

  StreamSubscription<List<SimpleTrackDto>>? sub;
  var isFirstChunk = true;

  sub = likedTracksStream(ctx: ctx, query: query).listen(
    (chunk) {
      if (sub != _likedSub) {
        unawaited(sub?.cancel());
        return;
      }

      if (chunk.isEmpty) {
        // Empty chunk serves as a reset signal from Rust
        likedTracksSignal.value = [];
        isFirstChunk = false;
      } else {
        if (isFirstChunk) {
          // Replace old list with the first result of a new search
          likedTracksSignal.value = chunk;
          isFirstChunk = false;
        } else {
          // Avoid duplicates when adding a chunk
          final existingIds = likedTracksSignal.value.map((t) => t.id).toSet();
          final uniqueNewTracks =
              chunk.where((t) => !existingIds.contains(t.id)).toList();

          if (uniqueNewTracks.isNotEmpty) {
            likedTracksSignal.value = [
              ...likedTracksSignal.value,
              ...uniqueNewTracks
            ];
          }
        }
      }
    },
    onDone: () {
      if (sub != _likedSub) return;
      isLibraryLoadingSignal.value = false;
    },
    onError: (_) {
      if (sub != _likedSub) return;
      isLibraryLoadingSignal.value = false;
    },
  );
  _likedSub = sub;
}

void setLibrarySearchQuery(String query) {
  final trimmedQuery = query.trim();
  librarySearchQuerySignal.value = trimmedQuery;

  _librarySearchDebounce?.cancel();

  if (trimmedQuery.isEmpty) {
    // Immediately reset search and request the full list
    unawaited(refreshLikedTracks(query: null, force: true));
    return;
  }

  _librarySearchDebounce = Timer(const Duration(milliseconds: 300), () {
    // Check if the query changed while waiting
    if (librarySearchQuerySignal.value == trimmedQuery) {
      unawaited(refreshLikedTracks(query: trimmedQuery, force: true));
    }
  });
}

Future<void> playTrackById(String trackId) async {
  await PlaybackController.playTrack(trackId);
}

Future<void> playLikedTrackById(String trackId) async {
  await PlaybackController.playLikedTrack(trackId);
}

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
