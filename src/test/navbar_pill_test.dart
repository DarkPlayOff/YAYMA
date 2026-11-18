import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:yayma/src/features/core/views/layout/navigation_bar.dart';

/// Width the label occupies inside its item: 0 while it is hidden, the full
/// text width once the item is selected.
double _reveal(WidgetTester tester, String label) => tester
    .getSize(
      find
          .ancestor(of: find.text(label), matching: find.byType(ClipRect))
          .first,
    )
    .width;

void main() {
  testWidgets('selected item reveals its label, others keep a bare icon', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(500, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: const Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: FloatingNavBar(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Главная'), findsOneWidget);
    final revealed = _reveal(tester, 'Главная');
    expect(revealed, greaterThan(0));
    expect(_reveal(tester, 'Поиск'), 0);

    await tester.tap(find.byIcon(Icons.search_rounded));
    // Mid-flight the reveal is between hidden and open: a spring, not a jump.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final midway = _reveal(tester, 'Поиск');

    await tester.pumpAndSettle();
    final open = _reveal(tester, 'Поиск');
    expect(midway, greaterThan(0));
    expect(midway, lessThan(open));
    expect(_reveal(tester, 'Главная'), 0);

    await tester.tap(find.byIcon(Icons.library_music_rounded));
    await tester.pumpAndSettle();
    expect(_reveal(tester, 'Поиск'), 0);
    expect(_reveal(tester, 'Библиотека'), greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('no ink splash on the phone; the desktop rail keeps it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(500, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    Future<void> pumpOn(TargetPlatform platform) => tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: platform),
        home: const Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: FloatingNavBar(),
          ),
        ),
      ),
    );

    ButtonStyle? styleOf() => tester
        .widget<IconButton>(
          find.ancestor(
            of: find.byIcon(Icons.search_rounded),
            matching: find.byType(IconButton),
          ),
        )
        .style;

    await pumpOn(TargetPlatform.android);
    await tester.pumpAndSettle();
    expect(styleOf()!.splashFactory, NoSplash.splashFactory);
    expect(
      styleOf()!.overlayColor?.resolve({WidgetState.pressed}),
      Colors.transparent,
    );

    await pumpOn(TargetPlatform.windows);
    await tester.pumpAndSettle();
    expect(styleOf(), isNull);
  });
}
