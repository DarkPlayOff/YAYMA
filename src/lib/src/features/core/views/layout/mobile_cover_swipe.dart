import 'dart:async';

import 'package:flutter/physics.dart';
import 'package:material_ui/material_ui.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/models.dart';

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

/// How long the incoming artwork may stay forced on screen after a commit
/// while playback has not reported the new track. Kept above the bounded wave
/// page fetch (5 s) so a slow but successful advance is never cut short.
const Duration kCoverSettleTimeout = Duration(seconds: 8);

/// How close the slide has to be to its target before it counts as arrived.
/// The default spring tolerance (0.001 px) keeps the animation running for a
/// few hundred ms after the cover visibly stops, which holds the swipe state
/// hostage for the next gesture.
const Tolerance kCoverSwipeSettleTolerance = Tolerance(
  distance: 0.5,
  velocity: 24,
);

/// Catch-up slide that carries a burst of skips to the newest track. It starts
/// from the artwork already on screen, so it only adds the remainder instead
/// of a full transition per skipped track.
const Duration kCoverCatchUpDuration = Duration(milliseconds: 140);

/// Direction of a queue move from the visible index alone: -1 is the previous
/// track, 1 the next one, 0 when it cannot be told. Wraps at the ends are only
/// inferred for queues longer than two tracks, where they cannot be confused
/// with an ordinary adjacent move.
int coverMoveDirection(int? oldIndex, int? newIndex, int count) {
  if (oldIndex == null || newIndex == null || oldIndex == newIndex) return 0;
  if (count > 2 && oldIndex == count - 1 && newIndex == 0) return 1;
  if (count > 2 && oldIndex == 0 && newIndex == count - 1) return -1;
  return newIndex > oldIndex ? 1 : -1;
}

/// Index of the neighbour of [index] in a queue of [count] items, or null at
/// the ends.
int? coverNeighbourIndex(int index, int direction, int count) {
  final target = index + direction;
  return target < 0 || target >= count ? null : target;
}

/// Swipe state machine of the full player cover.
///
/// Holds one notion of "what the user sees": [_centreId] / [_centreUrl], the
/// artwork resting at the screen centre. Every slide starts from it and ends
/// by replacing it, so the cover can never show two different ideas of the
/// current track at once.
///
/// The neighbour to pull in comes from the playback queue list only. The
/// queue-index based neighbour signals lag behind a skip, and mixing the two
/// sources made the cover slide onto itself or refuse to move at all.
///
/// Rendering (offsets, opacity, layout) stays in the widget; this class only
/// advances the state and drives the shared [animation].
class CoverSwipeController {
  CoverSwipeController({
    required this.animation,
    required this.travel,
    required this.canAnimate,
    required this.isMounted,
    required this.onNext,
    required this.onPrevious,
    required this.onChanged,
    required this.queue,
    SimpleTrackDto? initialTrack,
    int? initialIndex,
  }) : _reportedId = initialTrack?.id,
       _reportedIndex = initialIndex,
       _centreId = initialTrack?.id,
       _centreUrl = initialTrack?.coverUrl;

  final AnimationController animation;

  /// Distance the cover travels to bring the neighbour in.
  final double Function() travel;

  /// Whether the player is open (and not closing) enough to animate.
  final bool Function() canAnimate;

  final bool Function() isMounted;
  final VoidCallback onNext;
  final VoidCallback onPrevious;

  /// Repaints the cover after state that no animation drives changed, e.g.
  /// the settle watchdog giving the artwork back to the live track.
  final VoidCallback onChanged;

  /// The playback queue in order. The only source of "what is next", so it is
  /// injected instead of read from a signal.
  final List<SimpleTrackDto> Function() queue;

  /// Direction of the cover swipe: -1 is the previous track, 1 the next one.
  int _direction = 0;

  /// Whether the selected direction has a neighbour to move to. At the ends
  /// of the queue the cover only moves a little and snaps back.
  bool _canCommit = false;

  /// Set while the cover is sliding to another track, whether by a swipe or
  /// by a button. Further drags are ignored until it settles, so a second
  /// gesture cannot skip twice.
  bool _committing = false;

  /// Last track playback reported. Only used to notice changes and to work out
  /// which way the queue moved; the artwork on screen is [_centreId].
  String? _reportedId;
  int? _reportedIndex;

  /// Artwork resting at the screen centre: what the user actually sees.
  String? _centreId;
  String? _centreUrl;

  /// Ends of the slide that is running, kept to tell a lagging playback report
  /// from a skip that went past the landing artwork.
  String? _fromId;
  String? _targetId;

  /// Artwork of the neighbour that slides in. Non-null exactly while a
  /// direction is picked and it has somewhere to go.
  String? _incomingUrl;

  /// Newest track change that arrived while a cover animation was running.
  /// It is taken up once that animation lands, so the artwork on screen never
  /// changes in flight.
  ({String? id, String? url, int direction})? _pending;

  /// Gives the artwork back to the live track when a commit landed but
  /// playback never reported the new track (failed skip, failed wave fetch).
  Timer? _settleWatchdog;

  /// Direction the artwork at rest was reached in, kept while the watchdog
  /// holds it, so a late report that is still behind can be recognised.
  int _heldDirection = 0;

  /// Invalidates the callback of an animation that a grab took over, so a
  /// slide that already finished cannot settle the new gesture's state.
  int _animationEpoch = 0;

  int get direction => _direction;
  bool get canCommit => _canCommit;

  /// Artwork of the central cover. Always the resting artwork, so the cover
  /// cannot fall back to a different source mid-gesture.
  String? get holdUrl => _centreUrl;
  String? get incomingUrl => _incomingUrl;

  /// Keeps the artwork in sync with playback: lands a committed swipe once the
  /// new track arrives and slides the carousel when the track changes without
  /// a gesture (buttons, queue advance).
  void onTrackChange({String? trackId, String? coverUrl}) {
    final previousId = _reportedId;
    final previousIndex = _reportedIndex;
    final state = playerStateSignal.value;
    _reportedId = trackId;
    _reportedIndex = state?.queueIndex;

    if (trackId == previousId) {
      // Same track: late metadata can still refine the artwork on screen.
      if (trackId == _centreId && coverUrl != _centreUrl) {
        _centreUrl = coverUrl;
        onChanged();
      }
      return;
    }

    final direction = _changeDirection(
      previousId,
      previousIndex,
      trackId,
      state?.queueIndex,
      state?.queueCount ?? 0,
    );

    // An animation owns both covers until it lands. Queue the newest change
    // and take it up afterwards: retargeting or rolling back the artwork in
    // flight is what made a burst of skips flicker and go missing.
    if (_committing || animation.isAnimating) {
      _pending = (id: trackId, url: coverUrl, direction: direction);
      return;
    }

    if (trackId == _centreId) {
      _syncCentre();
      return;
    }
    // While a landed artwork is held, a report that is still behind it is the
    // same slow skip, not news: remember it and keep waiting instead of
    // dragging the cover backwards.
    if (_settleWatchdog != null &&
        _isBehind(trackId ?? '', _centreId, _heldDirection)) {
      _pending = null;
      return;
    }
    if (!_startSlide(toId: trackId, toUrl: coverUrl, direction: direction)) {
      _setCentre(trackId, coverUrl);
      onChanged();
    }
  }

  /// Clears any in-flight swipe state (called when the panel closes).
  void reset() {
    animation
      ..stop()
      ..value = 0;
    _animationEpoch++;
    _pending = null;
    _settleWatchdog?.cancel();
    _settleWatchdog = null;
    _endDrag();
    _clearSlide();
  }

  void dispose() => _settleWatchdog?.cancel();

  void onDragStart() {
    if (animation.isAnimating) {
      animation.stop();
    }
    // The gesture owns the state from here: drop the callback of the slide it
    // interrupted so it cannot settle on top of it.
    _animationEpoch++;
    _pending = null;
    _settleWatchdog?.cancel();
    _settleWatchdog = null;
    if (_committing && _incomingUrl != null) {
      // The skip already went through. The art that was sliding in is now the
      // cover at rest; falling back to the playback signal here would flash
      // the art that was sliding out, because the state has not caught up.
      // shortcut: this also moves the covers to their rest position at once,
      // which is a visible hop when the finger grabs a slide that just
      // started. Upgrade to a takeover that keeps the slider offset if rapid
      // double swipes ever look jumpy on a device.
      animation.value = 0;
      _centreId = _targetId;
      _centreUrl = _incomingUrl;
    }
    _endDrag();
  }

  void onDragUpdate(double delta) {
    if (_committing) return;
    // The cover only slides when the player is fully open.
    if (!canAnimate()) return;
    if (delta == 0) return;
    if (_direction == 0) {
      // Dragging to the left brings the next track in.
      final wanted = delta < 0 ? 1 : -1;
      final neighbour = _neighbour(wanted);
      _direction = wanted;
      _canCommit = neighbour != null;
      _incomingUrl = neighbour?.url;
      _targetId = neighbour?.id;
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
    if (_committing) return;
    final distance = travel();
    final direction = _direction;
    if (direction == 0) {
      _endDrag();
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
    _fromId = _centreId;
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
    if (_committing) return;
    if (animation.value == 0) {
      _endDrag();
      return;
    }
    _animateTo(0, onDone: _finishRollback);
  }

  /// Slides the cover to [toId] from the artwork at rest. Returns whether the
  /// slide could start; when it cannot, the caller shows the new artwork at
  /// once instead of leaving a stale one.
  bool _startSlide({
    required String? toId,
    required String? toUrl,
    required int direction,
    bool fast = false,
  }) {
    final fromId = _centreId;
    final fromUrl = _centreUrl;
    if (!isMounted() || !canAnimate()) return false;
    if (direction == 0 || fromId == null || toId == null) return false;
    if (fromId == toId || fromUrl == null || toUrl == null) return false;
    _settleWatchdog?.cancel();
    _settleWatchdog = null;
    _committing = true;
    _direction = direction;
    _canCommit = true;
    _fromId = fromId;
    _targetId = toId;
    _incomingUrl = toUrl;
    _animateTo(-direction * travel(), onDone: _finishCommit, fast: fast);
    return true;
  }

  void _animateTo(
    double target, {
    required VoidCallback onDone,
    double velocity = 0,
    bool fast = false,
  }) {
    // Mirror the open / close gesture: the spring is seeded with the fling
    // velocity, so the cover keeps the speed the finger had on release.
    final epoch = ++_animationEpoch;
    final run = fast && target != 0
        ? animation.animateTo(
            target,
            duration: kCoverCatchUpDuration,
            curve: Curves.easeOutCubic,
          )
        : animation.animateWith(
            SpringSimulation(
              target == 0 ? kCoverSwipeCloseSpring : kCoverSwipeExpandSpring,
              animation.value,
              target,
              velocity,
              snapToEnd: true,
              // The default tolerance keeps the controller running until the
              // spring is within 0.001 px of the target, which is a few
              // hundred ms after the cover has visibly arrived. The slide is
              // held as "committing" for that whole tail, so the next gesture
              // and the next track change are late. Stop as soon as the
              // remaining motion cannot be seen.
              tolerance: kCoverSwipeSettleTolerance,
            ),
          );
    unawaited(
      run.orCancel.then(
        (_) {
          if (epoch != _animationEpoch) return;
          onDone();
        },
        onError: (Object _) {
          // Canceled by a new gesture or by closing; the caller resets.
        },
      ),
    );
  }

  void _finishRollback() {
    // The cover is back at rest on the artwork it started from.
    _land(_centreId, _centreUrl, 0);
  }

  void _finishCommit() {
    // The artwork that slid in now sits at the screen centre.
    _land(_targetId, _incomingUrl, _direction);
  }

  /// Ends a cover animation at rest on [id] / [url] and reconciles it with
  /// what playback reports: a lagging report is waited out, a skip that went
  /// past the landing artwork is carried on by one short slide.
  void _land(String? id, String? url, int travelDirection) {
    if (!isMounted()) return;
    animation.value = 0;
    _endDrag();
    _setCentre(id, url);

    final live = playerStateSignal.value?.currentTrack;
    final liveId = live?.id;
    if (liveId == null || liveId == id) {
      // Playback is on the artwork at rest.
      _clearSlide();
      onChanged();
      return;
    }
    if (_isBehind(liveId, id, travelDirection)) {
      // Playback has not caught up yet: keep the artwork that just landed
      // until it does.
      _armSettleWatchdog(travelDirection);
      onChanged();
      return;
    }
    final direction = _pending?.direction ?? _queueDirection(id, liveId);
    _pending = null;
    if (!_startSlide(
      toId: liveId,
      toUrl: live!.coverUrl,
      direction: direction,
      fast: true,
    )) {
      _setCentre(liveId, live.coverUrl);
      onChanged();
    }
  }

  /// Whether [liveId] has not reached [centreId] yet, in the direction the
  /// cover is travelling. Without a usable queue position the only lagging
  /// report that can be recognised is the one still on the original track.
  bool _isBehind(String liveId, String? centreId, int travelDirection) {
    if (travelDirection == 0) return liveId == _fromId;
    final list = queue();
    final live = _indexOf(list, liveId);
    final centre = _indexOf(list, centreId);
    // A two-track queue only has one other track, so a wrap there is the track
    // the cover left; the index delta cannot tell it from an ordinary move.
    if (live < 0 || centre < 0 || list.length < 3) {
      return liveId == _fromId;
    }
    return coverMoveDirection(live, centre, list.length) == travelDirection;
  }

  /// Neighbour of the centre in the queue, wrapping only in repeat-all.
  ({String? id, String? url})? _neighbour(int direction) {
    final list = queue();
    final index = _indexOf(list, _centreId);
    if (index < 0) return null;
    final target = coverNeighbourIndex(index, direction, list.length);
    if (target != null) {
      final track = list[target];
      return (id: track.id, url: track.coverUrl);
    }
    if (list.length < 2) return null;
    if (playerStateSignal.value?.repeatMode != RepeatModeDto.all) return null;
    final track = direction > 0 ? list.first : list.last;
    return (id: track.id, url: track.coverUrl);
  }

  int _indexOf(List<SimpleTrackDto> list, String? id) =>
      id == null ? -1 : list.indexWhere((track) => track.id == id);

  /// Direction from [fromId] to [toId] in the queue, 0 when unknown.
  int _queueDirection(String? fromId, String? toId) {
    final list = queue();
    final from = _indexOf(list, fromId);
    final to = _indexOf(list, toId);
    if (from < 0 || to < 0 || from == to) return 0;
    return to > from ? 1 : -1;
  }

  /// Direction of a reported track change. The queue index delta is
  /// authoritative; when it did not move (queue replaced in place) the queue
  /// list still knows both positions.
  int _changeDirection(
    String? fromId,
    int? fromIndex,
    String? toId,
    int? toIndex,
    int count,
  ) {
    // A two-track queue can only wrap through repeat-all, and the index delta
    // calls that wrap a backwards move. Count it as forward, the usual skip.
    if (count == 2 &&
        playerStateSignal.value?.repeatMode == RepeatModeDto.all) {
      if (fromIndex == 1 && toIndex == 0) return 1;
      if (fromIndex == 0 && toIndex == 1) return -1;
    }
    final byIndex = coverMoveDirection(fromIndex, toIndex, count);
    if (byIndex != 0) return byIndex;
    return _queueDirection(fromId, toId);
  }

  /// Artwork at rest follows the live track again.
  void _syncCentre() {
    _settleWatchdog?.cancel();
    _settleWatchdog = null;
    final url = playerStateSignal.value?.currentTrack?.coverUrl;
    if (url == _centreUrl) return;
    _centreUrl = url;
    onChanged();
  }

  void _setCentre(String? id, String? url) {
    _centreId = id;
    _centreUrl = url;
    if (id != null && id == playerStateSignal.value?.currentTrack?.id) {
      _settleWatchdog?.cancel();
      _settleWatchdog = null;
    }
  }

  /// Gives the artwork back to the live track when a commit landed but the
  /// state never reported a new track (failed skip, failed wave fetch).
  void _armSettleWatchdog(int travelDirection) {
    _settleWatchdog?.cancel();
    _heldDirection = travelDirection;
    _settleWatchdog = Timer(kCoverSettleTimeout, () {
      if (!isMounted()) return;
      final live = playerStateSignal.value?.currentTrack;
      if (live?.id == null || live?.id == _centreId) return;
      _setCentre(live!.id, live.coverUrl);
      onChanged();
    });
  }

  void _endDrag() {
    _direction = 0;
    _canCommit = false;
    _incomingUrl = null;
    _committing = false;
  }

  void _clearSlide() {
    _fromId = null;
    _targetId = null;
  }
}
