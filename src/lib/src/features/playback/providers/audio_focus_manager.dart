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
  // Tracks whether we currently hold audio focus, so re-running the
  // `isPlaying` effect (e.g. from a volume change pushing a new
  // PlaybackState) doesn't call setActive(true) again. On Android that
  // re-requests audio focus and replaces the focus-change listener, which
  // loses track of an in-progress duck and breaks its matching restore.
  static bool _sessionActive = false;
  // null = not currently suppressed by an interruption; otherwise remembers
  // whether we were actually playing when the (possibly nested) interruption
  // started, so we only auto-resume what we auto-paused.
  static bool? _wasPlayingBeforeInterruption;
  // Bumped on every new fade so an in-flight one aborts instead of fighting
  // a newer fade for the last word on the volume.
  static int _fadeToken = 0;

  static const _duckFadeDuration = Duration(milliseconds: 200);
  static const _duckFadeSteps = 10;

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
            await _fadeVolumeTo(duckVolume);
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
              await _fadeVolumeTo(_originalVolume!);
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
              await _fadeVolumeTo(_originalVolume!);
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

  // Ramps the volume to [target] over `_duckFadeDuration` instead of
  // snapping it instantly, so ducking for a notification doesn't sound like
  // an abrupt cut. If a newer fade starts (e.g. a duck immediately followed
  // by its end), this one bails out on its next step rather than fighting
  // over the final value.
  static Future<void> _fadeVolumeTo(int target) async {
    final token = ++_fadeToken;
    final start = playerVolumeSignal.value;
    if (start == target) return;
    final stepDelay = _duckFadeDuration ~/ _duckFadeSteps;
    for (var i = 1; i <= _duckFadeSteps; i++) {
      if (token != _fadeToken) return;
      final t = i / _duckFadeSteps;
      final value = (start + (target - start) * t).round().clamp(0, 100);
      await PlaybackController.changeVolume(value);
      if (i < _duckFadeSteps) {
        await Future<void>.delayed(stepDelay);
      }
    }
  }

  static Future<void> _syncSessionActive(
    AudioSession session,
    bool isPlaying,
  ) async {
    try {
      if (isPlaying) {
        if (_sessionActive) return;
        final granted = await session.setActive(true);
        _sessionActive = granted;
        if (!granted) {
          await PlaybackController.pause();
        }
      } else {
        // Don't abandon focus while we're only paused because of an
        // interruption (e.g. a call) — abandoning cancels the focus
        // request, so we'd never receive the AUDIOFOCUS_GAIN needed to
        // auto-resume once the interruption ends.
        if (_wasPlayingBeforeInterruption != null) return;
        if (!_sessionActive) return;
        _sessionActive = false;
        await session.setActive(false);
      }
    } on Object catch (e, st) {
      debugPrint('Failed to sync audio session active state: $e\n$st');
    }
  }
}
