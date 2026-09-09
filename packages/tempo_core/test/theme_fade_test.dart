import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tomeui/tomeui.dart';

/// The light going up or down as a fade: the frame as it stood is held over
/// the new theme and fades away.
void main() {
  Widget under(Brightness brightness) => TomeApp(
    theme: Theme(palette: Palette(brightness: brightness)),
    debugShowCheckedModeBanner: false,
    home: ThemeFade(
      brightness: brightness,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeInOut,
      child: const ColoredBox(
        color: Color(0xFF123456),
        child: SizedBox.expand(
          child: Text('page', textDirection: TextDirection.ltr),
        ),
      ),
    ),
  );

  /// The held frame, if one is up.
  Finder held() => find.byKey(ThemeFade.heldKey);

  testWidgets('at rest nothing is held over the page', (tester) async {
    await tester.pumpWidget(under(Brightness.dark));
    await tester.pumpAndSettle();
    expect(held(), findsNothing);
    expect(find.text('page'), findsOneWidget);
  });

  testWidgets('the light changing holds the frame, and lets it go', (
    tester,
  ) async {
    await tester.pumpWidget(under(Brightness.dark));
    await tester.pumpAndSettle();

    await tester.pumpWidget(under(Brightness.light));
    await tester.pump();
    // The old frame is up over the new one...
    expect(
      held(),
      findsOneWidget,
      reason: 'the frame before the change should be held over the new one',
    );

    // ...fading, not sitting there...
    await tester.pump(const Duration(milliseconds: 120));
    final opacity = tester.widget<FadeTransition>(
      find.descendant(of: held(), matching: find.byType(FadeTransition)),
    );
    expect(opacity.opacity.value, greaterThan(0.0));
    expect(opacity.opacity.value, lessThan(1.0));

    // ...and gone once it is done, so nothing is left over the live tree.
    await tester.pumpAndSettle();
    expect(held(), findsNothing);
  });

  testWidgets('the held frame takes no words and no pointer', (tester) async {
    await tester.pumpWidget(under(Brightness.dark));
    await tester.pumpAndSettle();
    await tester.pumpWidget(under(Brightness.light));
    await tester.pump();

    expect(
      find.descendant(of: held(), matching: find.byType(IgnorePointer)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: held(), matching: find.byType(ExcludeSemantics)),
      findsOneWidget,
    );
    await tester.pumpAndSettle();
  });

  testWidgets('a rebuild in the same light holds nothing', (tester) async {
    await tester.pumpWidget(under(Brightness.dark));
    await tester.pumpAndSettle();
    // The theme moves for other reasons too - a color, a scale - and those
    // are not what this is for.
    await tester.pumpWidget(under(Brightness.dark));
    await tester.pump();
    expect(held(), findsNothing);
  });
}
