import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/models.dart' as rust;

class YaymaAudioHandler extends BaseAudioHandler {
  YaymaAudioHandler() {
    _initSignals();
  }

  // audio_service's native setState() rebuilds its action list and reads
  // androidCompactActionIndices without synchronization, so back-to-back
  // calls (e.g. buffering -> ready right at track start) can race and hit
  // an index that's momentarily out of bounds, crashing the app on some
  // Android versions (observed on 11). Debounce to collapse rapid
  // transitions into a single native call.
  Timer? _playbackStateDebounce;

  void _initSignals() {
    // Sync metadata
    effect(() {
      final meta = trackMetadataSignal();
      if (meta.id == null) {
        mediaItem.add(null);
        return;
      }

      // Use local if available, fallback to network immediately if not
      final artUri =
          localCoverUriSignal().value ??
          (meta.coverUrl != null ? Uri.parse(meta.coverUrl!) : null);

      // Use peek() to avoid rebuilding the notification every time the duration ticks
      final progress = trackProgressSignal.peek();

      mediaItem.add(
        MediaItem(
          id: meta.id!,
          album: meta.albumId,
          title: meta.title,
          artist: meta.artists.map((a) => a.name).join(', '),
          duration: Duration(milliseconds: progress.durationMs.toInt()),
          artUri: artUri,
          extras: {
            'version': meta.version,
            'codec': meta.codec,
          },
        ),
      );
    });

    // Sync playback state
    effect(() {
      final state = playerStateSignal();
      final isPlaying = state?.isPlaying ?? false;
      final processingState = _mapProcessingState(state);
      final repeatMode = state?.repeatMode;
      final isShuffled = state?.isShuffled ?? false;
      final currentTrack = state?.currentTrack;

      final dislikeControl = MediaControl.custom(
        androidIcon: (currentTrack?.isDisliked ?? false)
            ? 'drawable/disliked'
            : 'drawable/dislike',
        label: (currentTrack?.isDisliked ?? false) ? 'Undislike' : 'Dislike',
        name: 'dislike',
      );

      final likeControl = MediaControl.custom(
        androidIcon: (currentTrack?.isLiked ?? false)
            ? 'drawable/liked'
            : 'drawable/like',
        label: (currentTrack?.isLiked ?? false) ? 'Unlike' : 'Like',
        name: 'like',
      );
      // Use peek() for position to avoid spamming the Android IPC every 50ms,
      // which causes the notification to disappear or crash the system.
      final currentPosition = playerPositionMsSignal.peek();

      final newState = PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          if (isPlaying) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
          dislikeControl,
          likeControl,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        playing: isPlaying,
        // Only reference the built-in transport controls here. If a custom
        // action (like/dislike, which rely on app-supplied icon resources)
        // ever fails to resolve on the native side, the notification's
        // action list shrinks and a compact index pointing past the end
        // crashes the app (IndexOutOfBoundsException in
        // Notification$MediaStyle.makeMediaContentView, seen on Android 11).
        // Keeping compact indices within the guaranteed-present prefix
        // avoids that regardless of how many trailing custom actions land.
        androidCompactActionIndices: const [0, 1, 2],
        processingState: processingState,
        repeatMode: _mapRepeatMode(repeatMode),
        shuffleMode: isShuffled
            ? AudioServiceShuffleMode.all
            : AudioServiceShuffleMode.none,
        updatePosition: Duration(milliseconds: currentPosition.toInt()),
      );

      _playbackStateDebounce?.cancel();
      _playbackStateDebounce = Timer(
        const Duration(milliseconds: 120),
        () => playbackState.add(newState),
      );
    });
  }

  @override
  Future<void> customAction(String name, [Map<String, dynamic>? extras]) async {
    final trackId = playerStateSignal.peek()?.currentTrack?.id;
    if (trackId == null) return;

    if (name == 'like') {
      await PlaybackController.toggleLike(trackId: trackId);
    } else if (name == 'dislike') {
      await PlaybackController.toggleDislike(trackId: trackId);
    }
  }

  AudioProcessingState _mapProcessingState(rust.PlaybackState? state) {
    if (state == null) return AudioProcessingState.idle;
    if (state.isBuffering) return AudioProcessingState.buffering;
    if (state.currentTrack == null) return AudioProcessingState.idle;
    return AudioProcessingState.ready;
  }

  AudioServiceRepeatMode _mapRepeatMode(rust.RepeatModeDto? mode) {
    switch (mode) {
      case rust.RepeatModeDto.all:
        return AudioServiceRepeatMode.all;
      case rust.RepeatModeDto.single:
        return AudioServiceRepeatMode.one;
      case rust.RepeatModeDto.none:
      case null:
        return AudioServiceRepeatMode.none;
    }
  }

  @override
  Future<void> play() => PlaybackController.play();

  @override
  Future<void> pause() => PlaybackController.pause();

  @override
  Future<void> stop() => PlaybackController.stop();

  @override
  Future<void> skipToNext() => PlaybackController.next();

  @override
  Future<void> skipToPrevious() => PlaybackController.prev();

  @override
  Future<void> seek(Duration position) => PlaybackController.seekTo(position);

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    // Current PlaybackController only supports toggle, but we could implement direct set if needed
    // For now, just toggle if it doesn't match
    final current = repeatModeSignal();
    if (_mapRepeatMode(current) != repeatMode) {
      await PlaybackController.toggleRepeat();
    }
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    final current = isShuffledSignal();
    final target = shuffleMode == AudioServiceShuffleMode.all;
    if (current != target) {
      await PlaybackController.toggleShuffle();
    }
  }
}
