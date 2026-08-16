import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';

/// Handles Android audio focus: pausing/resuming playback on transient
/// interruptions (calls, other apps) and ducking for notifications.
class AudioFocusManager {
  AudioFocusManager._();

  static StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  static EffectCleanup? _disposeSessionActiveEffect;
  static Future<void> _interruptionQueue = Future.value();
  static Future<void> _sessionQueue = Future.value();
  static int _duckDepth = 0;
  static int _pauseDepth = 0;
  static bool _resumeAfterInterruption = false;
  static bool _sessionActive = false;
  static int _transientGain = 100;

  static const _duckGain = 20;
  static const _duckFadeDuration = Duration(milliseconds: 200);
  static const _duckFadeSteps = 10;

  static Future<void> initialize(AudioSession session) async {
    await _interruptionSub?.cancel();
    _duckDepth = 0;
    _pauseDepth = 0;
    _resumeAfterInterruption = false;
    _transientGain = 100;
    await PlaybackController.changeTransientVolumeGain(100);

    _interruptionSub = session.interruptionEventStream.listen(
      (event) {
        // Stream callbacks do not await returned futures. Chaining them keeps
        // the interruption state and fades strictly ordered.
        _interruptionQueue = _interruptionQueue.then(
          (_) => _handleInterruption(event),
        );
      },
      onError: (Object e, StackTrace st) {
        debugPrint('Audio interruption stream error: $e');
      },
    );

    _disposeSessionActiveEffect?.call();
    _disposeSessionActiveEffect = effect(() {
      final isPlaying = playerStateSignal()?.isPlaying ?? false;
      // Serialize setActive calls as well: overlapping activation and
      // deactivation futures can otherwise complete in the wrong order.
      _sessionQueue = _sessionQueue.then(
        (_) => _syncSessionActive(session, isPlaying),
      );
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
    switch (event.type) {
      case AudioInterruptionType.duck:
        if (event.begin) {
          _duckDepth++;
          if (_duckDepth == 1) await _fadeGainTo(_duckGain);
        } else if (_duckDepth > 0) {
          _duckDepth--;
          if (_duckDepth == 0) await _fadeGainTo(100);
        }
      case AudioInterruptionType.pause:
      case AudioInterruptionType.unknown:
        if (event.begin) {
          if (_pauseDepth == 0) {
            // A stronger interruption can supersede ducking without Android
            // sending its matching end event.
            if (_duckDepth > 0) {
              _duckDepth = 0;
              await _fadeGainTo(100);
            }
            _resumeAfterInterruption = isPlayingSignal.value;
            _pauseDepth = 1;
            if (_resumeAfterInterruption) await PlaybackController.pause();
          } else {
            _pauseDepth++;
          }
        } else if (_pauseDepth > 0) {
          _pauseDepth--;
          if (_pauseDepth == 0) {
            if (_resumeAfterInterruption) await PlaybackController.play();
            _resumeAfterInterruption = false;
          }
        }
    }
  }

  static Future<void> _fadeGainTo(int target) async {
    final start = _transientGain;
    if (start == target) return;
    final stepDelay = _duckFadeDuration ~/ _duckFadeSteps;
    for (var i = 1; i <= _duckFadeSteps; i++) {
      final t = i / _duckFadeSteps;
      _transientGain = (start + (target - start) * t).round().clamp(0, 100);
      await PlaybackController.changeTransientVolumeGain(_transientGain);
      if (i < _duckFadeSteps) await Future<void>.delayed(stepDelay);
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
        if (!granted) await PlaybackController.pause();
      } else {
        // Keep the request while paused by an active interruption so Android
        // can deliver the matching focus-gain event.
        if (_pauseDepth > 0 || !_sessionActive) return;
        await session.setActive(false);
        _sessionActive = false;
      }
    } on Object catch (e, st) {
      debugPrint('Failed to sync audio session active state: $e\n$st');
    }
  }
}
