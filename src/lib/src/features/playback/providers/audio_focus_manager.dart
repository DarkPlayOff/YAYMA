import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';

/// Handles Android audio focus: pausing/resuming playback on transient
/// interruptions (calls, other apps) and ducking volume for notifications.
class AudioFocusManager {
  AudioFocusManager._();

  static StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  static EffectCleanup? _disposeSessionActiveEffect;
  static int? _originalVolume;
  static bool _isDucked = false;
  // null = not currently suppressed by an interruption; otherwise remembers
  // whether we were actually playing when the (possibly nested) interruption
  // started, so we only auto-resume what we auto-paused.
  static bool? _wasPlayingBeforeInterruption;

  static Future<void> initialize(AudioSession session) async {
    await _interruptionSub?.cancel();
    _interruptionSub = session.interruptionEventStream.listen(
      _handleInterruption,
      onError: (Object e, StackTrace st) {
        debugPrint('Audio interruption stream error: $e');
      },
    );

    _disposeSessionActiveEffect?.call();
    _disposeSessionActiveEffect = effect(() {
      final state = playerStateSignal();
      final isPlaying = state?.isPlaying ?? false;
      unawaited(_syncSessionActive(session, isPlaying));
    });
  }

  static Future<void> _handleInterruption(
    AudioInterruptionEvent event,
  ) async {
    try {
      await _applyInterruption(event);
    } on Object catch (e, st) {
      debugPrint('Audio interruption handling failed: $e\n$st');
    }
  }

  static Future<void> _applyInterruption(AudioInterruptionEvent event) async {
    if (event.begin) {
      switch (event.type) {
        case AudioInterruptionType.duck:
          if (!_isDucked) {
            _isDucked = true;
            final currentVolume = playerVolumeSignal.value;
            _originalVolume = currentVolume;
            final duckVolume = (currentVolume * 0.2).round().clamp(0, 100);
            await PlaybackController.changeVolume(duckVolume);
          }
        case AudioInterruptionType.pause:
        case AudioInterruptionType.unknown:
          // A stronger interruption (e.g. a call) can arrive while we're
          // still ducked from a weaker one; restore volume now since the
          // matching duck-end event isn't guaranteed after being
          // superseded like this.
          if (_isDucked) {
            _isDucked = false;
            if (_originalVolume != null) {
              await PlaybackController.changeVolume(_originalVolume!);
              _originalVolume = null;
            }
          }
          // Only capture on the outermost interruption so a nested one
          // doesn't overwrite it with the already-paused state.
          _wasPlayingBeforeInterruption ??= isPlayingSignal.value;
          if (isPlayingSignal.value) {
            await PlaybackController.pause();
          }
      }
    } else {
      switch (event.type) {
        case AudioInterruptionType.duck:
          if (_isDucked) {
            _isDucked = false;
            if (_originalVolume != null) {
              await PlaybackController.changeVolume(_originalVolume!);
              _originalVolume = null;
            }
          }
        case AudioInterruptionType.pause:
          // Only resume what we paused ourselves - not if the user paused
          // manually during the interruption, or nothing was playing to
          // begin with.
          if (_wasPlayingBeforeInterruption ?? false) {
            await PlaybackController.play();
          }
          _wasPlayingBeforeInterruption = null;
        case AudioInterruptionType.unknown:
          _wasPlayingBeforeInterruption = null;
      }
    }
  }

  static Future<void> _syncSessionActive(
    AudioSession session,
    bool isPlaying,
  ) async {
    try {
      if (isPlaying) {
        final granted = await session.setActive(true);
        if (!granted) {
          await PlaybackController.pause();
        }
      } else {
        await session.setActive(false);
      }
    } on Object catch (e, st) {
      debugPrint('Failed to sync audio session active state: $e\n$st');
    }
  }
}
