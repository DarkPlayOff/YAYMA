import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/app/init.dart';
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

StreamSubscription<rust.AppEvent>? _eventSub;

/// Deduplicates concurrent [initPlayback] calls (login + auto-login racing).
Future<void>? _initPlaybackFuture;

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
  await _eventSub?.cancel();
  _eventSub = null;

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

  await _eventSub?.cancel();
  _eventSub = null;

  // Initialize app event stream
  _eventSub = rust.appEventStream(ctx: ctx).listen((event) {
    switch (event) {
      case rust.AppEvent_PlaybackStateChanged(field0: final state):
        playerStateSignal.value = state;
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
          showAppError(humanizeError(message));
          unawaited(AppInit.logout());
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

  audioQualitySignal.value = await rust.getAudioQuality(ctx: ctx);

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

// Track metadata (static data only)
final FlutterComputed<
  ({
    String? id,
    String title,
    String? version,
    List<TrackArtistDto> artists,
    String? coverUrl,
    String? albumId,
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
    coverUrl: state?.currentTrack?.coverUrl,
    albumId: state?.currentTrack?.albumId,
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

// Signal for queue tracks
final FutureSignal<List<SimpleTrackDto>> queueTracksSignal = computedAsync(
  () async {
    final ctx = appContextSignal();
    final state = playerStateSignal();
    if (ctx == null || state == null) return const [];

    // Depend on key queue parameters to re-trigger when queue changes
    final _ = state.queueCount;
    final _ = state.isShuffled;

    return await rust.getQueue(ctx: ctx);
  },
  options: const AsyncSignalOptions(name: 'queueTracksSignal'),
);

// Signal for previous track in queue
final FlutterComputed<SimpleTrackDto?> previousTrackSignal = computed(() {
  final state = playerStateSignal.value;
  final queue = queueTracksSignal().value ?? const [];
  if (state == null || queue.isEmpty) return null;

  final index = state.queueIndex;
  final repeatMode = state.repeatMode;

  if (index > 0 && index < queue.length) {
    return queue[index - 1];
  } else if (index == 0 && repeatMode == RepeatModeDto.all) {
    return queue.last;
  }
  return null;
}, options: const ComputedOptions(name: 'previousTrackSignal'));

// Signal for next track in queue
final FlutterComputed<SimpleTrackDto?> nextTrackSignal = computed(() {
  final state = playerStateSignal.value;
  final queue = queueTracksSignal().value ?? const [];
  if (state == null || queue.isEmpty) return null;

  final index = state.queueIndex;
  final repeatMode = state.repeatMode;

  if (index + 1 < queue.length) {
    return queue[index + 1];
  } else if (index + 1 == queue.length && repeatMode == RepeatModeDto.all) {
    return queue.first;
  }
  return null;
}, options: const ComputedOptions(name: 'nextTrackSignal'));

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
  static Future<void> playAlbum(int albumId) =>
      runRustAction((ctx) => rust.playAlbum(ctx: ctx, albumId: albumId));
  static Future<void> togglePlay() {
    // A pause the user asked for must not wait out the track-switch debounce.
    final wasPlaying = stablePlayingSignal.peek();
    if (wasPlaying) _userPausePending = true;
    return runRustAction((ctx) => rust.togglePlayPause(ctx: ctx)).then((ok) {
      // The pause may have failed; don't let the flag eat the next transition.
      if (wasPlaying && !ok) _userPausePending = false;
    });
  }

  static Future<void> play() {
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
  static Future<void> toggleShuffle() =>
      runRustAction((ctx) => rust.toggleShuffle(ctx: ctx));
  static Future<void> toggleRepeat() =>
      runRustAction((ctx) => rust.toggleRepeatMode(ctx: ctx));
  static Future<void> stop() => runRustAction((ctx) => rust.stop(ctx: ctx));
  static Future<bool> toggleLike({required String trackId}) async {
    // Optimistic list update (instant); the Rust stream reconciles after.
    // Unlike works by id; insertion needs the DTO: current queue first,
    // then the liked cache (re-like).
    final baseId = baseTrackId(trackId);
    SimpleTrackDto? dto;
    for (final t in queueTracksSignal.value.value ?? const <SimpleTrackDto>[]) {
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
