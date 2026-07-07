import 'dart:async';

import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/auth/providers/auth_provider.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/content.dart';
import 'package:yayma/src/rust/api/library.dart';
import 'package:yayma/src/rust/api/models.dart';

final FlutterSignal<List<SimpleTrackDto>> likedTracksSignal =
    signal<List<SimpleTrackDto>>([]);
final FlutterSignal<List<SimplePlaylistDto>> playlistsSignal =
    signal<List<SimplePlaylistDto>>([]);
final FlutterSignal<List<SimpleAlbumDto>> likedAlbumsSignal =
    signal<List<SimpleAlbumDto>>([]);
final FlutterSignal<List<SimpleArtistDto>> likedArtistsSignal =
    signal<List<SimpleArtistDto>>([]);
final FlutterSignal<bool> isLibraryLoadingSignal = signal<bool>(false);
final FlutterSignal<String> librarySearchQuerySignal = signal<String>('');
final FlutterSignal<Set<String>> downloadedTracksSignal = signal<Set<String>>(
  {},
);
final FlutterSignal<Set<String>> downloadingTracksSignal = signal<Set<String>>(
  {},
);

StreamSubscription<List<SimpleTrackDto>>? _likedSub;
Timer? _librarySearchDebounce;

Future<void> initLibrary() async {
  // Load only playlists as they are lightweight and might be needed for navigation
  await refreshPlaylists();
  await refreshDownloadedTracks();
  // Liked tracks are loaded on demand when the library screen is opened
}

Future<void> refreshDownloadedTracks() async {
  final ids = await runRustFetch((ctx) => getDownloadedTrackIds(ctx: ctx));
  if (ids != null) {
    downloadedTracksSignal.value = ids.toSet();
  }
}

Future<void> refreshPlaylists() async {
  final playlists = await runRustFetch((ctx) => getPlaylists(ctx: ctx));
  if (playlists != null) {
    playlistsSignal.value = playlists;
  }
}

Future<void> refreshLikedAlbums() async {
  final albums = await runRustFetch((ctx) => getLikedAlbums(ctx: ctx));
  if (albums != null) {
    likedAlbumsSignal.value = albums;
  }
}

Future<void> refreshLikedArtists() async {
  final artists = await runRustFetch((ctx) => getLikedArtists(ctx: ctx));
  if (artists != null) {
    likedArtistsSignal.value = artists;
  }
}

Future<bool> addLikedAlbumAction(String albumId) async {
  final id = int.tryParse(albumId);
  if (id == null) return false;

  final success = await runRustAction(
    (ctx) => addLikedAlbum(ctx: ctx, albumId: id),
  );
  return success;
}

Future<bool> removeLikedAlbumAction(String albumId) async {
  final id = int.tryParse(albumId);
  if (id == null) return false;

  final success = await runRustAction(
    (ctx) => removeLikedAlbum(ctx: ctx, albumId: id),
  );
  return success;
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
        if (isFirstChunk) {
          // Second empty chunk in a row or initial empty chunk when already expecting first
          // means the list is truly empty.
          likedTracksSignal.value = [];
          isFirstChunk = false;
        } else {
          // First empty chunk serves as a reset signal for a new data sequence.
          // We set isFirstChunk to true so that the next non-empty chunk REPLACES the list.
          isFirstChunk = true;
        }
      } else {
        if (isFirstChunk) {
          // Replace old list with the first result of a new search or update
          likedTracksSignal.value = chunk;
          isFirstChunk = false;
        } else {
          // Append subsequent chunks
          final existingIds = likedTracksSignal.value.map((t) => t.id).toSet();
          final uniqueNewTracks = chunk
              .where((t) => !existingIds.contains(t.id))
              .toList();

          if (uniqueNewTracks.isNotEmpty) {
            likedTracksSignal.value = [
              ...likedTracksSignal.value,
              ...uniqueNewTracks,
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
    unawaited(refreshLikedTracks(force: true));
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

final FlutterSignal<bool> isDownloadingAllLikedTracksSignal = signal(false);

Future<void> downloadAllLikedTracksAction(List<SimpleTrackDto> tracks) async {
  if (isDownloadingAllLikedTracksSignal.value) return;

  final ctx = appContextSignal.value;
  if (ctx == null) return;

  isDownloadingAllLikedTracksSignal.value = true;
  // Note: UI could handle the notification, but placing it here centralizes the logic.
  // We'll let the provider handle it for now, similar to other actions.

  try {
    final trackIds = tracks
        .where((t) => !downloadedTracksSignal.value.contains(t.id))
        .map((t) => t.id)
        .toList();

    if (trackIds.isNotEmpty) {
      await downloadTracksBatch(ctx: ctx, trackIds: trackIds);
    }
  } catch (e) {
    // Error handling will be deferred or handled by caller, or we could just log.
    rethrow;
  } finally {
    isDownloadingAllLikedTracksSignal.value = false;
  }
}

Future<int> deleteAllLikedTracksAction(List<SimpleTrackDto> tracks) async {
  final ctx = appContextSignal.value;
  if (ctx == null) return 0;

  var deleted = 0;
  for (final track in tracks) {
    final downloadedTracks = downloadedTracksSignal.value;
    if (downloadedTracks.contains(track.id)) {
      await deleteDownloadedTrack(ctx: ctx, trackId: track.id);
      unawaited(refreshDownloadedTracks());
      deleted++;
    }
  }

  return deleted;
}
