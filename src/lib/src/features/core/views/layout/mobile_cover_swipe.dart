import 'dart:async';

import 'package:flutter/physics.dart';
import 'package:material_ui/material_ui.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';

/// Gap between the cover and the neighbour cover that slides in.
const double kCoverSwipeGap = 24;

/// Fling velocity (logical px/s) that commits a swipe even when the cover has
/// not travelled far enough.
const double kCoverSwipeFlingVelocity = 300;

const SpringDescription kCoverSwipeExpandSpring = SpringDescription(
  mass: 1,
  stiffness: 420,
  damping: 38,
);

const SpringDescription kCoverSwipeCloseSpring = SpringDescription(
  mass: 1,
  stiffness: 520,
  damping: 46,
);

/// Swipe state machine of the full player cover.
///
/// Owns which neighbour is being pulled in, whether the gesture can commit,
/// the artwork currently forced on screen and the commit / rollback
/// transitions. Rendering (offsets, opacity, layout) stays in the widget; this
/// class only advances the state and drives the shared [animation].
class CoverSwipeController {
  CoverSwipeController({
    required this.animation,
    required this.travel,
    required this.canAnimate,
    required this.isMounted,
    required this.onNext,
    required this.onPrevious,
    String? initialTrackId,
    String? initialCoverUrl,
  }) : _visibleTrackId = initialTrackId,
       _visibleCoverUrl = initialCoverUrl;

  final AnimationController animation;

  /// Distance the cover travels to bring the neighbour in.
  final double Function() travel;

  /// Whether the player is open (and not closing) enough to animate.
  final bool Function() canAnimate;

  final bool Function() isMounted;
  final VoidCallback onNext;
  final VoidCallback onPrevious;

  /// Direction of the cover swipe: -1 is the previous track, 1 the next one.
  int _direction = 0;

  /// Whether the selected direction has a neighbour to move to. At the ends
  /// of the queue the cover only moves a little and snaps back.
  bool _canCommit = false;

  /// Set while the cover is sliding to another track, whether by a swipe or
  /// by a button. Further drags are ignored until it settles, so a second
  /// gesture cannot skip twice.
  bool _committing = false;

  /// Set when the current drag started during a commit animation.
  bool _ignoreDrag = false;

  /// True after a commit settled while the playback state was still catching
  /// up: [holdUrl] then shows the incoming artwork until it does.
  bool _settled = false;

  /// Track the swipe started from, used to detect when playback actually
  /// switches to the new track.
  String? _fromTrackId;

  /// Track the committed swipe expects to land on.
  String? _targetTrackId;

  /// Artwork forced on the central cover while the gesture / commit is in
  /// flight, so it does not flip to the new track before the animation ends.
  String? _holdUrl;

  /// Artwork of the track that slides in.
  String? _incomingUrl;

  /// Track currently shown by the player, used to notice track changes that
  /// did not come from the cover gesture (buttons, queue advance).
  String? _visibleTrackId;

  /// Artwork of [_visibleTrackId], kept because the signals are already on the
  /// new track by the time the effect runs.
  String? _visibleCoverUrl;

  int get direction => _direction;
  bool get canCommit => _canCommit;
  String? get holdUrl => _holdUrl;
  String? get incomingUrl => _incomingUrl;

  /// Keeps the artwork in sync with playback: finishes a committed swipe once
  /// the new track arrives and slides the carousel when the track changes
  /// without a gesture (buttons, queue advance).
  void onTrackChange({String? trackId, String? coverUrl}) {
    final previousId = _visibleTrackId;
    final previousUrl = _visibleCoverUrl;
    _visibleTrackId = trackId;
    _visibleCoverUrl = coverUrl;
    if (trackId == previousId) return;

    // A committed swipe already slid the next cover into place and only
    // waits for playback to report it.
    if (_settled) {
      final settledTargetId = _targetTrackId;
      final settledUrl = _holdUrl;
      final reachedTarget =
          settledTargetId != null && trackId == settledTargetId;
      final diverged = trackId != _fromTrackId && trackId != settledTargetId;
      if (reachedTarget) {
        _clearHold();
        return;
      }
      if (!diverged) return;
      // Playback moved somewhere else: slide on from the artwork that is
      // currently on screen instead of flashing the new cover.
      _clearHold();
      _startTrackSlide(
        fromId: settledTargetId,
        fromUrl: settledUrl,
        toId: trackId,
        toUrl: coverUrl,
        direction: _trackChangeDirection(settledTargetId),
      );
      return;
    }

    // The queue changed while a swipe / slide was still animating.
    if (_committing) {
      if (trackId == _targetTrackId) return;
      final direction = _trackChangeDirection(previousId);
      if (direction != 0 && direction == _direction && animation.isAnimating) {
        // Same direction: keep sliding out the artwork that is already on
        // screen and just land on the newest track instead of jumping.
        _incomingUrl = coverUrl;
        _fromTrackId = previousId;
        _targetTrackId = trackId;
        return;
      }
      // Direction changed or the animation was interrupted: finish the
      // current transition at once and start a fresh one.
      animation
        ..stop()
        ..value = 0;
      _endDrag();
      _clearHold();
      _startTrackSlide(
        fromId: previousId,
        fromUrl: previousUrl,
        toId: trackId,
        toUrl: coverUrl,
        direction: direction,
      );
      return;
    }

    _startTrackSlide(
      fromId: previousId,
      fromUrl: previousUrl,
      toId: trackId,
      toUrl: coverUrl,
      direction: _trackChangeDirection(previousId),
    );
  }

  /// Clears any in-flight swipe state (called when the panel closes).
  void reset() {
    animation
      ..stop()
      ..value = 0;
    _ignoreDrag = false;
    _endDrag();
    _clearHold();
  }

  void onDragStart() {
    if (animation.isAnimating) {
      if (_committing) {
        // The track is already changing; ignore this gesture until the
        // commit animation settles so it cannot skip twice.
        _ignoreDrag = true;
        return;
      }
      animation.stop();
    }
    _ignoreDrag = false;
    // When the previous commit settled before playback caught up, the art on
    // screen is the incoming cover: keep it and treat its track as the new
    // starting point instead of flashing the old artwork.
    final settled = _settled && _holdUrl != null;
    final settledTargetId = _targetTrackId;
    final settledHoldUrl = _holdUrl;
    _endDrag();
    _settled = false;
    if (settled) {
      _fromTrackId =
          settledTargetId ?? playerStateSignal.value?.currentTrack?.id;
      _holdUrl = settledHoldUrl;
    } else {
      _clearHold();
      _fromTrackId = playerStateSignal.value?.currentTrack?.id;
      _holdUrl = currentCoverUrlSignal.value ?? trackMetadataSignal().coverUrl;
    }
  }

  void onDragUpdate(double delta) {
    if (_ignoreDrag || _committing) return;
    // The cover only slides when the player is fully open.
    if (!canAnimate()) return;
    if (delta == 0) return;
    if (_direction == 0) {
      // Dragging to the left brings the next track in.
      final wanted = delta < 0 ? 1 : -1;
      final previous = previousTrackSignal();
      final next = nextTrackSignal();
      final neighbor = wanted > 0 ? next : previous;
      _direction = wanted;
      _canCommit = neighbor != null;
      _incomingUrl = neighbor?.coverUrl;
      _targetTrackId = neighbor?.id;
    }
    final distance = travel();
    // The swipe cannot cross the centre: once a direction is picked the
    // cover follows the finger on that side only. Queue ends get a short,
    // damped travel instead of pulling in a neighbour that does not exist.
    final limit = _canCommit ? distance : distance * 0.18;
    final factor = _canCommit ? 1.0 : 0.25;
    final lower = _direction > 0 ? -limit : 0.0;
    final upper = _direction > 0 ? 0.0 : limit;
    animation.value = (animation.value + delta * factor).clamp(lower, upper);
  }

  void onDragEnd(double velocity) {
    if (_ignoreDrag) {
      _ignoreDrag = false;
      return;
    }
    if (_committing) return;
    final distance = travel();
    final direction = _direction;
    if (direction == 0) {
      _endDrag();
      _clearHold();
      return;
    }
    final flung = direction > 0
        ? velocity < -kCoverSwipeFlingVelocity
        : velocity > kCoverSwipeFlingVelocity;
    final committed =
        _canCommit && (animation.value.abs() > distance * 0.25 || flung);
    if (!committed) {
      _animateTo(0, velocity: velocity, onDone: _finishRollback);
      return;
    }
    _committing = true;
    if (direction > 0) {
      onNext();
    } else {
      // The regular prev restarts the current track when it is past the
      // restart threshold; a swipe must always select the shown neighbour.
      onPrevious();
    }
    _animateTo(
      -direction * distance,
      velocity: velocity,
      onDone: _finishCommit,
    );
  }

  void onDragCancel() {
    if (_ignoreDrag) {
      _ignoreDrag = false;
      return;
    }
    if (_committing) return;
    if (animation.value == 0) {
      _endDrag();
      _clearHold();
      return;
    }
    _animateTo(0, onDone: _finishRollback);
  }

  /// Slides the cover to the new track the same way a committed swipe does,
  /// so next / previous buttons do not swap the artwork abruptly.
  void _startTrackSlide({
    required String? fromId,
    required String? fromUrl,
    required String? toId,
    required String? toUrl,
    required int direction,
  }) {
    if (!isMounted() || !canAnimate()) return;
    if (direction == 0 || fromId == null || toId == null) return;
    if (fromUrl == null || toUrl == null) return;
    _committing = true;
    _direction = direction;
    _canCommit = true;
    _holdUrl = fromUrl;
    _incomingUrl = toUrl;
    _fromTrackId = fromId;
    _targetTrackId = toId;
    _settled = false;
    _animateTo(-direction * travel(), onDone: _finishCommit);
  }

  void _animateTo(
    double target, {
    required VoidCallback onDone,
    double velocity = 0,
  }) {
    // Mirror the open / close gesture: the spring is seeded with the fling
    // velocity, so the cover keeps the speed the finger had on release.
    final simulation = SpringSimulation(
      target == 0 ? kCoverSwipeCloseSpring : kCoverSwipeExpandSpring,
      animation.value,
      target,
      velocity,
      snapToEnd: true,
    );
    unawaited(
      animation
          .animateWith(simulation)
          .orCancel
          .then(
            (_) => onDone(),
            onError: (Object _) {
              // Canceled by a new gesture or by closing; the caller resets.
            },
          ),
    );
  }

  void _finishRollback() {
    if (!isMounted()) return;
    animation.value = 0;
    _endDrag();
    _clearHold();
  }

  void _finishCommit() {
    if (!isMounted()) return;
    final incoming = _incomingUrl;
    final targetId = _targetTrackId;
    animation.value = 0;
    final trackId = playerStateSignal.value?.currentTrack?.id;
    _endDrag();
    if (targetId != null && trackId == targetId) {
      // Playback has already switched: the live cover is the incoming one.
      _clearHold();
    } else if (incoming != null &&
        (trackId == _fromTrackId || trackId == null)) {
      // Playback is still catching up. Keep showing the artwork that just
      // slid in until the state reports the new track.
      _holdUrl = incoming;
      _settled = true;
    } else {
      _clearHold();
    }
  }

  /// Direction of a queue move, inferred from the old track still being one
  /// of the neighbours of the new one.
  int _trackChangeDirection(String? oldTrackId) {
    if (oldTrackId == null) return 0;
    if (previousTrackSignal()?.id == oldTrackId) return 1;
    if (nextTrackSignal()?.id == oldTrackId) return -1;
    return 0;
  }

  void _endDrag() {
    _direction = 0;
    _canCommit = false;
    _incomingUrl = null;
    _committing = false;
  }

  void _clearHold() {
    _holdUrl = null;
    _fromTrackId = null;
    _targetTrackId = null;
    _settled = false;
  }
}
