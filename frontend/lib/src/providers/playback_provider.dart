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

// Сигналы состояния
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

  // Инициализация потока событий
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
  // Активируем эффекты
  _activatePersistentColorScheme();
  _activateVibePalette();
  if (Platform.isWindows) {
    _activateTaskbarEffect();
  }
}

void _activatePersistentColorScheme() => _persistentColorSchemeEffect;
void _activateVibePalette() => _vibePaletteEffect;
void _activateTaskbarEffect() => _taskbarEffect;

// Метаданные трека (без прогресса)
final FlutterComputed<
  ({
    String? albumId,
    List<TrackArtistDto> artists,
    String? codec,
    String? coverUrl,
    List<String> currentWaveSeeds,
    String? id,
    bool isDisliked,
    bool isLiked,
    bool isPlaying,
    bool isShuffled,
    RepeatModeDto repeatMode,
    String title,
    String? version,
    int volume,
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
    isPlaying: state?.isPlaying ?? false,
    isLiked: state?.currentTrack?.isLiked ?? false,
    isDisliked: state?.currentTrack?.isDisliked ?? false,
    isShuffled: state?.isShuffled ?? false,
    repeatMode: state?.repeatMode ?? RepeatModeDto.none,
    volume: state?.volume ?? 100,
    currentWaveSeeds: state?.currentWaveSeeds ?? [],
    albumId: state?.currentTrack?.albumId,
    codec: state?.codec,
  );
}, debugLabel: 'trackMetadataSignal');

// Прогресс трека (обновляется часто)
final FlutterComputed<({double durationMs, double positionMs})>
trackProgressSignal = computed(() {
  final progress = playerProgressSignal.value;
  return (
    durationMs: (progress?.durationMs ?? 1).toDouble(),
    positionMs: (progress?.positionMs ?? 0).toDouble(),
  );
}, debugLabel: 'trackProgressSignal');

// Сигнал только для URL обложки, чтобы не триггерить расчет при лайках/паузе
final FlutterComputed<String?> currentCoverUrlSignal = computed(
  () => trackMetadataSignal().coverUrl,
  debugLabel: 'currentCoverUrlSignal',
);

// Цветовая схема из обложки
final FutureSignal<ColorScheme?> colorSchemeSignal = computedAsync(() async {
  final url = currentCoverUrlSignal();
  if (url == null) return null;

  final path = await rust.getCachedImagePath(url: url);
  if (path == null) return null;

  // Ограничиваем разрешение до минимума для квантования
  return ColorScheme.fromImageProvider(
    provider: ResizeImage(FileImage(File(path)), width: 32, height: 32),
    brightness: Brightness.dark,
  );
}, debugLabel: 'colorSchemeSignal');

// Храним последнюю успешную цветовую схему, чтобы не было отката цветов при смене трека
final FlutterSignal<ColorScheme?> _persistentColorScheme = signal<ColorScheme?>(
  null,
);

// Эффект для обновления персистентной цветовой схемы
final EffectCleanup _persistentColorSchemeEffect = effect(() {
  final url = currentCoverUrlSignal();
  final scheme = colorSchemeSignal().value;

  if (url == null) {
    _persistentColorScheme.value = null;
  } else if (scheme != null) {
    _persistentColorScheme.value = scheme;
  }
});

// Акцентный цвет
final FlutterComputed<Color> accentColorSignal = computed(
  () => _persistentColorScheme()?.primary ?? Colors.deepOrange,
  debugLabel: 'accentColorSignal',
);

// Цвет панели плеера
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

// Синхронизация палитры с Rust (для Vibe-эффекта)
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

// Храним последнее состояние, чтобы не спамить системными вызовами
String? _lastTaskbarTrackId;
bool? _lastTaskbarIsPlaying;

// Эффект для обновления кнопок в панели задач Windows
final EffectCleanup _taskbarEffect = effect(() {
  if (!Platform.isWindows) return;
  final metadata = trackMetadataSignal();

  // Обновляем только если изменился трек или статус проигрывания
  if (_lastTaskbarTrackId == metadata.id &&
      _lastTaskbarIsPlaying == metadata.isPlaying) {
    return;
  }
  _lastTaskbarTrackId = metadata.id;
  _lastTaskbarIsPlaying = metadata.isPlaying;

  unawaited(() async {
    try {
      await WindowsTaskbar.setThumbnailToolbar([
        ThumbnailToolbarButton(
          ThumbnailToolbarAssetIcon(
            metadata.isDisliked
                ? 'assets/icons/disliked.ico'
                : 'assets/icons/dislike.ico',
          ),
          metadata.isDisliked ? 'Убрать дизлайк' : 'Дизлайк',
          () {
            if (metadata.id != null) {
              unawaited(
                PlaybackController.toggleDislike(trackId: metadata.id!),
              );
            }
          },
        ),
        ThumbnailToolbarButton(
          ThumbnailToolbarAssetIcon(
            metadata.isShuffled
                ? 'assets/icons/shuffle_on.ico'
                : 'assets/icons/shuffle.ico',
          ),
          metadata.isShuffled
              ? 'Выключить перемешивание'
              : 'Включить перемешивание',
          () => unawaited(PlaybackController.toggleShuffle()),
        ),
        ThumbnailToolbarButton(
          ThumbnailToolbarAssetIcon('assets/icons/skip_previous.ico'),
          'Назад',
          () => unawaited(PlaybackController.prev()),
        ),
        ThumbnailToolbarButton(
          ThumbnailToolbarAssetIcon(
            metadata.isPlaying
                ? 'assets/icons/pause.ico'
                : 'assets/icons/play.ico',
          ),
          metadata.isPlaying ? 'Пауза' : 'Играть',
          () => unawaited(PlaybackController.togglePlay()),
        ),
        ThumbnailToolbarButton(
          ThumbnailToolbarAssetIcon('assets/icons/skip_next.ico'),
          'Вперед',
          () => unawaited(PlaybackController.next()),
        ),
        ThumbnailToolbarButton(
          ThumbnailToolbarAssetIcon(
            metadata.repeatMode == RepeatModeDto.none
                ? 'assets/icons/repeat.ico'
                : (metadata.repeatMode == RepeatModeDto.single
                      ? 'assets/icons/repeat_one.ico'
                      : 'assets/icons/repeat_on.ico'),
          ),
          'Повтор',
          () => unawaited(PlaybackController.toggleRepeat()),
        ),
        ThumbnailToolbarButton(
          ThumbnailToolbarAssetIcon(
            metadata.isLiked
                ? 'assets/icons/liked.ico'
                : 'assets/icons/like.ico',
          ),
          metadata.isLiked ? 'Убрать лайк' : 'Лайк',
          () {
            if (metadata.id != null) {
              unawaited(PlaybackController.toggleLike(trackId: metadata.id!));
            }
          },
        ),
      ]);

      final artistStr = metadata.artists.map((a) => a.name).join(', ');
      var title = metadata.title;
      if (artistStr.isNotEmpty) {
        title = '$artistStr - $title';
      }
      await WindowsTaskbar.setThumbnailTooltip(title);
    } on Exception catch (_) {
      // Игнорируем ошибки, если окно временно недоступно
    }
  }());
});

// Позиция трека (теперь берется из прогресса)
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

// Глобальные методы управления
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
