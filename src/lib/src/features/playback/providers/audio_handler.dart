import 'package:audio_service/audio_service.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/models.dart' as rust;

class YaymaAudioHandler extends BaseAudioHandler {
  YaymaAudioHandler() {
    _initSignals();
  }

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

      playbackState.add(
        PlaybackState(
          controls: [
            dislikeControl,
            MediaControl.skipToPrevious,
            if (isPlaying) MediaControl.pause else MediaControl.play,
            MediaControl.skipToNext,
            likeControl,
          ],
          systemActions: const {
            MediaAction.seek,
            MediaAction.seekForward,
            MediaAction.seekBackward,
          },
          playing: isPlaying,
          androidCompactActionIndices: const [
            0,
            2,
            4,
          ], // Show Like, Play, Dislike in compact
          processingState: processingState,
          repeatMode: _mapRepeatMode(repeatMode),
          shuffleMode: isShuffled
              ? AudioServiceShuffleMode.all
              : AudioServiceShuffleMode.none,
          updatePosition: Duration(milliseconds: currentPosition.toInt()),
        ),
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
