import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:yayma/src/features/core/views/layout/mobile_cover_swipe.dart';
import 'package:yayma/src/features/core/views/layout/mobile_full_player.dart';
import 'package:yayma/src/features/core/views/widgets/rust_cached_image.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/models.dart';

const _coverTravel = 344.0;

SimpleTrackDto _track(String id) => SimpleTrackDto(
  id: id,
  title: id,
  artists: const [],
  durationMs: 1000,
  coverUrl: '$id.jpg',
  isLiked: false,
  isDisliked: false,
);

const _ids = ['a', 'b', 'c', 'd', 'e'];

/// One cover as it is painted on screen.
class _Cover {
  const _Cover({
    required this.url,
    required this.rect,
    required this.opacity,
    required this.order,
  });

  final String? url;

  /// Painted rect in screen coordinates, transforms included.
  final Rect rect;
  final double opacity;

  /// Position in the widget stack: higher is painted on top.
  final int order;

  bool contains(Offset point) => rect.contains(point) && opacity > 0.5;

  @override
  String toString() =>
      '${url ?? '-'}@${rect.left.toStringAsFixed(0)}'
      '..${rect.right.toStringAsFixed(0)} op=${opacity.toStringAsFixed(2)}';
}

/// Drives the real full player the way a finger and the player state do.
class _Player {
  _Player(this.tester);

  final WidgetTester tester;

  /// Track playback is on, as reported by the state signal.
  String current = 'a';

  Size get screen => tester.view.physicalSize / tester.view.devicePixelRatio;

  double get _coverY =>
      covers.isEmpty ? screen.height / 2 : covers.last.rect.center.dy;

  Offset get centre => Offset(screen.width / 2, _coverY);

  Future<void> mount({String start = 'a'}) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    current = start;
    _publish(current);
    await tester.pumpWidget(
      MaterialApp(
        home: MobileFullPlayer(
          plateRect: const Rect.fromLTWH(0, 700, 360, 400),
          coverRect: const Rect.fromLTWH(20, 100, 300, 300),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    await publishQueue();
  }

  void _publish(String id) {
    playerStateSignal.value = PlaybackState(
      isPlaying: true,
      isBuffering: false,
      volume: 100,
      isMuted: false,
      repeatMode: RepeatModeDto.none,
      isShuffled: false,
      queueCount: _ids.length,
      queueIndex: _ids.indexOf(id),
      currentTrack: _track(id),
      currentWaveSeeds: const [],
    );
  }

  /// [queueTracksSignal] is filled from Rust in the app; the test injects the
  /// list it would return. Every state change makes the signal re-fetch, so it
  /// has to be re-injected afterwards.
  Future<void> publishQueue() async {
    queueTracksSignal.setValue(_ids.map(_track).toList());
    await tester.pump();
  }

  /// Playback reports [id].
  Future<void> report(String id) async {
    current = id;
    _publish(id);
    await tester.pump();
    await publishQueue();
  }

  /// The cover squares that are on screen, in paint order.
  List<_Cover> get covers {
    // Each cover shows a low-resolution placeholder inside the full-size
    // artwork; only the artwork is a cover in its own right.
    final images = tester
        .widgetList<RustCachedImage>(find.byType(RustCachedImage))
        .where((image) => image.placeholder != null)
        .toList();
    return [
      for (var i = 0; i < images.length; i++)
        _Cover(
          url: images[i].imageUrl,
          rect: tester.getRect(find.byWidget(images[i])),
          opacity: _opacityOf(images[i]),
          order: i,
        ),
    ];
  }

  double _opacityOf(RustCachedImage image) {
    final opacity = find
        .ancestor(of: find.byWidget(image), matching: find.byType(Opacity))
        .evaluate();
    if (opacity.isEmpty) return 1;
    return tester.widget<Opacity>(find.byWidget(opacity.first.widget)).opacity;
  }

  /// Artwork the user sees at [point], or null where no cover is painted.
  String? artAt(Offset point) {
    final hits = covers.where((cover) => cover.contains(point)).toList();
    if (hits.isEmpty) return null;
    hits.sort((a, b) => a.order.compareTo(b.order));
    return hits.last.url;
  }

  String? get centreArt => artAt(centre);

  /// Artworks painted anywhere on screen, in paint order.
  List<String?> get painted =>
      covers.where((cover) => cover.opacity > 0.5).map((c) => c.url).toList();

  /// The central cover: the one at rest (or nearest to rest) on screen.
  _Cover get central {
    final onScreen = covers.where((cover) => cover.opacity > 0.5).toList();
    onScreen.sort((a, b) => a.rect.left.abs().compareTo(b.rect.left.abs()));
    return onScreen.first;
  }

  bool get moving => _moving;
  bool _moving = false;

  Future<void> pump([Duration by = const Duration(milliseconds: 16)]) async {
    final before = covers.map((c) => c.rect).toList();
    await tester.pump(by);
    final now = covers.map((c) => c.rect).toList();
    _moving =
        before.length != now.length ||
        [
          for (var i = 0; i < now.length && i < before.length; i++)
            (now[i].left - before[i].left).abs() > 0.01,
        ].any((changed) => changed);
  }

  /// Pumps until nothing moves any more, including the frame in which the
  /// slide finishes and settles its state (that callback runs on a microtask).
  Future<void> settle({int frames = 400}) async {
    var still = 0;
    for (var i = 0; i < frames; i++) {
      await pump(const Duration(milliseconds: 16));
      if (_moving) {
        still = 0;
      } else if (++still >= 2) {
        break;
      }
    }
    await pump();
    await pump();
  }

  /// Starts a real horizontal drag at [from] (the middle of the cover unless
  /// told otherwise).
  Future<TestGesture> touch({Offset? from}) async {
    final gesture = await tester.startGesture(from ?? centre);
    await pump();
    return gesture;
  }

  /// Drags [distance] logical pixels to the right (negative = left) in [steps].
  Future<void> dragBy(
    TestGesture gesture,
    double distance, {
    int steps = 6,
  }) async {
    for (var i = 0; i < steps; i++) {
      await gesture.moveBy(Offset(distance / steps, 0));
      await pump();
    }
  }

  /// A whole swipe: drag and release, without playback catching up. Returns
  /// whether the cover started moving towards a neighbour.
  Future<bool> swipe(double distance, {int steps = 6, Offset? from}) async {
    final gesture = await touch(from: from);
    await dragBy(gesture, distance, steps: steps);
    final sliding = moving;
    await gesture.up();
    // The first frame after a release only seeds the ticker; the second one is
    // the first that shows the cover moving.
    await pump();
    await pump();
    return sliding;
  }

  String describe() =>
      'current=$current painted=$painted centre=$centreArt '
      'covers=${covers.map((c) => c.toString()).toList()}';
}

/// Invariants of the carousel as the user sees it.
void _expectSane(_Player player, {String? reason}) {
  final suffix = reason == null ? '' : ' ($reason)';
  final visible = player.covers.where((cover) => cover.opacity > 0.5).toList();
  expect(
    visible.length,
    lessThanOrEqualTo(2),
    reason: 'more than two covers are painted$suffix: ${player.describe()}',
  );
  for (var i = 0; i < visible.length; i++) {
    for (var j = i + 1; j < visible.length; j++) {
      expect(
        visible[i].rect.overlaps(visible[j].rect),
        isFalse,
        reason:
            'two covers are painted on top of each other$suffix: '
            '${player.describe()}',
      );
      expect(
        visible[i].url,
        isNot(visible[j].url),
        reason:
            'the same artwork is painted twice$suffix: ${player.describe()}',
      );
    }
  }
}

void main() {
  testWidgets('a swipe slides the next cover in and lands on it', (
    tester,
  ) async {
    final player = _Player(tester);
    await player.mount();
    expect(player.centreArt, 'a.jpg');

    final gesture = await player.touch();
    await player.dragBy(gesture, -60);
    expect(player.painted, containsAll(<String?>['a.jpg', 'b.jpg']));
    expect(player.artAt(Offset(60, player._coverY)), 'a.jpg');

    await player.dragBy(gesture, -160);
    await gesture.up();
    await player.pump();
    await player.report('b');
    await player.settle();

    expect(player.centreArt, 'b.jpg');
    expect(player.moving, isFalse);
  });

  testWidgets('a committed slide comes to rest and frees the gesture quickly', (
    tester,
  ) async {
    final player = _Player(tester);
    await player.mount();

    await player.swipe(-220);
    var elapsed = 0;
    while (player.moving && elapsed < 2000) {
      await player.pump();
      elapsed += 16;
    }
    // The cover only animates until it is visually there; holding the swipe
    // state for a tail of invisible motion is what made rapid gestures stick.
    expect(
      elapsed,
      lessThan(368),
      reason: 'the slide kept moving for $elapsed ms',
    );
    expect(player.centreArt, 'b.jpg', reason: 'the requested cover is shown');

    // A new drag right after the visual landing must move the cover at once.
    final before = player.central.rect.left;
    final gesture = await player.touch();
    await player.dragBy(gesture, -40, steps: 2);
    expect(
      player.central.rect.left,
      moreOrLessEquals(before - 40, epsilon: 1),
      reason: 'the first 40 px of the next swipe were swallowed',
    );
    await gesture.up();
    await player.pump();
    await player.report('c');
    await player.settle();
    _expectSane(player);
  });

  testWidgets('a burst of skips does not retarget the artwork in flight', (
    tester,
  ) async {
    final player = _Player(tester);
    await player.mount();

    await player.swipe(-220);
    await player.pump(const Duration(milliseconds: 30));
    final outgoing = player.artAt(Offset(60, player._coverY));
    final incoming = player.painted.last;

    // Playback jumps two tracks ahead while the cover is still sliding.
    await player.report('c');
    await player.pump();
    expect(
      player.artAt(Offset(60, player._coverY)),
      outgoing,
      reason: 'the outgoing artwork stays put in flight: ${player.describe()}',
    );
    expect(player.painted, contains(incoming));

    await player.settle();
    await player.settle();
    expect(
      player.centreArt,
      'c.jpg',
      reason: 'it catches up to the live track',
    );
    _expectSane(player);
  });

  testWidgets('grabbing a sliding cover applies the skip at once, no half-way', (
    tester,
  ) async {
    final player = _Player(tester);
    await player.mount();
    final restLeft = player.central.rect.left;

    // The swipe commits, the slide towards the next cover is still running.
    await player.swipe(-140);
    await player.pump(const Duration(milliseconds: 16));
    final finger = Offset(80, player._coverY);
    expect(
      player.artAt(finger),
      'a.jpg',
      reason: 'the outgoing cover is still under the finger',
    );

    // The skip already went out, so the first movement takes the slide over:
    // the cover jumps to its rest position under the finger (the gesture that
    // was moving fast would otherwise stay frozen half-way), never to a blank.
    final gesture = await player.touch(from: finger);
    await player.dragBy(gesture, -20, steps: 1);
    expect(
      player.central.rect.left,
      moreOrLessEquals(restLeft - 20, epsilon: 0.5),
      reason:
          'the grab leaves the carousel off its rest position: '
          '${player.describe()}',
    );
    expect(player.centreArt, 'b.jpg', reason: 'the skip already went through');
    _expectSane(player);

    // The same finger can ask for one more skip.
    await player.dragBy(gesture, -220);
    await gesture.up();
    await player.pump();
    await player.report('c');
    await player.settle();

    _expectSane(player);
    expect(player.centreArt, 'c.jpg');
    expect(player.central.rect.left, moreOrLessEquals(restLeft, epsilon: 0.5));
  });

  testWidgets('two swift swipes skip twice and end on the second track', (
    tester,
  ) async {
    final player = _Player(tester);
    await player.mount();

    await player.swipe(-220);
    await player.report('b');
    await player.pump(const Duration(milliseconds: 40));
    await player.swipe(-220);
    await player.report('c');
    await player.settle();

    expect(player.centreArt, 'c.jpg');
    _expectSane(player);
  });

  testWidgets('a grab during a rollback does not skip', (tester) async {
    final player = _Player(tester);
    await player.mount();

    final gesture = await player.touch();
    await player.dragBy(gesture, -40);
    await gesture.up();
    await player.pump(const Duration(milliseconds: 40));

    // Grab the cover again while it springs back.
    final second = await player.touch();
    await player.dragBy(second, 40);
    await second.up();
    await player.settle();

    expect(player.centreArt, 'a.jpg');
  });

  testWidgets('the last track damps the swipe instead of pulling a ghost', (
    tester,
  ) async {
    final player = _Player(tester);
    await player.mount(start: 'e');
    await player.report('e');

    final gesture = await player.touch();
    await player.dragBy(gesture, -260);
    final moved = player.moving;
    await gesture.up();
    await player.settle();

    expect(
      moved,
      isTrue,
      reason: 'the cover still follows the finger a little',
    );
    expect(player.centreArt, 'e.jpg');
    expect(player.painted.where((url) => url != 'e.jpg'), isEmpty);
  });

  testWidgets('a failed skip gives the artwork back to what is playing', (
    tester,
  ) async {
    final player = _Player(tester);
    await player.mount();

    // The swipe commits, playback never reports the new track.
    await player.swipe(-220);
    await player.settle();
    expect(player.centreArt, 'b.jpg', reason: 'the requested art is shown');

    await tester.pump(kCoverSettleTimeout + const Duration(seconds: 1));
    await player.settle();
    expect(player.centreArt, 'a.jpg', reason: 'back to what is playing');
  });

  testWidgets('rapid random gestures keep one sane cover on screen', (
    tester,
  ) async {
    final random = Random(7);
    final player = _Player(tester);
    await player.mount();

    for (var step = 0; step < 25; step++) {
      final forward = random.nextBool();
      final distance = -(60 + random.nextDouble() * 240);
      final index = _ids.indexOf(player.current);
      // Swiping past either end cannot commit; the player never does either.
      final canSkip = forward ? index < _ids.length - 1 : index > 0;

      final before = player.painted.toSet();
      final gesture = await player.touch(
        from: player.centre + Offset(forward ? -20 : 20, 0),
      );
      await player.dragBy(
        gesture,
        forward ? distance : -distance,
        steps: 1 + random.nextInt(6),
      );
      await gesture.up();
      await player.pump(const Duration(milliseconds: 16));
      _expectSane(player, reason: 'step $step');

      // Playback applies the skip the gesture just asked for.
      if (canSkip && player.painted.toSet() != before) {
        await player.report(_ids[index + (forward ? 1 : -1)]);
      }
      await tester.pump(const Duration(milliseconds: 32));
    }

    await player.settle();
    expect(
      player.centreArt,
      '${player.current}.jpg',
      reason: 'the cover must show what is playing: ${player.describe()}',
    );
    expect(
      player.central.rect.left.abs(),
      lessThan(_coverTravel / 2),
      reason: 'the cover came to rest off centre: ${player.describe()}',
    );
  });
}
