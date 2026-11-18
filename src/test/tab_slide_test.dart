import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:yayma/src/features/core/views/widgets/tab_slide.dart';

const Key _a = ValueKey('a');
const Key _b = ValueKey('b');

/// Two tabs sharing a stack, exactly how the app layers its root buckets.
Widget _tabs(TargetPlatform platform, {required bool showB}) {
  Widget tab(String name, Key key, bool visible) => TabSlide(
    isVisible: visible,
    direction: 1,
    child: SizedBox.expand(key: key, child: Text(name)),
  );

  return MaterialApp(
    theme: ThemeData(platform: platform),
    home: Scaffold(
      body: Stack(children: [tab('A', _a, !showB), tab('B', _b, showB)]),
    ),
  );
}

Finder _child(Key key) => find.byKey(key, skipOffstage: false);

bool _offstage(WidgetTester tester, Key key) => tester
    .widget<Offstage>(
      find.ancestor(of: _child(key), matching: find.byType(Offstage)).first,
    )
    .offstage;

void main() {
  testWidgets('on Android the leaving tab slides out and the new one slides in '
      'from the side the selection moved to', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_tabs(TargetPlatform.android, showB: false));
    await tester.pumpAndSettle();
    expect(_offstage(tester, _a), isFalse);
    expect(_offstage(tester, _b), isTrue);

    await tester.pumpWidget(_tabs(TargetPlatform.android, showB: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Direction +1: B arrives from the right, A leaves to the left.
    expect(_offstage(tester, _b), isFalse);
    expect(tester.getTopLeft(_child(_b)).dx, greaterThan(0));
    expect(tester.getTopLeft(_child(_a)).dx, lessThan(0));

    await tester.pumpAndSettle();
    expect(tester.getTopLeft(_child(_b)).dx, 0);
    expect(_offstage(tester, _a), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop still swaps instantly', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_tabs(TargetPlatform.windows, showB: false));
    await tester.pumpWidget(_tabs(TargetPlatform.windows, showB: true));
    await tester.pump();

    expect(_offstage(tester, _b), isFalse);
    expect(tester.getTopLeft(_child(_b)).dx, 0);
    expect(
      find.descendant(
        of: find.byType(TabSlide),
        matching: find.byType(Opacity),
        skipOffstage: false,
      ),
      findsNothing,
    );
  });
}
