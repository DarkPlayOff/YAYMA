import 'dart:async';

import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/app/session.dart';
import 'package:yayma/src/features/core/services/debouncer.dart';
import 'package:yayma/src/features/core/services/rust_bridge.dart';
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

/// Number of liked tracks received in the active unfiltered sequence.
/// Drives the "Загружено N…" progress indicator.
final FlutterSignal<int> likedTracksLoadedSignal = signal<int>(0);

/// Last known full liked-tracks count (0 = unknown yet). Shown as "N / M".
final FlutterSignal<int> likedTracksExpectedSignal = signal<int>(0);

/// Last fully loaded unfiltered liked-tracks list. Backs local search
/// filtering so typing doesn't trigger a full Rust rebuild per keystroke.
final List<SimpleTrackDto> _likedFullCache = [];
final FlutterSignal<Set<String>> downloadedTracksSignal = signal<Set<String>>(
  {},
);
final FlutterSignal<Set<String>> downloadingTracksSignal = signal<Set<String>>(
  {},
);

StreamSubscription<List<SimpleTrackDto>>? _likedSub;
final Debouncer _librarySearchDebouncer = Debouncer();
final List<SimpleTrackDto> _likedAccum = [];
final Set<String> _likedAccumIds = {};
Timer? _likedFlushTimer;
bool _likedFlushPending = false;
Timer? _likedIdleTimer;

void _cancelLikedFlushTimer() {
  _likedFlushTimer?.cancel();
  _likedFlushTimer = null;
}

void _resetLikedAccum() {
  _cancelLikedFlushTimer();
  _likedIdleTimer?.cancel();
  _likedIdleTimer = null;
  _likedAccum.clear();
  _likedAccumIds.clear();
  _likedFlushPending = false;
}

/// Clears the chunk accumulator without touching the idle/load-finished
/// timer. Used inside the stream chunk handler: the handler arms the idle
/// timer on every chunk, so a full reset here would cancel the timer it
/// just started and leave `isLibraryLoadingSignal` stuck `true` on short
/// (single-chunk) or empty libraries.
void _clearLikedAccumContents() {
  _cancelLikedFlushTimer();
  _likedAccum.clear();
  _likedAccumIds.clear();
  _likedFlushPending = false;
}

Future<void> initLibrary() async {
  // Load only playlists as they are lightweight and might be needed for navigation
  await refreshPlaylists();
  await refreshDownloadedTracks();
  // Liked tracks are loaded on demand when the library screen is opened
}

Future<void> disposeLibrary() async {
  _librarySearchDebouncer.dispose();
  final sub = _likedSub;
  _likedSub = null;
  await sub?.cancel();
  _resetLikedAccum();
  likedTracksSignal.value = [];
  playlistsSignal.value = [];
  likedAlbumsSignal.value = [];
  likedArtistsSignal.value = [];
  isLibraryLoadingSignal.value = false;
  likedTracksLoadedSignal.value = 0;
  likedTracksExpectedSignal.value = 0;
  _likedFullCache.clear();
  librarySearchQuerySignal.value = '';
  downloadedTracksSignal.value = {};
  downloadingTracksSignal.value = {};
  isDownloadingAllLikedTracksSignal.value = false;
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

Future<bool> addLikedArtistAction(String artistId) async {
  if (artistId.isEmpty) return false;

  final success = await runRustAction(
    (ctx) => addLikedArtist(ctx: ctx, artistId: artistId),
  );
  return success;
}

Future<bool> removeLikedArtistAction(String artistId) async {
  if (artistId.isEmpty) return false;

  final success = await runRustAction(
    (ctx) => removeLikedArtist(ctx: ctx, artistId: artistId),
  );
  return success;
}

Future<bool> addDislikedArtistAction(String artistId) async {
  if (artistId.isEmpty) return false;

  final success = await runRustAction(
    (ctx) => addDislikedArtist(ctx: ctx, artistId: artistId),
  );
  return success;
}

Future<bool> removeDislikedArtistAction(String artistId) async {
  if (artistId.isEmpty) return false;

  final success = await runRustAction(
    (ctx) => removeDislikedArtist(ctx: ctx, artistId: artistId),
  );
  return success;
}

Future<bool> addLikedPlaylistAction(String ownerUid, int kind) async {
  final uid = BigInt.tryParse(ownerUid);
  if (uid == null) return false;

  final success = await runRustAction(
    (ctx) => addLikedPlaylist(ctx: ctx, ownerUid: uid, kind: kind),
  );
  return success;
}

Future<bool> removeLikedPlaylistAction(String ownerUid, int kind) async {
  final uid = BigInt.tryParse(ownerUid);
  if (uid == null) return false;

  final success = await runRustAction(
    (ctx) => removeLikedPlaylist(ctx: ctx, ownerUid: uid, kind: kind),
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
  _resetLikedAccum();
  // Reset progress for the new run; keep `expected` as last-known total
  // so "N / M" still shows a denominator during reloads.
  likedTracksLoadedSignal.value = 0;

  // Do not clear the list immediately to avoid flickering.
  // It will be cleared upon receiving the first chunk or reset signal.
  isLibraryLoadingSignal.value = true;

  StreamSubscription<List<SimpleTrackDto>>? sub;
  var isFirstChunk = true;
  final isSearch = query?.trim().isNotEmpty ?? false;

  void publishAccum() {
    _likedFlushPending = false;
    likedTracksSignal.value = List.of(_likedAccum);
    if (!isSearch) {
      _likedFullCache
        ..clear()
        ..addAll(_likedAccum);
      likedTracksLoadedSignal.value = _likedAccum.length;
    }
  }

  void scheduleFlush() {
    if (_likedFlushTimer != null) return;
    _likedFlushTimer = Timer(const Duration(milliseconds: 250), () {
      _likedFlushTimer = null;
      if (sub != _likedSub || !_likedFlushPending) return;
      publishAccum();
    });
  }

  // The Rust stream never closes on its own (it waits on library_changed),
  // so "load finished" = no new chunks for a while. On idle, drop the
  // loading flag and remember the count as the expected total.
  void restartIdleTimer() {
    _likedIdleTimer?.cancel();
    _likedIdleTimer = Timer(const Duration(milliseconds: 500), () {
      _likedIdleTimer = null;
      if (sub != _likedSub) return;
      isLibraryLoadingSignal.value = false;
      if (!isSearch && _likedAccum.isNotEmpty) {
        likedTracksExpectedSignal.value = _likedAccum.length;
      }
    });
  }

  sub = likedTracksStream(ctx: ctx, query: query).listen(
    (chunk) {
      if (sub != _likedSub) {
        unawaited(sub?.cancel());
        return;
      }
      isLibraryLoadingSignal.value = true;
      restartIdleTimer();

      if (chunk.isEmpty) {
        if (isFirstChunk) {
          // Second empty chunk in a row or initial empty chunk when already expecting first
          // means the list is truly empty.
          _clearLikedAccumContents();
          likedTracksSignal.value = [];
          if (!isSearch) {
            _likedFullCache.clear();
            likedTracksLoadedSignal.value = 0;
          }
          isFirstChunk = false;
        } else {
          // First empty chunk serves as a reset signal for a new data sequence.
          // We set isFirstChunk to true so that the next non-empty chunk REPLACES the list.
          // NOTE: must not cancel the idle timer armed above.
          _clearLikedAccumContents();
          isFirstChunk = true;
        }
      } else {
        if (isFirstChunk) {
          // Replace old list with the first result of a new search or update.
          // Publish immediately for fast first paint.
          // NOTE: must not cancel the idle timer armed above.
          _clearLikedAccumContents();
          for (final t in chunk) {
            if (_likedAccumIds.add(t.id)) _likedAccum.add(t);
          }
          publishAccum();
          isFirstChunk = false;
        } else {
          // Accumulate subsequent chunks with incremental dedup (O(1) per
          // track) and publish throttled copies instead of one signal
          // update per 50-track chunk.
          var added = false;
          for (final t in chunk) {
            if (_likedAccumIds.add(t.id)) {
              _likedAccum.add(t);
              added = true;
            }
          }
          if (added) {
            _likedFlushPending = true;
            scheduleFlush();
          }
        }
      }
    },
    onDone: () {
      if (sub != _likedSub) return;
      _cancelLikedFlushTimer();
      _likedIdleTimer?.cancel();
      _likedIdleTimer = null;
      if (_likedFlushPending) publishAccum();
      isLibraryLoadingSignal.value = false;
    },
    onError: (_) {
      if (sub != _likedSub) return;
      _cancelLikedFlushTimer();
      _likedIdleTimer?.cancel();
      _likedIdleTimer = null;
      isLibraryLoadingSignal.value = false;
    },
  );
  _likedSub = sub;
}

/// Local equivalent of Rust `track_dto_matches_query` (title/artists/album,
/// case-insensitive): filters the cached full liked-tracks list without a
/// Rust round-trip.
bool _likedTrackMatchesQuery(SimpleTrackDto t, String q) {
  if (t.title.toLowerCase().contains(q)) return true;
  for (final a in t.artists) {
    if (a.name.toLowerCase().contains(q)) return true;
  }
  final album = t.album;
  return album != null && album.toLowerCase().contains(q);
}

/// Filters the cached full liked-tracks list locally. Returns false when the
/// cache is empty and the caller should fall back to the Rust query stream
/// (e.g. library opened with a persisted query before the first full load).
bool filterLikedTracksLocally(String query) {
  if (_likedFullCache.isEmpty) return false;
  // The cache is updated incrementally during the bulk load, so filtering
  // it mid-load would show a truncated list and cancel the full stream
  // (`_likedSub`), leaving the cache partial. Fall back to the Rust query
  // stream while the unfiltered load is still in progress.
  if (isLibraryLoadingSignal.value) return false;
  final oldSub = _likedSub;
  _likedSub = null;
  unawaited(oldSub?.cancel());
  _resetLikedAccum();
  isLibraryLoadingSignal.value = false;
  final q = query.toLowerCase();
  likedTracksSignal.value = _likedFullCache
      .where((t) => _likedTrackMatchesQuery(t, q))
      .toList();
  return true;
}

void setLibrarySearchQuery(String query) {
  final trimmedQuery = query.trim();
  librarySearchQuerySignal.value = trimmedQuery;

  _librarySearchDebouncer.cancel();

  if (trimmedQuery.isEmpty) {
    // Immediately reset search and request the full list
    unawaited(refreshLikedTracks(force: true));
    return;
  }

  _librarySearchDebouncer.run(() {
    // Check if the query changed while waiting
    if (librarySearchQuerySignal.value == trimmedQuery) {
      // Prefer the local cache: no full Rust rebuild per keystroke.
      if (!filterLikedTracksLocally(trimmedQuery)) {
        unawaited(refreshLikedTracks(query: trimmedQuery, force: true));
      }
    }
  }, const Duration(milliseconds: 300));
}

Future<bool> addTrackToPlaylistAction(
  int kind,
  String trackId,
  String? albumId,
) async {
  final success = await runRustAction(
    (ctx) => addTrackToPlaylist(
      ctx: ctx,
      kind: kind,
      trackId: trackId,
      albumId: albumId,
    ),
  );
  if (success) await refreshPlaylists();
  return success;
}

Future<bool> removeTrackFromPlaylistAction(
  int kind,
  String trackId,
  String? albumId,
) async {
  final success = await runRustAction(
    (ctx) => removeTrackFromPlaylist(
      ctx: ctx,
      kind: kind,
      trackId: trackId,
      albumId: albumId,
    ),
  );
  if (success) await refreshPlaylists();
  return success;
}

Future<bool> moveTrackInPlaylistAction(
  int kind,
  int fromIndex,
  int toIndex,
  String trackId,
  String? albumId,
) async {
  final success = await runRustAction(
    (ctx) => moveTrackInPlaylist(
      ctx: ctx,
      kind: kind,
      fromIndex: fromIndex,
      toIndex: toIndex,
      trackId: trackId,
      albumId: albumId ?? '',
    ),
  );
  if (success) await refreshPlaylists();
  return success;
}

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

Future<List<String>> downloadLikedTracksAction(
  List<SimpleTrackDto> tracks, {
  required bool toCache,
}) async {
  if (isDownloadingAllLikedTracksSignal.value) return const [];

  final ctx = appContextSignal.value;
  if (ctx == null) return const [];

  isDownloadingAllLikedTracksSignal.value = true;

  try {
    final trackIds = toCache
        ? tracks
              .where((t) => !downloadedTracksSignal.value.contains(t.id))
              .map((t) => t.id)
              .toList()
        : tracks.map((track) => track.id).toList();

    if (trackIds.isEmpty) return const [];

    final paths = await downloadTracks(
      ctx: ctx,
      trackIds: trackIds,
      toCache: toCache,
      collectionName: toCache ? null : 'Любимые треки',
    );
    if (toCache) unawaited(refreshDownloadedTracks());
    return paths;
  } finally {
    isDownloadingAllLikedTracksSignal.value = false;
  }
}

Future<List<String>> downloadCollectionToFilesAction(
  List<SimpleTrackDto> tracks, {
  required String collectionName,
}) async {
  final ctx = appContextSignal.value;
  if (ctx == null || tracks.isEmpty) return const [];

  return await downloadTracks(
    ctx: ctx,
    trackIds: tracks.map((track) => track.id).toList(),
    toCache: false,
    collectionName: collectionName,
  );
}

Future<int> deleteAllLikedTracksAction(List<SimpleTrackDto> tracks) async {
  final ctx = appContextSignal.value;
  if (ctx == null) return 0;

  var deleted = 0;
  final downloadedTracks = downloadedTracksSignal.value;
  for (final track in tracks) {
    if (downloadedTracks.contains(track.id)) {
      await deleteDownloadedTrack(ctx: ctx, trackId: track.id);
      deleted++;
    }
  }
  // Single refresh after the loop: per-track refreshes used to queue
  // thousands of redundant DB reads on large libraries.
  if (deleted > 0) unawaited(refreshDownloadedTracks());

  return deleted;
}
