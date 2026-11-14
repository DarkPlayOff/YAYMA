import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';
import 'package:yayma/src/features/playback/views/queue_panel.dart';
import 'package:yayma/src/rust/api/models.dart';

SimpleTrackDto _track(int index) => SimpleTrackDto(
  id: '$index',
  title: 'Track $index',
  artists: const [],
  durationMs: 60000,
  coverUrl: 'cover.jpg',
  isLiked: false,
  isDisliked: false,
);

void main() {
  testWidgets('queue rows paint their hover ink inside the list', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    playerStateSignal.value = PlaybackState(
      isPlaying: true,
      isBuffering: false,
      volume: 100,
      isMuted: false,
      repeatMode: RepeatModeDto.none,
      isShuffled: false,
      queueCount: 10,
      queueIndex: 0,
      queueRevision: 0,
      currentTrack: _track(-1),
      currentWaveSeeds: const [],
    );

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: QueuePanel())),
    );
    await tester.pump(const Duration(milliseconds: 100));

    queueWindowSignal.setValue([for (var i = 0; i < 9; i++) _track(i)]);
    await tester.pump(const Duration(milliseconds: 100));

    final row = find
        .descendant(
          of: find.byType(CustomScrollView),
          matching: find.byType(InkWell),
        )
        .first;
    expect(row, findsOneWidget);

    // Ink is painted by the nearest Material above the row. On the dialog's
    // Material that clip is the whole panel, so a row at the list edge
    // highlights the area under the actions instead of stopping at the edge.
    final inkMaterial = tester.widget<Material>(
      find.ancestor(of: row, matching: find.byType(Material)).first,
    );
    expect(
      find.descendant(
        of: find.byType(CustomScrollView),
        matching: find.byWidget(inkMaterial),
      ),
      findsOneWidget,
    );
  });
}
