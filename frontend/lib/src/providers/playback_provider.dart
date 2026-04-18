import 'dart:async';
import 'dart:io' show File, Platform;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:windows_taskbar/windows_taskbar.dart';
import 'package:yayma/src/providers/auth_provider.dart';
import 'package:yayma/src/providers/library_provider.dart';
import 'package:yayma/src/providers/notification_provider.dart';
import 'package:yayma/src/rust/api/audio_fx.dart' as rust;
import 'package:yayma/src/rust/api/library.dart' as rust;
import 'package:yayma/src/rust/api/models.dart';
import 'package:yayma/src/rust/api/playback.dart' as rust;
import 'package:yayma/src/rust/api/simple.dart' as rust;

// Player state signals
final FlutterSignal<PlaybackState?> playerStateSignal = signal<PlaybackState?>(
  null,
);
final FlutterSignal<PlaybackProgressDto?> playerProgressSignal =
    signal<PlaybackProgressDto?>(null);
final FlutterSignal<Float32List> vibeTickSignal = signal<Float32List>(
  Float32List(0),
);

final FlutterSignal<AudioQuality> audioQualitySignal = signal<AudioQuality>(
  AudioQuality.normal,
);

StreamSubscription<rust.AppEvent>? _eventSub;

Future<void> initPlayback() async {
  final ctx = appContextSignal.value;
  if (ctx == null) return;

  await _eventSub?.cancel();

  // Initialize app event stream
  _eventSub = rust.appEventStream(ctx: ctx).listen((event) {
    switch (event) {
      case rust.AppEvent_PlaybackStateChanged(field0: final state):
        playerStateSignal.value = state;
      case rust.AppEvent_PlaybackProgress(field0: final progress):
        playerProgressSignal.value = progress;
      case rust.AppEvent_VibeTick(field0: final tick):
        vibeTickSignal.value = tick;
      case rust.AppEvent_LikedTracksChanged(field0: final tracks):
        likedTracksSignal.value = tracks;
      case rust.AppEvent_Error(field0: final message):
        showAppError(message);
      case _:
        break;
    }
  });

  audioQualitySignal.value = await rust.getAudioQuality(ctx: ctx);
  
  _activatePersistentColorScheme();
  _activateVibePalette();
  if (Platform.isWindows) {
    _activateTaskbarEffect();
  }
}

void _activatePersistentColorScheme() => _persistentColorSchemeEffect;
void _activateVibePalette() => _vibePaletteEffect;
void _activateTaskbarEffect() => _taskbarEffect;

// Signal for current track ID only
final FlutterComputed<String?> currentTrackIdSignal = computed(
  () => playerStateSignal.value?.currentTrack?.id,
  debugLabel: 'currentTrackIdSignal',
);

// Signal for volume only
final FlutterComputed<int> playerVolumeSignal = computed(
  () => playerStateSignal.value?.volume ?? 100,
  debugLabel: 'playerVolumeSignal',
);

// Signal for playback status only
final FlutterComputed<bool> isPlayingSignal = computed(
  () => playerStateSignal.value?.isPlaying ?? false,
  debugLabel: 'isPlayingSignal',
);

// Shuffle signal
final FlutterComputed<bool> isShuffledSignal = computed(
  () => playerStateSignal.value?.isShuffled ?? false,
  debugLabel: 'isShuffledSignal',
);

// Repeat mode signal
final FlutterComputed<RepeatModeDto> repeatModeSignal = computed(
  () => playerStateSignal.value?.repeatMode ?? RepeatModeDto.none,
  debugLabel: 'repeatModeSignal',
);

// Signals for liking/disliking the current track
final FlutterComputed<bool> isLikedSignal = computed(
  () => playerStateSignal.value?.currentTrack?.isLiked ?? false,
  debugLabel: 'isLikedSignal',
);

final FlutterComputed<bool> isDislikedSignal = computed(
  () => playerStateSignal.value?.currentTrack?.isDisliked ?? false,
  debugLabel: 'isDislikedSignal',
);

// Signal for current wave seeds
final FlutterComputed<List<String>> currentWaveSeedsSignal = computed(
  () => playerStateSignal.value?.currentWaveSeeds ?? [],
  debugLabel: 'currentWaveSeedsSignal',
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
}, debugLabel: 'trackMetadataSignal');

// Track progress (updates frequently)
final FlutterComputed<({double durationMs, double positionMs})>
trackProgressSignal = computed(() {
  final progress = playerProgressSignal.value;
  return (
    durationMs: (progress?.durationMs ?? 1).toDouble(),
    positionMs: (progress?.positionMs ?? 0).toDouble(),
  );
}, debugLabel: 'trackProgressSignal');

// Signal for cover URL only to avoid re-calculating on pause/likes
final FlutterComputed<String?> currentCoverUrlSignal = computed(
  () => playerStateSignal.value?.currentTrack?.coverUrl,
  debugLabel: 'currentCoverUrlSignal',
);

// Color scheme generated from cover image
final FutureSignal<ColorScheme?> colorSchemeSignal = computedAsync(() async {
  final url = currentCoverUrlSignal();
  if (url == null) return null;

  final path = await rust.getCachedImagePath(url: url);
  if (path == null) return null;

  // Resize to minimum for faster quantization
  return ColorScheme.fromImageProvider(
    provider: ResizeImage(FileImage(File(path)), width: 32, height: 32),
    brightness: Brightness.dark,
  );
}, debugLabel: 'colorSchemeSignal');

// Store last successful color scheme to prevent flickering during track changes
final FlutterSignal<ColorScheme?> _persistentColorScheme = signal<ColorScheme?>(
  null,
);

// Effect to update persistent color scheme
final EffectCleanup _persistentColorSchemeEffect = effect(() {
  final url = currentCoverUrlSignal();
  final scheme = colorSchemeSignal().value;

  if (url == null) {
    _persistentColorScheme.value = null;
  } else if (scheme != null) {
    _persistentColorScheme.value = scheme;
  }
});

// Accent color
final FlutterComputed<Color> accentColorSignal = computed(
  () => _persistentColorScheme()?.primary ?? Colors.deepOrange,
  debugLabel: 'accentColorSignal',
);

// Player bar background color
final FlutterComputed<Color> playerBarColorSignal = computed(
  () =>
      Color.lerp(
        _persistentColorScheme()?.surfaceContainerHighest,
        Colors.black,
        0.4,
      ) ??
      const Color(0xFF181818),
  debugLabel: 'playerBarColorSignal',
);

// Sync palette with Rust for Vibe effect
final EffectCleanup _vibePaletteEffect = effect(() {
  final scheme = colorSchemeSignal().value;
  final ctx = appContextSignal.value;
  if (scheme != null && ctx != null) {
    List<double> c(Color col) => [col.r, col.g, col.b];
    final p = [
      ...c(scheme.primary),
      ...c(scheme.secondary),
      ...c(scheme.tertiary),
      ...c(scheme.primaryContainer),
      ...c(scheme.secondaryContainer),
      ...c(scheme.tertiaryContainer),
    ];
    unawaited(
      rust.setVibePalette(
        ctx: ctx,
        colors: Float32List.fromList(p),
      ),
    );
  }
});

// Cache last state to avoid redundant system calls
String? _lastTaskbarTrackId;
bool? _lastTaskbarIsPlaying;
bool? _lastTaskbarIsLiked;
bool? _lastTaskbarIsDisliked;
bool? _lastTaskbarIsShuffled;
RepeatModeDto? _lastTaskbarRepeatMode;

// Windows taskbar thumbnail buttons update
final EffectCleanup _taskbarEffect = effect(() {
  if (!Platform.isWindows) return;

  final meta = trackMetadataSignal();
  final isPlaying = isPlayingSignal();
  final isLiked = isLikedSignal();
  final isDisliked = isDislikedSignal();
  final isShuffled = isShuffledSignal();
  final repeatMode = repeatModeSignal();

  // Update only if track or key status changed
  if (_lastTaskbarTrackId == meta.id &&
      _lastTaskbarIsPlaying == isPlaying &&
      _lastTaskbarIsLiked == isLiked &&
      _lastTaskbarIsDisliked == isDisliked &&
      _lastTaskbarIsShuffled == isShuffled &&
      _lastTaskbarRepeatMode == repeatMode) {
    return;
  }

  _lastTaskbarTrackId = meta.id;
  _lastTaskbarIsPlaying = isPlaying;
  _lastTaskbarIsLiked = isLiked;
  _lastTaskbarIsDisliked = isDisliked;
  _lastTaskbarIsShuffled = isShuffled;
  _lastTaskbarRepeatMode = repeatMode;

  unawaited(() async {
    try {
      await WindowsTaskbar.setThumbnailToolbar([
        ThumbnailToolbarButton(
          ThumbnailToolbarAssetIcon(
            isDisliked
                ? 'assets/icons/disliked.ico'
                : 'assets/icons/dislike.ico',
          ),
          isDisliked ? 'Убрать дизлайк' : 'Дизлайк',
          () {
            if (meta.id != null) {
              unawaited(PlaybackController.toggleDislike(trackId: meta.id!));
            }
          },
        ),
        ThumbnailToolbarButton(
          ThumbnailToolbarAssetIcon(
            isShuffled
                ? 'assets/icons/shuffle_on.ico'
                : 'assets/icons/shuffle.ico',
          ),
          isShuffled ? 'Выключить перемешивание' : 'Включить перемешивание',
          () => unawaited(PlaybackController.toggleShuffle()),
        ),
        ThumbnailToolbarButton(
          ThumbnailToolbarAssetIcon('assets/icons/skip_previous.ico'),
          'Назад',
          () => unawaited(PlaybackController.prev()),
        ),
        ThumbnailToolbarButton(
          ThumbnailToolbarAssetIcon(
            isPlaying ? 'assets/icons/pause.ico' : 'assets/icons/play.ico',
          ),
          isPlaying ? 'Пауза' : 'Играть',
          () => unawaited(PlaybackController.togglePlay()),
        ),
        ThumbnailToolbarButton(
          ThumbnailToolbarAssetIcon('assets/icons/skip_next.ico'),
          'Вперед',
          () => unawaited(PlaybackController.next()),
        ),
        ThumbnailToolbarButton(
          ThumbnailToolbarAssetIcon(
            repeatMode == RepeatModeDto.none
                ? 'assets/icons/repeat.ico'
                : (repeatMode == RepeatModeDto.single
                      ? 'assets/icons/repeat_one.ico'
                      : 'assets/icons/repeat_on.ico'),
          ),
          'Повтор',
          () => unawaited(PlaybackController.toggleRepeat()),
        ),
        ThumbnailToolbarButton(
          ThumbnailToolbarAssetIcon(
            isLiked ? 'assets/icons/liked.ico' : 'assets/icons/like.ico',
          ),
          isLiked ? 'Убрать лайк' : 'Лайк',
          () {
            if (meta.id != null) {
              unawaited(PlaybackController.toggleLike(trackId: meta.id!));
            }
          },
        ),
      ]);

      final artistStr = meta.artists.map((a) => a.name).join(', ');
      var title = meta.title;
      if (artistStr.isNotEmpty) {
        title = '$artistStr - $title';
      }
      await WindowsTaskbar.setThumbnailTooltip(title);
    } on Exception catch (_) {
      // Ignore errors if window is temporarily unavailable
    }
  }());
});

// Track position from progress
final FlutterComputed<double> playerPositionMsSignal = computed(
  () => (playerProgressSignal.value?.positionMs ?? 0).toDouble(),
  debugLabel: 'playerPositionMsSignal',
);

final FlutterSignal<bool> showLyricsSignal = signal<bool>(false);

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
  static Future<void> togglePlay() =>
      runRustAction((ctx) => rust.togglePlayPause(ctx: ctx));
  static Future<void> next() => runRustAction((ctx) => rust.playNext(ctx: ctx));
  static Future<void> prev() => runRustAction((ctx) => rust.playPrev(ctx: ctx));
  static Future<void> toggleShuffle() =>
      runRustAction((ctx) => rust.toggleShuffle(ctx: ctx));
  static Future<void> toggleRepeat() =>
      runRustAction((ctx) => rust.toggleRepeatMode(ctx: ctx));
  static Future<void> stop() => runRustAction((ctx) => rust.stop(ctx: ctx));
  static Future<void> toggleLike({required String trackId}) =>
      runRustAction((ctx) => rust.toggleLike(ctx: ctx, trackId: trackId));
  static Future<void> toggleDislike({required String trackId}) =>
      runRustAction((ctx) => rust.toggleDislike(ctx: ctx, trackId: trackId));
  static Future<void> startMyWave() => runRustAction(
    (ctx) => rust.startWave(ctx: ctx, seeds: ['user:onyourwave']),
  );
  static Future<void> startTrackWave(String trackId) => runRustAction(
    (ctx) => rust.startWave(ctx: ctx, seeds: ['track:$trackId']),
  );
  static Future<void> changeVolume(int volume) =>
      runRustAction((ctx) => rust.setVolume(ctx: ctx, volume: volume));
  static Future<void> seekTo(Duration duration) => runRustAction(
    (ctx) => rust.seek(ctx: ctx, positionMs: duration.inMilliseconds),
  );

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
