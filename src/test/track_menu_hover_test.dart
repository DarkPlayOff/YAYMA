import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:yayma/src/features/core/views/widgets/track_tile.dart';
import 'package:yayma/src/features/library/providers/library_provider.dart';

/// Rows live in M3E segmented lists (albums, liked tracks, search, history).
/// Opening the menu used to focus the segmented item, which recreates its
/// subtree: the row and the open menu died as soon as the pointer moved into
/// the popup, and only the second attempt worked. Submenus ("Скачать") open on
/// hover, which needs focus — so the popup must live outside the row's focus
/// subtree, not be merely unfocusable.
void main() {
  setUp(() {
    trackPlaylistMembershipSignal.value = {};
  });

  testWidgets('context menu survives moving the pointer into it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              SliverM3ESegmentedList(
                itemCount: 20,
                padding: EdgeInsets.zero,
                itemBuilder: (context, i) => CommonTrackTile(
                  trackId: '$i',
                  title: 'Test track $i',
                  artists: const [],
                  trailing: const Text('3:45'),
                  onTap: () {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    await mouse.moveTo(tester.getCenter(find.text('Test track 2')));
    await tester.pumpAndSettle();

    final moreButton = tester.getCenter(
      find.byIcon(Icons.more_horiz_rounded).first,
    );
    await mouse.moveTo(moreButton);
    await tester.pumpAndSettle();
    await mouse.down(moreButton);
    await mouse.up();
    await tester.pumpAndSettle();

    final menuItem = find.text('О треке');
    expect(menuItem, findsOneWidget, reason: 'menu opens on click');

    // Walk into the popup the way a cursor does.
    final to = tester.getCenter(menuItem);
    for (var step = 1; step <= 10; step++) {
      await mouse.moveTo(Offset.lerp(moreButton, to, step / 10)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();

    expect(menuItem, findsOneWidget, reason: 'menu stays open');

    // Submenus open on hover, so the popup still needs working focus.
    await mouse.moveTo(tester.getCenter(find.text('Скачать')));
    await tester.pumpAndSettle();
    expect(
      find.text('В кэш приложения'),
      findsOneWidget,
      reason: 'hover opens the submenu',
    );
  });

  testWidgets('open menu survives the row rebuilding', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              SliverM3ESegmentedList(
                itemCount: 20,
                padding: EdgeInsets.zero,
                itemBuilder: (context, i) => CommonTrackTile(
                  trackId: '$i',
                  title: 'Test track $i',
                  artists: const [],
                  trailing: const Text('3:45'),
                  onTap: () {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    await mouse.moveTo(tester.getCenter(find.text('Test track 2')));
    await tester.pumpAndSettle();
    final moreButton = tester.getCenter(
      find.byIcon(Icons.more_horiz_rounded).first,
    );
    await mouse.moveTo(moreButton);
    await tester.pumpAndSettle();
    await mouse.down(moreButton);
    await mouse.up();
    await tester.pumpAndSettle();

    expect(find.text('О треке'), findsOneWidget);

    // The membership fetch landing while the menu is open rebuilds the tile.
    trackPlaylistMembershipSignal.value = {
      '2': {1},
    };
    await tester.pumpAndSettle();

    expect(find.text('О треке'), findsOneWidget, reason: 'no rebuild crash');
  });

  testWidgets('scrolling closes the menu', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              SliverM3ESegmentedList(
                itemCount: 40,
                padding: EdgeInsets.zero,
                itemBuilder: (context, i) => CommonTrackTile(
                  trackId: '$i',
                  title: 'Test track $i',
                  artists: const [],
                  trailing: const Text('3:45'),
                  onTap: () {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    await mouse.moveTo(tester.getCenter(find.text('Test track 2')));
    await tester.pumpAndSettle();
    final moreButton = tester.getCenter(
      find.byIcon(Icons.more_horiz_rounded).first,
    );
    await mouse.moveTo(moreButton);
    await tester.pumpAndSettle();
    await mouse.down(moreButton);
    await mouse.up();
    await tester.pumpAndSettle();
    expect(find.text('О треке'), findsOneWidget);

    await tester.sendEventToBinding(
      PointerScrollEvent(position: moreButton, scrollDelta: const Offset(0, 300)),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('О треке'),
      findsNothing,
      reason: 'a detached popup would act on the wrong row',
    );
  });
}
