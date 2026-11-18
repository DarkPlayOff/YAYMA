import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/app/session.dart';
import 'package:yayma/src/features/core/providers/notification_provider.dart';
import 'package:yayma/src/features/core/providers/visual_effects_provider.dart';
import 'package:yayma/src/features/core/services/app_error.dart';
import 'package:yayma/src/features/core/services/debouncer.dart';
import 'package:yayma/src/features/core/services/rust_bridge.dart';
import 'package:yayma/src/features/core/theme/app_theme.dart';
import 'package:yayma/src/features/core/theme/cover_palette.dart';
import 'package:yayma/src/features/core/utils/track_ids.dart';
import 'package:yayma/src/features/library/providers/library_provider.dart';
import 'package:yayma/src/rust/api/audio_fx.dart' as rust;
import 'package:yayma/src/rust/api/library.dart' as rust;
import 'package:yayma/src/rust/api/models.dart';
import 'package:yayma/src/rust/api/playback.dart' as rust;
import 'package:yayma/src/rust/api/simple.dart' as rust;
import 'package:yayma/src/rust/lib.dart';

// Player state signals
final FlutterSignal<PlaybackState?> playerStateSignal = signal<PlaybackState?>(
  null,
);
final FlutterSignal<PlaybackProgressDto?> playerProgressSignal =
    signal<PlaybackProgressDto?>(null);
final FlutterSignal<F32Array26> vibeTickSignal = signal<F32Array26>(
  F32Array26.init(),
);

final FlutterSignal<AudioQuality> audioQualitySignal = signal<AudioQuality>(
  AudioQuality.normal,
);

/// Crossfade toggle: on = fixed-length overlap between tracks, off = strict
/// gapless transition without overlap. Mirrors the persisted Rust setting;
/// the audio engine reads the same value through its own signals.
final FlutterSignal<bool> crossfadeEnabledSignal = signal(true);

/// "Меньше ИИ": ask Yandex for fewer AI-generated tracks in recommendations.
final FlutterSignal<bool> aiContentReductionSignal = signal(false);

StreamSubscription<rust.AppEvent>? _eventSub;

/// Deduplicates concurrent [initPlayback] calls (login + auto-login racing).
Future<void>? _initPlaybackFuture;

/// Track the last progress snapshot belongs to. Used to tell a real track
/// change from a pause/like/volume update that must not reset the position.
String? _progressTrackId;

Future<void> initPlayback() {
  final ongoing = _initPlaybackFuture;
  if (ongoing != null) return ongoing;
  final future = _initPlaybackUnsafe();
  _initPlaybackFuture = future;
  unawaited(
    future.then(
      (_) {
        if (identical(_initPlaybackFuture, future)) _initPlaybackFuture = null;
      },
      onError: (_) {
        if (identical(_initPlaybackFuture, future)) _initPlaybackFuture = null;
      },
    ),
  );
  return future;
}

/// Explicit teardown for logout/app shutdown: cancels the Rust event stream
/// and resets playback-owned signals to their initial values so a later
/// [initPlayback] starts clean. Idempotent.
Future<void> disposePlayback() async {
  _initPlaybackFuture = null;
  _progressTrackId = null;
  // Clear the handle first and don't await the cancel: an FFI stream cancel
  // may never complete and must not stall logout before it reaches the UI.
  final sub = _eventSub;
  _eventSub = null;
  unawaited(sub?.cancel());

  _bufferingDelayDebouncer.dispose();
  _stablePlayingDebouncer.dispose();
  stablePlayingSignal.value = false;
  _userPausePending = false;

  playerStateSignal.value = null;
  playerProgressSignal.value = null;
  vibeTickSignal.value = F32Array26.init();
  audioQualitySignal.value = AudioQuality.normal;
  audioDevicesSignal.value = [];
  selectedAudioDeviceSignal.value = null;
  colorSchemeSignal.value = null;
  appThemeSignal.value = null;
  showBufferingIndicatorSignal.value = false;
  showLyricsSignal.value = false;
  hideLyricsOverlaySignal.value = false;
  lyricsSuppressDimSignal.value = false;
  equalizerSignal.value = null;
  audioEffectsSignal.value = [];

  clearCoverPalettes();
  // In-flight preparations finish harmlessly; clearing drops the handles so
  // stale futures are not held across login sessions.
}

Future<void> _initPlaybackUnsafe() async {
  final ctx = appContextSignal.value;
  if (ctx == null) return;

  // The Android UI has no wave shader, so keep Rust from computing ticks
  // for a frame nobody draws.
  if (Platform.isAndroid) {
    vibeVisibleSignal.value = false;
    unawaited(rust.setVibeAnimationEnabled(ctx: ctx, enabled: false));
  }

  final previousSub = _eventSub;
  _eventSub = null;
  unawaited(previousSub?.cancel());

  // Initialize app event stream
  final subscription = rust.appEventStream(ctx: ctx).listen((event) {
    switch (event) {
      case rust.AppEvent_PlaybackStateChanged(field0: final state):
        playerStateSignal.value = state;
        final trackId = state.currentTrack?.id;
        if (trackId != _progressTrackId) {
          // Progress events belong to one track and stop while it is swapped;
          // snap to the new track's duration so the seek bar, notification and
          // lyrics stop showing the previous track's values.
          _progressTrackId = trackId;
          final track = state.currentTrack;
          playerProgressSignal.value = track == null
              ? null
              : PlaybackProgressDto(
                  positionMs: 0,
                  durationMs: track.durationMs,
                );
        }
      case rust.AppEvent_PlaybackProgress(field0: final progress):
        playerProgressSignal.value = progress;
      case rust.AppEvent_VibeTick(field0: final tick):
        if (vibeVisibleSignal.value) {
          vibeTickSignal.value = tick;
        }
      case rust.AppEvent_LikedTracksChanged(field0: final tracks):
        likedTracksSignal.value = tracks;
      case rust.AppEvent_AccountUpdated(field0: final account):
        accountSignal.value = account;
      case rust.AppEvent_Notification(field1: final message):
        showAppWarning(message);
      case rust.AppEvent_Error(field0: final message):
        if (isSessionExpired(message)) {
          // Rust sends the raw auth wording; confirm before logging out so a
          // transient 401 keeps the session.
          unawaited(confirmedLogout(ctx, message));
        } else {
          // Rust sends the actionable reason here ("Buffering timed out after
          // 15s", "Failed to play track: …"), so keep it instead of replacing
          // it with a generic line.
          showAppError('Ошибка воспроизведения: $message');
        }
      case rust.AppEvent_TrackDownloadStarted(field0: final trackId):
        downloadingTracksSignal.value = {
          ...downloadingTracksSignal.value,
          trackId,
        };
      case rust.AppEvent_TrackDownloadFinished(field0: final trackId):
        downloadingTracksSignal.value = {...downloadingTracksSignal.value}
          ..remove(trackId);
        unawaited(refreshDownloadedTracks());
      case rust.AppEvent_TrackDownloadFailed(
        field0: final trackId,
        field1: final error,
      ):
        downloadingTracksSignal.value = {...downloadingTracksSignal.value}
          ..remove(trackId);
        showAppError('Ошибка загрузки трека: $error');
      case _:
        break;
    }
  });
  _eventSub = subscription;

  final quality = await rust.getAudioQuality(ctx: ctx);

  // A logout (or a login as another account) may have landed while awaiting.
  // Installing effects and theme now would bind them to the dead context.
  if (!identical(appContextSignal.value, ctx)) {
    // Cancel only our own subscription: a new init may have replaced it
    // while this one was awaiting. Not awaited — an FFI cancel may never
    // complete.
    unawaited(subscription.cancel());
    if (identical(_eventSub, subscription)) _eventSub = null;
    return;
  }

  audioQualitySignal.value = quality;
  activateCoverTheme();
  _activateEffects();
}

/// Reading a lazy top-level effect initializes it and starts it listening.
final List<EffectCleanup> _playbackEffects = [
  _vibePaletteEffect,
  _bufferingDelayEffect,
  _stablePlayingEffect,
  _lyricsOverlayResetEffect,
  _wifiLockEffect,
];

void _activateEffects() => _playbackEffects;

const _wifiLockChannel = MethodChannel('io.github.darkplayoff.yayma/wifilock');

/// Prompts the user (once, via the system dialog) to exempt the app from
/// battery optimizations, so Android doesn't throttle/kill the background
/// audio engine independently of the wake lock held during playback.
Future<void> requestIgnoreBatteryOptimizations() async {
  if (!Platform.isAndroid) return;
  await _wifiLockChannel
      .invokeMethod('requestIgnoreBatteryOptimizations')
      .catchError((_) {});
}

final EffectCleanup _wifiLockEffect = effect(() {
  if (!Platform.isAndroid) return;

  final state = playerStateSignal();
  final shouldHold =
      (state?.isBuffering ?? false) || (state?.isPlaying ?? false);

  if (shouldHold) {
    unawaited(_wifiLockChannel.invokeMethod('acquire').catchError((e) {}));
  } else {
    unawaited(_wifiLockChannel.invokeMethod('release').catchError((e) {}));
  }
});

// Signal for current track ID only
final FlutterComputed<String?> currentTrackIdSignal = computed(
  () => playerStateSignal.value?.currentTrack?.id,
  options: const ComputedOptions(name: 'currentTrackIdSignal'),
);

// Signal for the current track only
final FlutterComputed<SimpleTrackDto?> currentTrackSignal = computed(
  () => playerStateSignal.value?.currentTrack,
  options: const ComputedOptions(name: 'currentTrackSignal'),
);

// Signal for volume only
final FlutterComputed<int> playerVolumeSignal = computed(
  () => playerStateSignal.value?.volume ?? 100,
  options: const ComputedOptions(name: 'playerVolumeSignal'),
);

// Signal for playback status only
final FlutterComputed<bool> isPlayingSignal = computed(
  () => playerStateSignal.value?.isPlaying ?? false,
  options: const ComputedOptions(name: 'isPlayingSignal'),
);

// A track switch briefly reports `isPlaying = false` while the engine swaps
// sources. Propagating that directly flickers the play/pause button and
// shrinks the cover for the length of the transition. [stablePlayingSignal]
// delays every false transition by [stablePlayingDelay]: if playback resumes
// within the window, the pause never becomes visible. A pause the user asked
// for flushes the delay immediately (see [PlaybackController.togglePlay]
// and [PlaybackController.pause]).
const Duration stablePlayingDelay = Duration(seconds: 1);
final FlutterSignal<bool> stablePlayingSignal = signal(false);
final Debouncer _stablePlayingDebouncer = Debouncer();
// Set when the user asks for a pause, so the matching false transition skips
// the delay instead of leaving the button unresponsive for a second.
bool _userPausePending = false;

final EffectCleanup _stablePlayingEffect = effect(() {
  if (isPlayingSignal()) {
    _userPausePending = false;
    _stablePlayingDebouncer.cancel();
    stablePlayingSignal.value = true;
    return;
  }
  if (!stablePlayingSignal.peek()) return;
  if (_userPausePending) {
    _userPausePending = false;
    _stablePlayingDebouncer.cancel();
    stablePlayingSignal.value = false;
    return;
  }
  // runOnce: repeated false pushes must not restart the countdown.
  _stablePlayingDebouncer.runOnce(
    () => stablePlayingSignal.value = false,
    stablePlayingDelay,
  );
});

// Shuffle signal
final FlutterComputed<bool> isShuffledSignal = computed(
  () => playerStateSignal.value?.isShuffled ?? false,
  options: const ComputedOptions(name: 'isShuffledSignal'),
);

// Repeat mode signal
final FlutterComputed<RepeatModeDto> repeatModeSignal = computed(
  () => playerStateSignal.value?.repeatMode ?? RepeatModeDto.none,
  options: const ComputedOptions(name: 'repeatModeSignal'),
);

// Signals for liking/disliking the current track
final FlutterComputed<bool> isLikedSignal = computed(
  () => playerStateSignal.value?.currentTrack?.isLiked ?? false,
  options: const ComputedOptions(name: 'isLikedSignal'),
);

final FlutterComputed<bool> isDislikedSignal = computed(
  () => playerStateSignal.value?.currentTrack?.isDisliked ?? false,
  options: const ComputedOptions(name: 'isDislikedSignal'),
);

// Signal for current wave seeds
final FlutterComputed<List<String>> currentWaveSeedsSignal = computed(
  () => playerStateSignal.value?.currentWaveSeeds ?? [],
  options: const ComputedOptions(name: 'currentWaveSeedsSignal'),
);

/// True while the queue is owned by the rotor session ("Моя волна"):
/// shuffle/repeat are disabled there, desktop-client parity.
final FlutterComputed<bool> isWaveActiveSignal = computed(
  () => currentWaveSeedsSignal().isNotEmpty,
  options: const ComputedOptions(name: 'isWaveActiveSignal'),
);

// Track metadata (static data only)
final FlutterComputed<
  ({
    String? id,
    String title,
    String? version,
    List<TrackArtistDto> artists,
    String? album,
    String? albumId,
    String? coverUrl,
    int durationMs,
    String? codec,
  })
>
trackMetadataSignal = computed(() {
  final state = playerStateSignal.value;
  return (
    id: state?.currentTrack?.id,
    title: state?.currentTrack?.title ?? 'Тишина',
    version: state?.currentTrack?.version,
    artists: state?.currentTrack?.artists ?? [],
    album: state?.currentTrack?.album,
    albumId: state?.currentTrack?.albumId,
    coverUrl: state?.currentTrack?.coverUrl,
    durationMs: state?.currentTrack?.durationMs ?? 0,
    codec: state?.codec,
  );
}, options: const ComputedOptions(name: 'trackMetadataSignal'));

// Track progress (updates frequently)
final FlutterComputed<({double durationMs, double positionMs})>
trackProgressSignal = computed(() {
  final progress = playerProgressSignal.value;
  return (
    durationMs: (progress?.durationMs ?? 1).toDouble(),
    positionMs: (progress?.positionMs ?? 0).toDouble(),
  );
}, options: const ComputedOptions(name: 'trackProgressSignal'));

// Signal for audio output devices
final FlutterSignal<List<String>> audioDevicesSignal = signal<List<String>>([]);
final FlutterSignal<String?> selectedAudioDeviceSignal = signal<String?>(null);

Future<void> refreshAudioDevices() async {
  final ctx = appContextSignal.value;
  if (ctx == null) return;
  audioDevicesSignal.value = await rust.getAudioDevices(ctx: ctx);
}

Future<void> setAudioDevice(String deviceName) async {
  final ctx = appContextSignal.value;
  if (ctx == null) return;
  selectedAudioDeviceSignal.value = deviceName.isEmpty ? null : deviceName;
  await rust.setAudioDevice(ctx: ctx, deviceName: deviceName);
}

// Signal for cover URL only to avoid re-calculating on pause/likes
final FlutterComputed<String?> currentCoverUrlSignal = computed(
  () => playerStateSignal.value?.currentTrack?.coverUrl,
);

// Signal for local cover URI from Rust cache
final FutureSignal<Uri?> localCoverUriSignal = computedAsync(() async {
  final url = currentCoverUrlSignal();
  final ctx = appContextSignal.value;
  if (url == null || ctx == null) return null;

  final path = await rust.getCachedImagePath(ctx: ctx, url: url);
  if (path != null) return Uri.file(path);
  return Uri.parse(url); // Fallback to remote if not yet cached
}, options: const AsyncSignalOptions(name: 'localCoverUriSignal'));

// Queue shape only: recomputed when the queue size or order changes, not on
// every pause/volume/like, each of which would otherwise copy the whole queue
// over FFI and query the DB again.
final FlutterComputed<int> queueCountSignal = computed(
  () => playerStateSignal.value?.queueCount ?? 0,
  options: const ComputedOptions(name: 'queueCountSignal'),
);

// Queue position only: the queue panel subscribes to this instead of the
// whole playback state, so volume/pause ticks do not rebuild the O(n) list.
final FlutterComputed<int> queueIndexSignal = computed(
  () => playerStateSignal.value?.queueIndex ?? 0,
  options: const ComputedOptions(name: 'queueIndexSignal'),
);

// Playback source context only (for the "Сейчас играет из …" header line).
final FlutterComputed<PlaybackContextDto?> playbackContextSignal = computed(
  () => playerStateSignal.value?.playbackContext,
  options: const ComputedOptions(name: 'playbackContextSignal'),
);

// Queue identity only: bumped by Rust whenever the queue is replaced or
// reordered. Count alone misses a replacement with the same queue length.
final FlutterComputed<int> queueRevisionSignal = computed(
  () => playerStateSignal.value?.queueRevision ?? 0,
  options: const ComputedOptions(name: 'queueRevisionSignal'),
);

/// Narrow neighbourhood of the playhead for the cover-swipe previews:
/// [queueIndex-1 .. queueIndex+1], plus the previous/next tracks already
/// resolved in Rust under the real repeat policy. One call covers both the
/// window and the hints, so they refresh together and cannot drift.
final FutureSignal<QueueNeighborhoodDto> queueNeighborhoodSignal =
    computedAsync(
      () async {
        final ctx = appContextSignal();
        final queueCount = queueCountSignal();
        queueIndexSignal();
        repeatModeSignal();
        // Refetch when the queue itself changes, including a same-length swap
        // (album A → album B) and a shuffle that reorders the same tracks.
        final _ = queueRevisionSignal();
        if (ctx == null || queueCount == 0) {
          return const QueueNeighborhoodDto(tracks: []);
        }

        return await rust.queueNeighborhood(ctx: ctx);
      },
      options: const AsyncSignalOptions(name: 'queueNeighborhoodSignal'),
    );

/// Tracks around the playhead, for optimistic like inserts.
final FlutterComputed<List<SimpleTrackDto>> queueTracksSignal = computed(
  () => queueNeighborhoodSignal.value.value?.tracks ?? const [],
  options: const ComputedOptions(name: 'queueTracksSignal'),
);

/// How many upcoming tracks the queue panel fetches and shows at most, like
/// the desktop client caps its queue view. The rest is summarised in a
/// footer line.
const int queueWindowLength = 200;

/// Upcoming queue window for the panel: the [queueWindowLength] tracks after
/// the current one, so large queues are not copied whole on every change.
/// Refetched on queue revisions and on queue position moves (the window
/// follows the playhead).
final FutureSignal<List<SimpleTrackDto>> queueWindowSignal = computedAsync(
  () async {
    final ctx = appContextSignal();
    final count = queueCountSignal();
    final start = queueIndexSignal() + 1;
    // Refetch on queue mutations, same as queueTracksSignal.
    final _ = queueRevisionSignal();
    if (ctx == null || start >= count) return const [];

    return await rust.queueWindow(
      ctx: ctx,
      offset: start,
      len: queueWindowLength,
    );
  },
  options: const AsyncSignalOptions(name: 'queueWindowSignal'),
);

/// How many already-played tracks the queue panel keeps visible.
const int queuePlayedWindowLength = 50;

/// Already-played queue window for the panel: up to
/// [queuePlayedWindowLength] tracks right before the playhead. The absolute
/// index of the first track travels with the list, so a stale value (kept
/// while a move refetches) can still be placed correctly.
final FutureSignal<({int start, List<SimpleTrackDto> tracks})>
queuePlayedWindowSignal = computedAsync(() async {
  final ctx = appContextSignal();
  final index = queueIndexSignal();
  // Refetch on queue mutations, same as queueWindowSignal.
  final _ = queueRevisionSignal();
  if (ctx == null || index == 0) {
    return (start: 0, tracks: const <SimpleTrackDto>[]);
  }
  final start = index > queuePlayedWindowLength
      ? index - queuePlayedWindowLength
      : 0;
  return (
    start: start,
    tracks: await rust.queueWindow(ctx: ctx, offset: start, len: index - start),
  );
}, options: const AsyncSignalOptions(name: 'queuePlayedWindowSignal'));

// Signal for previous track in queue
final FlutterComputed<SimpleTrackDto?> previousTrackSignal = computed(
  () => queueNeighborhoodSignal().value?.previous,
  options: const ComputedOptions(name: 'previousTrackSignal'),
);

// Signal for next track in queue
final FlutterComputed<SimpleTrackDto?> nextTrackSignal = computed(
  () => queueNeighborhoodSignal().value?.next,
  options: const ComputedOptions(name: 'nextTrackSignal'),
);

// Store color scheme, updated automatically when local cover URI changes
final FlutterSignal<ColorScheme?> colorSchemeSignal = signal<ColorScheme?>(
  null,
);

// ThemeData built together with [colorSchemeSignal], so the app's root build
// only swaps an object instead of running the colour math per track.
final FlutterSignal<ThemeData?> appThemeSignal = signal<ThemeData?>(null);

// Accent color
final FlutterComputed<Color> accentColorSignal = computed(
  () => colorSchemeSignal()?.primary ?? defaultAccentColor,
  options: const ComputedOptions(name: 'accentColorSignal'),
);

// Player bar background color
final FlutterComputed<Color> playerBarColorSignal = computed(
  () => surfaceOverlay(colorSchemeSignal()?.surfaceContainerHighest),
  options: const ComputedOptions(name: 'playerBarColorSignal'),
);

// Sync palette with Rust for Vibe effect
final EffectCleanup _vibePaletteEffect = effect(() {
  if (Platform.isAndroid) return; // no wave shader on Android
  final scheme = colorSchemeSignal();
  final ctx = appContextSignal.value;
  if (scheme != null && ctx != null) {
    unawaited(
      rust.setVibePalette(
        ctx: ctx,
        colors: Float32List.fromList(vibePalette(scheme)),
      ),
    );
  }
});

// Buffering indicator that only shows once the track has been stalled > 3s,
// to avoid flickering on short buffering hiccups.
final Debouncer _bufferingDelayDebouncer = Debouncer();
final FlutterSignal<bool> showBufferingIndicatorSignal = signal(false);
final EffectCleanup _bufferingDelayEffect = effect(() {
  final state = playerStateSignal();
  final stalled = state != null && !state.isPlaying && state.isBuffering;

  if (!stalled) {
    _bufferingDelayDebouncer.cancel();
    showBufferingIndicatorSignal.value = false;
    return;
  }

  _bufferingDelayDebouncer.runOnce(() {
    showBufferingIndicatorSignal.value = true;
  }, const Duration(seconds: 3));
});

// Windows taskbar thumbnail toolbar is handled natively in Rust
// (src/rust/src/audio/taskbar.rs): button state is derived from audio signals
// there, and WM_COMMAND actions go straight to the audio actor / library
// logic without crossing the FFI boundary.

// Track position from progress
final FlutterComputed<double> playerPositionMsSignal = computed(
  () => (playerProgressSignal.value?.positionMs ?? 0).toDouble(),
  options: const ComputedOptions(name: 'playerPositionMsSignal'),
);

final FlutterSignal<bool> showLyricsSignal = signal<bool>(false);
final FlutterSignal<bool> hideLyricsOverlaySignal = signal<bool>(false);

/// True while the lyrics text for the currently displayed track is still
/// being fetched, or once fetched turns out empty. Used to keep the
/// background scrim off in both cases — dimming only comes back once
/// actual lyrics lines have loaded.
final FlutterSignal<bool> lyricsSuppressDimSignal = signal<bool>(false);

// Reset overlay visibility on track change
final EffectCleanup _lyricsOverlayResetEffect = effect(() {
  currentTrackIdSignal(); // Just call to track dependency
  hideLyricsOverlaySignal.value = false;
  lyricsSuppressDimSignal.value = false;
});

final FlutterSignal<EqualizerDto?> equalizerSignal = signal<EqualizerDto?>(
  null,
);
final FlutterSignal<List<AudioEffectDto>> audioEffectsSignal =
    signal<List<AudioEffectDto>>([]);

Future<void> refreshEqualizer() async {
  final ctx = appContextSignal.value;
  if (ctx == null) return;
  equalizerSignal.value = await rust.getEqualizer(ctx: ctx);
}

Future<void> refreshAudioEffects() async {
  final ctx = appContextSignal.value;
  if (ctx == null) return;
  audioEffectsSignal.value = await rust.getAudioEffects(ctx: ctx);
}

// Global playback control methods
class PlaybackController {
  static Future<void> playTrack(String trackId) =>
      runRustAction((ctx) => rust.playTrack(ctx: ctx, trackId: trackId));
  static Future<void> playLikedTrack(String trackId) =>
      runRustAction((ctx) => rust.playLikedTrack(ctx: ctx, trackId: trackId));
  static Future<void> playAlbumTrack(int albumId, String trackId) =>
      runRustAction(
        (ctx) =>
            rust.playAlbumTrack(ctx: ctx, albumId: albumId, trackId: trackId),
      );
  static Future<void> playPlaylistTrack(String uid, int kind, String trackId) =>
      runRustAction(
        (ctx) => rust.playPlaylistTrack(
          ctx: ctx,
          uid: uid,
          kind: kind,
          trackId: trackId,
        ),
      );
  static Future<void> playPlaylist(String uid, int kind) =>
      runRustAction((ctx) => rust.playPlaylist(ctx: ctx, uid: uid, kind: kind));
  static Future<void> togglePlay() {
    // Decide from what the button shows, not from Rust's momentary flag: while
    // a track is being swapped Rust reports isPlaying=false, so a plain toggle
    // would resume instead of pausing the track the user is looking at.
    if (stablePlayingSignal.peek()) return pause();
    _userPausePending = false;
    return runRustAction((ctx) => rust.play(ctx: ctx));
  }

  static Future<void> play() {
    _userPausePending = false;
    return runRustAction((ctx) => rust.play(ctx: ctx));
  }

  static Future<void> pause() {
    final wasPlaying = stablePlayingSignal.peek();
    if (wasPlaying) _userPausePending = true;
    return runRustAction((ctx) => rust.pause(ctx: ctx)).then((ok) {
      if (wasPlaying && !ok) _userPausePending = false;
    });
  }

  static Future<void> next() => runRustAction((ctx) => rust.playNext(ctx: ctx));
  static Future<void> prev() => runRustAction((ctx) => rust.playPrev(ctx: ctx));

  /// Always moves to the previous queue track, unlike [prev] which restarts
  /// the current track once it has been playing for a while.
  static Future<void> previousTrack() =>
      runRustAction((ctx) => rust.playPreviousTrack(ctx: ctx));

  /// Jumps straight to the queue track at absolute [index]. No optimistic
  /// updates: Rust emits PlaybackStateChanged, which refreshes
  /// [playerStateSignal] and (via the queueRevision bump)
  /// [queueNeighborhoodSignal].
  static Future<void> jumpToQueueIndex(int index) =>
      runRustAction((ctx) => rust.queueJumpTo(ctx: ctx, index: index));

  /// Removes the queue track at absolute [index]. The queue list refetches
  /// itself through the queueRevision bump in the emitted state.
  static Future<void> removeFromQueueAt(int index) =>
      runRustAction((ctx) => rust.queueRemoveAt(ctx: ctx, index: index));

  /// Moves the queue track from absolute index [from] to [to]. [to] is the
  /// final position of the item in the list after the removal, matching the
  /// `onReorderItem` semantics used by the queue panel.
  static Future<void> reorderQueue(int from, int to) =>
      runRustAction((ctx) => rust.queueReorder(ctx: ctx, from: from, to: to));

  /// Puts [trackId] right after the currently playing track. Returns whether
  /// the call succeeded, so callers can show their own success feedback.
  static Future<bool> playTrackNextInQueue(String trackId) =>
      runRustAction((ctx) => rust.queueAddNext(ctx: ctx, trackId: trackId));

  /// Appends [trackId] to the end of the playback queue. Returns whether the
  /// call succeeded, so callers can show their own success feedback.
  static Future<bool> addTrackToQueue(String trackId) =>
      runRustAction((ctx) => rust.queueAddLast(ctx: ctx, trackId: trackId));

  /// Drops every upcoming track; the current one keeps playing. The queue
  /// list refetches itself through the queueRevision bump in the emitted
  /// state.
  static Future<bool> clearQueue() =>
      runRustAction((ctx) => rust.queueClear(ctx: ctx));

  static Future<void> toggleShuffle() =>
      runRustAction((ctx) => rust.toggleShuffle(ctx: ctx));
  static Future<void> toggleRepeat() =>
      runRustAction((ctx) => rust.toggleRepeatMode(ctx: ctx));

  /// Sets the repeat mode to an exact value instead of cycling it. Used where
  /// the target mode is known precisely, e.g. the Android media notification
  /// (AudioServiceRepeatMode has none/all/one and no toggle semantics).
  static Future<void> setRepeatMode(RepeatModeDto mode) =>
      runRustAction((ctx) => rust.setRepeatMode(ctx: ctx, mode: mode));

  /// Enables or disables shuffle directly instead of toggling, mirroring
  /// [setRepeatMode] for the Android media notification.
  static Future<void> setShuffle({required bool enabled}) =>
      runRustAction((ctx) => rust.setShuffle(ctx: ctx, enabled: enabled));
  static Future<void> stop() => runRustAction((ctx) => rust.stop(ctx: ctx));
  static Future<bool> toggleLike({required String trackId}) async {
    // Optimistic list update (instant); the Rust stream reconciles after.
    // Unlike works by id; insertion needs the DTO: the playhead neighbourhood
    // first, then the liked cache (re-like). A fresh like of a track outside
    // that neighbourhood skips the optimistic insert — the confirmed update
    // still lands via the liked-tracks stream.
    final baseId = baseTrackId(trackId);
    SimpleTrackDto? dto;
    for (final t in queueTracksSignal.value) {
      if (baseTrackId(t.id) == baseId) {
        dto = t;
        break;
      }
    }
    dto ??= findLikedDto(baseId);
    final applied = applyLikeOptimistic(trackId: trackId, track: dto);
    final confirmed = await runRustAction(
      (ctx) => rust.toggleLike(ctx: ctx, trackId: trackId),
    );
    // Rust rolled its state back; undo the optimistic list edit as well so
    // both sides show the same (server) truth.
    if (!confirmed) {
      applyLikeOptimistic(trackId: trackId, track: dto, liked: !applied);
    }
    return confirmed;
  }

  static Future<void> toggleDislike({required String trackId}) =>
      runRustAction((ctx) => rust.toggleDislike(ctx: ctx, trackId: trackId));

  static Future<void> startTrackWave(String trackId, [String? title]) =>
      runRustAction(
        (ctx) => rust.startWave(
          ctx: ctx,
          seeds: [
            if (title != null) 'track:$trackId:$title' else 'track:$trackId',
          ],
        ),
      );
  static Future<void> changeVolume(int volume) =>
      runRustAction((ctx) => rust.setVolume(ctx: ctx, volume: volume));
  static Future<void> changeTransientVolumeGain(int gain) =>
      runRustAction((ctx) => rust.setTransientVolumeGain(ctx: ctx, gain: gain));
  static Future<void> seekTo(Duration duration) {
    // Optimistic update so the timeline stays at the new position even while
    // paused (progress events only tick during playback, and the seek echo
    // from Rust may take a moment to arrive).
    final current = playerProgressSignal.peek();
    if (current != null) {
      final pos = duration.inMilliseconds.clamp(0, current.durationMs);
      playerProgressSignal.value = PlaybackProgressDto(
        positionMs: pos,
        durationMs: current.durationMs,
      );
    }
    return runRustAction(
      (ctx) => rust.seek(ctx: ctx, positionMs: duration.inMilliseconds),
    );
  }

  static Future<void> setQuality(AudioQuality quality) =>
      runRustAction((ctx) async {
        await rust.setAudioQuality(ctx: ctx, quality: quality);
        audioQualitySignal.value = quality;
      });

  static Future<void> setEqualizerEnabled({required bool enabled}) =>
      runRustAction((ctx) async {
        await rust.setEqualizerEnabled(ctx: ctx, enabled: enabled);
        await refreshEqualizer();
      });

  static Future<void> setEqualizerBand(int index, double gainDb) =>
      runRustAction((ctx) async {
        await rust.setEqualizerBand(ctx: ctx, index: index, gainDb: gainDb);
        // Local update for smoothness
        final current = equalizerSignal.value;
        if (current != null) {
          final newBands = List<BandDto>.from(current.bands);
          newBands[index] = BandDto(
            frequency: current.bands[index].frequency,
            gainDb: gainDb,
            index: index,
          );
          equalizerSignal.value = EqualizerDto(
            enabled: current.enabled,
            bands: newBands,
          );
        }
      });

  static Future<void> resetEqualizer() => runRustAction((ctx) async {
    final current = equalizerSignal.value;
    if (current != null) {
      for (var i = 0; i < current.bands.length; i++) {
        await rust.setEqualizerBand(ctx: ctx, index: i, gainDb: 0);
      }
      await refreshEqualizer();
    }
  });

  static Future<void> setEffectEnabled(String id, {required bool enabled}) =>
      runRustAction((ctx) async {
        await rust.setEffectEnabled(ctx: ctx, id: id, enabled: enabled);
        await refreshAudioEffects();
      });

  static Future<void> setEffectParam(String id, int index, double value) =>
      runRustAction((ctx) async {
        await rust.setEffectParam(ctx: ctx, id: id, index: index, value: value);
        // Local update for smoothness
        final currentEffects = List<AudioEffectDto>.from(
          audioEffectsSignal.value,
        );
        final effectIndex = currentEffects.indexWhere((e) => e.id == id);
        if (effectIndex != -1) {
          final effect = currentEffects[effectIndex];
          final newParams = List<EffectParamDto>.from(effect.params);
          final param = newParams[index];
          newParams[index] = EffectParamDto(
            name: param.name,
            value: value,
            defaultValue: param.defaultValue,
            min: param.min,
            max: param.max,
            step: param.step,
            unit: param.unit,
            index: index,
          );
          currentEffects[effectIndex] = AudioEffectDto(
            id: effect.id,
            name: effect.name,
            enabled: effect.enabled,
            params: newParams,
          );
          audioEffectsSignal.value = currentEffects;
        }
      });

  static Future<void> resetEffect(String id) => runRustAction((ctx) async {
    await rust.resetEffect(ctx: ctx, id: id);
    await refreshAudioEffects();
  });
}
