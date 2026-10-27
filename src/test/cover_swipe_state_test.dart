import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:yayma/src/features/core/views/layout/mobile_cover_swipe.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/models.dart';

const _travel = 300.0;

SimpleTrackDto _track(String id) => SimpleTrackDto(
  id: id,
  title: id,
  artists: const [],
  durationMs: 1000,
  coverUrl: '$id.jpg',
  isLiked: false,
  isDisliked: false,
);

List<SimpleTrackDto> _queue(List<String> ids) => ids.map(_track).toList();

PlaybackState _state(
  List<String> ids,
  String trackId, {
  bool isPlaying = true,
  RepeatModeDto repeat = RepeatModeDto.none,
}) {
  final index = ids.indexOf(trackId);
  return PlaybackState(
    isPlaying: isPlaying,
    isBuffering: false,
    volume: 100,
    isMuted: false,
    repeatMode: repeat,
    isShuffled: false,
    queueCount: ids.length,
    queueIndex: index < 0 ? 0 : index,
    currentTrack: _track(trackId),
    currentWaveSeeds: const [],
  );
}

/// Test bench: a controller over a fixed queue plus the bits of playback and
/// rendering it talks to. Playback only moves when the test says so, which is
/// what exposes the lag between a skip and the reported state.
class _Bench {
  _Bench(
    this.tester, {
    this.ids = const ['a', 'b', 'c', 'd'],
    String? startAt,
    this.repeat = RepeatModeDto.none,
    this.canAnimate = true,
  }) : current = startAt ?? ids.first {
    playerStateSignal.value = _state(ids, current, repeat: repeat);
    animation = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 400),
      lowerBound: double.negativeInfinity,
      upperBound: double.infinity,
      // Without an explicit value the controller starts at the lower bound.
      value: 0,
    );
    addTearDown(animation.dispose);
    swipe = CoverSwipeController(
      animation: animation,
      travel: () => _travel,
      canAnimate: () => this.canAnimate,
      isMounted: () => true,
      onNext: () {
        nextCalls++;
        if (pendingSkips > 0) pendingSkips--;
      },
      onPrevious: () => prevCalls++,
      onChanged: () {
        changedCalls++;
      },
      queue: () => _queue(ids),
      initialTrack: _track(current),
      initialIndex: ids.indexOf(current),
    );
    addTearDown(swipe.dispose);
  }

  /// Track ids, in queue order.
  final List<String> ids;
  final WidgetTester tester;
  final RepeatModeDto repeat;
  bool canAnimate;

  late final AnimationController animation;
  late final CoverSwipeController swipe;

  /// Track playback is on right now.
  String current;
  int nextCalls = 0;
  int prevCalls = 0;
  int changedCalls = 0;

  /// Skips the fake playback applies on the next [commit] so the state catches
  /// up in the same frame, like a fast local skip.
  int pendingSkips = 0;

  /// Applies the skip the gesture just requested.
  void catchUp() {
    final index = ids.indexOf(current);
    current = ids[(index + 1).clamp(0, ids.length - 1)];
    playerStateSignal.value = _state(ids, current, repeat: repeat);
    swipe.onTrackChange(trackId: current, coverUrl: '$current.jpg');
  }

  /// Plays a state change the gesture did not request (a button, the queue
  /// advancing, a remote device).
  void play(String trackId) {
    current = trackId;
    playerStateSignal.value = _state(ids, trackId, repeat: repeat);
    swipe.onTrackChange(trackId: trackId, coverUrl: '$trackId.jpg');
  }

  void dragStart() => swipe.onDragStart();

  void dragBy(double delta) => swipe.onDragUpdate(delta);

  void dragEnd([double velocity = 0]) => swipe.onDragEnd(velocity);

  /// Swipes one full screen in [direction] and releases at rest, without
  /// letting playback catch up.
  void swipeAndRelease(int direction, {double velocity = 0}) {
    dragStart();
    dragBy(-direction * _travel * 0.6);
    dragEnd(velocity);
  }

  /// What the widget paints: the central artwork plus the visible neighbour.
  _Frame frame() => _Frame(
    centreUrl: swipe.holdUrl ?? '$current.jpg',
    incomingUrl: swipe.direction != 0 && swipe.canCommit
        ? swipe.incomingUrl
        : null,
    direction: swipe.direction,
    dx: animation.value,
    animating: animation.isAnimating,
  );

  Future<void> pump([Duration by = const Duration(milliseconds: 16)]) =>
      tester.pump(by);

  /// Pumps until the cover is at rest, then returns the final frame.
  Future<_Frame> settle() async {
    for (var i = 0; i < 200; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (!animation.isAnimating) break;
    }
    return frame();
  }
}

class _Frame {
  const _Frame({
    required this.centreUrl,
    required this.incomingUrl,
    required this.direction,
    required this.dx,
    required this.animating,
  });

  final String centreUrl;
  final String? incomingUrl;
  final int direction;
  final double dx;
  final bool animating;

  bool get atRest => !animating && dx.abs() < 0.5;

  @override
  String toString() =>
      'centre=$centreUrl incoming=$incomingUrl dir=$direction '
      'dx=${dx.toStringAsFixed(1)} animating=$animating';
}

/// Invariants the rendered carousel must never break.
void _expectSane(_Frame frame, {String? reason}) {
  final context = reason == null ? '' : ' ($reason)';
  // The centre is never empty: the widget would show the live artwork and the
  // gesture would have nothing to move.
  expect(frame.centreUrl, isNotEmpty, reason: 'empty centre$context');
  // The neighbour must never be the artwork that is already in the centre.
  expect(
    frame.incomingUrl,
    isNot(frame.centreUrl),
    reason: 'the carousel slides a duplicate onto itself$context',
  );
  // A visible neighbour only exists while the cover is moving.
  if (frame.incomingUrl != null) {
    expect(
      frame.direction,
      isNot(0),
      reason: 'a neighbour is visible without a direction$context',
    );
  }
}

Future<void> _expectRest(_Bench bench, String trackId, {String? reason}) async {
  final frame = await bench.settle();
  final context = reason == null ? '' : ' ($reason)';
  expect(frame.atRest, isTrue, reason: 'cover is not at rest: $frame$context');
  expect(frame.direction, 0, reason: 'direction is left over$context');
  expect(frame.centreUrl, '$trackId.jpg', reason: 'wrong artwork$context');
}

void main() {
  group('queue helpers', () {
    test('neighbour of an index, without wrapping', () {
      expect(coverNeighbourIndex(1, 1, 5), 2);
      expect(coverNeighbourIndex(1, -1, 5), 0);
      expect(coverNeighbourIndex(0, -1, 5), isNull);
      expect(coverNeighbourIndex(4, 1, 5), isNull);
      expect(coverNeighbourIndex(0, 1, 1), isNull);
    });

    test('move direction from the index delta, wrapping a long queue', () {
      expect(coverMoveDirection(0, 1, 5), 1);
      expect(coverMoveDirection(3, 2, 5), -1);
      expect(coverMoveDirection(4, 0, 5), 1);
      expect(coverMoveDirection(0, 4, 5), -1);
      expect(coverMoveDirection(0, 2, 5), 1);
      expect(coverMoveDirection(2, 0, 5), -1);
      // Short queues cannot be wrapped without guessing.
      expect(coverMoveDirection(1, 0, 2), -1);
      expect(coverMoveDirection(null, 1, 5), 0);
      expect(coverMoveDirection(1, 1, 5), 0);
    });
  });

  group('gesture', () {
    testWidgets('a full swipe forward skips once and lands on the neighbour', (
      tester,
    ) async {
      final bench = _Bench(tester);

      bench.swipeAndRelease(1);
      expect(bench.nextCalls, 1);
      expect(bench.swipe.incomingUrl, 'b.jpg');
      expect(bench.swipe.canCommit, isTrue);

      // Playback catches up while the slide is still running.
      bench.catchUp();
      final frame = await bench.settle();

      expect(frame.centreUrl, 'b.jpg');
      _expectSane(frame);
      await _expectRest(bench, 'b');
    });

    testWidgets('a short drag rolls back without skipping', (tester) async {
      final bench = _Bench(tester);

      bench.dragStart();
      bench.dragBy(-_travel * 0.1);
      bench.dragEnd();
      expect(bench.nextCalls, 0);

      await _expectRest(bench, 'a');
      expect(bench.swipe.incomingUrl, isNull);
    });

    testWidgets('a fling commits even on a short travel', (tester) async {
      final bench = _Bench(tester);

      bench.dragStart();
      bench.dragBy(-_travel * 0.05);
      bench.dragEnd(-1200);

      expect(bench.nextCalls, 1);
      bench.catchUp();
      await _expectRest(bench, 'b');
    });

    testWidgets('a swipe backwards skips back once', (tester) async {
      final bench = _Bench(tester, startAt: 'c');

      bench.swipeAndRelease(-1);
      expect(bench.prevCalls, 1);
      expect(bench.nextCalls, 0);
      expect(bench.swipe.incomingUrl, 'b.jpg');

      bench.play('b');
      await _expectRest(bench, 'b');
    });

    testWidgets('the queue start damps the swipe and skips nothing', (
      tester,
    ) async {
      final bench = _Bench(tester);

      bench.dragStart();
      bench.dragBy(_travel * 0.6);
      // Damped: the cover moves a little, never a whole screen.
      expect(bench.animation.value, inInclusiveRange(0, _travel * 0.18));
      expect(bench.swipe.canCommit, isFalse);
      bench.dragEnd();

      _expectSane(bench.frame());
      await _expectRest(bench, 'a');
      expect(bench.prevCalls, 0);
    });

    testWidgets('repeat-all wraps from the last track to the first', (
      tester,
    ) async {
      final bench = _Bench(tester, startAt: 'd', repeat: RepeatModeDto.all);

      bench.dragStart();
      bench.dragBy(-_travel * 0.6);
      expect(bench.swipe.canCommit, isTrue, reason: 'wraps to the first track');
      expect(bench.swipe.incomingUrl, 'a.jpg');
      bench.dragEnd();

      expect(bench.nextCalls, 1);
      bench.play('a');
      await _expectRest(bench, 'a');
    });

    testWidgets('repeat-all wraps and holds the landing art until playback', (
      tester,
    ) async {
      final bench = _Bench(tester, startAt: 'd', repeat: RepeatModeDto.all);

      bench.swipeAndRelease(1);
      await bench.settle();
      // Playback still says "d", which the queue delta would read as an
      // ordinary backwards move; the wrap must not be mistaken for one.
      expect(bench.current, 'd');
      expect(bench.swipe.holdUrl, 'a.jpg', reason: 'the landed art is kept');

      bench.play('a');
      await _expectRest(bench, 'a');
    });

    testWidgets('without repeat the last track is the end of the carousel', (
      tester,
    ) async {
      final bench = _Bench(tester, startAt: 'd');

      bench.dragStart();
      bench.dragBy(-10);
      expect(bench.swipe.canCommit, isFalse);
      expect(bench.swipe.incomingUrl, isNull);
      bench.dragEnd();

      await _expectRest(bench, 'd');
    });
  });

  group('swiping again while an animation runs', () {
    testWidgets('a grab during the commit keeps the incoming artwork', (
      tester,
    ) async {
      final bench = _Bench(tester);

      bench.swipeAndRelease(1);
      await bench.pump();
      await bench.pump(const Duration(milliseconds: 40));
      expect(
        bench.animation.value,
        lessThan(0),
        reason: 'the slide is running',
      );

      bench.dragStart();

      // The skip already went through, so the art that was sliding in is the
      // one at rest; the state has not reported it yet.
      expect(bench.swipe.holdUrl, 'b.jpg');
      expect(bench.animation.value, 0);
      expect(bench.swipe.direction, 0);
      _expectSane(bench.frame(), reason: 'after the grab');
    });

    testWidgets('the second swipe moves instead of blocking', (tester) async {
      final bench = _Bench(tester);

      bench.swipeAndRelease(1);
      await bench.pump();
      await bench.pump(const Duration(milliseconds: 40));

      bench.dragStart();
      bench.dragBy(-20);

      expect(
        bench.animation.value,
        lessThan(0),
        reason: 'the cover follows the new gesture',
      );
      expect(bench.swipe.direction, 1);
      expect(
        bench.swipe.incomingUrl,
        'c.jpg',
        reason: 'next after the landing',
      );
      _expectSane(bench.frame());
    });

    testWidgets('the second swipe commits to the real next track', (
      tester,
    ) async {
      final bench = _Bench(tester);

      bench.swipeAndRelease(1);
      await bench.pump();
      await bench.pump(const Duration(milliseconds: 40));
      bench.dragStart();
      bench.dragBy(-_travel * 0.6);
      bench.dragEnd();

      expect(bench.nextCalls, 2, reason: 'the first skip plus this one');
      expect(bench.swipe.incomingUrl, 'c.jpg');

      bench.play('c');
      await _expectRest(bench, 'c');
    });

    testWidgets('a grab during a rollback does not skip', (tester) async {
      final bench = _Bench(tester);

      bench.dragStart();
      bench.dragBy(-_travel * 0.1);
      bench.dragEnd();
      await bench.pump();
      await bench.pump(const Duration(milliseconds: 40));

      bench.dragStart();
      bench.dragBy(_travel * 0.1);
      bench.dragEnd();

      expect(bench.nextCalls, 0);
      await _expectRest(bench, 'a');
    });

    testWidgets('a grab after the commit landed but before the report', (
      tester,
    ) async {
      final bench = _Bench(tester);

      bench.swipeAndRelease(1);
      await bench.settle();
      // Playback has not caught up: the state still says "a".
      expect(bench.current, 'a');
      expect(bench.swipe.holdUrl, 'b.jpg', reason: 'the landed art is kept');

      bench.dragStart();
      bench.dragBy(-20);

      expect(bench.animation.value, lessThan(0));
      expect(
        bench.swipe.incomingUrl,
        'c.jpg',
        reason: 'the neighbour is taken from the landing art, not the state',
      );
      _expectSane(bench.frame());

      bench.dragEnd();
      bench.play('b');
      await _expectRest(bench, 'b');
    });

    testWidgets('a rollback while playback is behind keeps the landing art', (
      tester,
    ) async {
      final bench = _Bench(tester);

      bench.swipeAndRelease(1);
      await bench.settle();
      bench.dragStart();
      bench.dragBy(-_travel * 0.1);
      bench.dragEnd();

      // Nothing new was requested: playback is still on the old track, so the
      // artwork that landed is held.
      expect(bench.nextCalls, 1);
      expect(bench.swipe.holdUrl, 'b.jpg');

      bench.play('b');
      await _expectRest(bench, 'b');
    });

    testWidgets('a grab during a rollback keeps the offset on screen', (
      tester,
    ) async {
      final bench = _Bench(tester);

      bench.dragStart();
      bench.dragBy(-_travel * 0.1);
      bench.dragEnd();
      await bench.pump();
      final offset = bench.animation.value;
      expect(offset.abs(), greaterThan(1), reason: 'the rollback is running');

      bench.dragStart();

      expect(
        bench.animation.value,
        offset,
        reason: 'the cover must not hop to the centre under the finger',
      );
    });
  });

  group('a burst of skips', () {
    testWidgets('never changes the artwork while the cover is moving', (
      tester,
    ) async {
      final bench = _Bench(tester);

      bench.swipeAndRelease(1);
      await bench.pump();
      await bench.pump(const Duration(milliseconds: 30));
      final incoming = bench.swipe.incomingUrl;

      // Two more skips from a keyboard or a remote.
      bench.play('c');
      bench.play('d');
      await bench.pump();

      expect(bench.swipe.incomingUrl, incoming);
      expect(bench.swipe.holdUrl, 'a.jpg');
      _expectSane(bench.frame());
      bench.swipe.reset();
    });

    testWidgets('is carried to the newest track in one short slide', (
      tester,
    ) async {
      final bench = _Bench(tester);

      bench.swipeAndRelease(1);
      await bench.pump();
      await bench.pump(const Duration(milliseconds: 30));
      bench.play('c');
      bench.play('d');

      for (var i = 0; i < 200; i++) {
        await bench.pump();
        if (!bench.animation.isAnimating) break;
      }
      // Either it landed on d directly or is carrying from b to d.
      expect(
        bench.swipe.holdUrl,
        anyOf('b.jpg', 'd.jpg'),
        reason: 'never bounces back to a skipped-through artwork',
      );
      _expectSane(bench.frame());

      await bench.settle();
      await bench.settle();
      await _expectRest(bench, 'd');
    });

    testWidgets('lands once and stops when playback already moved on', (
      tester,
    ) async {
      final bench = _Bench(tester);

      bench.swipeAndRelease(1);
      await bench.pump();
      await bench.pump(const Duration(milliseconds: 30));
      bench.play('c');
      bench.play('d');
      await bench.settle();
      await bench.settle();

      expect(bench.animation.isAnimating, isFalse);
      expect(bench.animation.value, 0);
      expect(bench.swipe.direction, 0);
      expect(bench.swipe.canCommit, isFalse);
    });

    testWidgets('a lagging report after the landing does not drag back', (
      tester,
    ) async {
      final bench = _Bench(tester);

      // Two skips land the cover on c while playback is still on a.
      bench.swipeAndRelease(1);
      await bench.settle();
      bench.swipeAndRelease(1);
      await bench.settle();
      expect(bench.swipe.holdUrl, 'c.jpg');

      // The report of the first skip arrives now.
      bench.play('b');

      expect(bench.swipe.holdUrl, 'c.jpg', reason: 'the landing art is kept');
      expect(bench.animation.isAnimating, isFalse);
      _expectSane(bench.frame());

      bench.play('c');
      await _expectRest(bench, 'c');
    });
  });

  group('track changes from outside the gesture', () {
    testWidgets('a next button slides the cover the same way', (tester) async {
      final bench = _Bench(tester);

      bench.play('b');
      expect(bench.swipe.incomingUrl, 'b.jpg');
      expect(bench.swipe.direction, 1);
      _expectSane(bench.frame());

      await _expectRest(bench, 'b');
    });

    testWidgets('a previous button slides backwards', (tester) async {
      final bench = _Bench(tester, startAt: 'c');

      bench.play('b');
      expect(bench.swipe.direction, -1);
      await _expectRest(bench, 'b');
    });

    testWidgets('a queue replaced in place still slides, by list position', (
      tester,
    ) async {
      final bench = _Bench(tester);

      // The index does not move, so only the queue list can tell the side.
      playerStateSignal.value = _state(bench.ids, 'b');
      bench.swipe.onTrackChange(trackId: 'b', coverUrl: 'b.jpg');

      expect(bench.swipe.direction, 1, reason: 'b follows a in the queue');
      await _expectRest(bench, 'b');
    });

    testWidgets('a track missing from the queue shows up without a slide', (
      tester,
    ) async {
      final bench = _Bench(tester);

      bench.play('zzz');
      expect(bench.swipe.incomingUrl, isNull);
      expect(bench.swipe.holdUrl, 'zzz.jpg');
      await _expectRest(bench, 'zzz');
    });

    testWidgets('late artwork metadata of the shown track is picked up', (
      tester,
    ) async {
      final bench = _Bench(tester);

      bench.swipe.onTrackChange(trackId: 'a', coverUrl: 'a-hires.jpg');
      expect(bench.swipe.holdUrl, 'a-hires.jpg');
      expect(bench.animation.isAnimating, isFalse);
      expect(bench.changedCalls, 1, reason: 'the new artwork must be painted');
    });

    testWidgets('repeat-all wraps a two-track queue forward', (tester) async {
      final bench = _Bench(
        tester,
        ids: const ['a', 'b'],
        startAt: 'b',
        repeat: RepeatModeDto.all,
      );

      bench.play('a');

      expect(bench.swipe.direction, 1, reason: 'the cover follows the advance');
      await _expectRest(bench, 'a');
    });
  });

  group('when the slide cannot animate', () {
    testWidgets('a button skip still shows the new track', (tester) async {
      final bench = _Bench(tester, canAnimate: false);

      bench.play('b');

      expect(bench.swipe.holdUrl, 'b.jpg');
      expect(bench.animation.isAnimating, isFalse);
      expect(bench.swipe.direction, 0);
      _expectSane(bench.frame());
    });

    testWidgets('the watchdog gives the artwork back when a skip fails', (
      tester,
    ) async {
      final bench = _Bench(tester);

      bench.swipeAndRelease(1);
      await bench.settle();
      expect(bench.swipe.holdUrl, 'b.jpg');

      // Playback never reports the new track.
      await tester.pump(kCoverSettleTimeout + const Duration(seconds: 1));

      expect(bench.swipe.holdUrl, 'a.jpg', reason: 'back to what is playing');
      expect(bench.swipe.direction, 0);
    });
  });

  testWidgets('random gestures keep the carousel sane on every frame', (
    tester,
  ) async {
    final random = Random(20261027);
    final bench = _Bench(tester, ids: const ['a', 'b', 'c', 'd', 'e']);

    for (var step = 0; step < 220; step++) {
      final action = random.nextInt(10);
      if (action < 4) {
        // A swipe, from a random distance, sometimes mid-animation.
        final direction = random.nextBool() ? 1 : -1;
        bench.dragStart();
        _expectSane(bench.frame(), reason: 'after drag start, step $step');
        bench.dragBy(-direction * _travel * (0.05 + random.nextDouble() * 0.7));
        _expectSane(bench.frame(), reason: 'mid drag, step $step');
        bench.dragEnd(random.nextBool() ? 0 : direction * -900);
      } else if (action < 6) {
        // Playback catches up with whatever was just requested.
        if (bench.swipe.direction > 0) {
          final index = bench.ids.indexOf(bench.current);
          if (index + 1 < bench.ids.length) bench.catchUp();
        } else if (bench.swipe.direction < 0) {
          final index = bench.ids.indexOf(bench.current);
          if (index > 0) bench.play(bench.ids[index - 1]);
        }
      } else if (action < 8) {
        // A skip from outside the gesture, possibly mid-animation.
        final index = bench.ids.indexOf(bench.current);
        final target = (index + (random.nextBool() ? 1 : -1)).clamp(
          0,
          bench.ids.length - 1,
        );
        bench.play(bench.ids[target]);
      }

      for (var frame = 0; frame < 3; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        _expectSane(bench.frame(), reason: 'step $step');
      }
    }

    // Let everything land and check the cover is usable again.
    for (var i = 0; i < 400; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (!bench.animation.isAnimating) break;
    }
    await tester.pump(kCoverSettleTimeout);
    final frame = bench.frame();
    expect(
      frame.atRest,
      isTrue,
      reason: 'the cover never came to rest: $frame',
    );
    expect(frame.direction, 0);
    expect(
      frame.centreUrl,
      '${bench.current}.jpg',
      reason: 'the cover must show the track that is actually playing',
    );
  });
}
