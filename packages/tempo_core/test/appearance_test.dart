import 'package:tempo_core/tempo_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

/// The player's UI is dressed by [Appearance], and one place refuses to
/// be: over home the bar paints no ground, and its readings sit on the
/// wallpaper, which is black in any light. The danger there is text that
/// resolves itself against the *page's* color and comes out near-black
/// on it, which is invisible rather than merely wrong - hence a test.
void main() {
  tearDown(() {
    Appearance.mode.value = AppearanceMode.dark;
    MenuDock.reset();
    MenuDock.selected.value = null;
  });

  Color colorOf(WidgetTester tester, Type of) {
    final text = tester.widget<Text>(
      find.descendant(of: find.byType(of), matching: find.byType(Text)).first,
    );
    return text.style!.color!;
  }

  /// The battery is painted, not set: its outline is the color to read.
  Color gaugeColor(WidgetTester tester) {
    final paint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(BatteryGauge),
        matching: find.byType(CustomPaint),
      ),
    );
    return (paint.painter! as BatteryGaugePainter).outline;
  }

  Future<ClickWheelController> pumpHome(
    WidgetTester tester,
    Brightness brightness,
  ) async {
    Appearance.mode.value = brightness == Brightness.dark
        ? AppearanceMode.dark
        : AppearanceMode.light;
    final wheel = ClickWheelController();
    await tester.pumpWidget(TempoApp(wheel: wheel));
    await tester.pumpAndSettle();
    return wheel;
  }

  for (final brightness in Brightness.values) {
    testWidgets('over home the bar keeps light text in a ${brightness.name} '
        'theme', (tester) async {
      await pumpHome(tester, brightness);

      // On black, both readings have to be legible whichever way the rest
      // of the UI is dressed.
      expect(colorOf(tester, ClockText).computeLuminance(), greaterThan(0.5));
      expect(gaugeColor(tester).computeLuminance(), greaterThan(0.5));
    });
  }

  testWidgets('over a page the bar wears the page\'s light', (tester) async {
    final wheel = await pumpHome(tester, Brightness.light);
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    wheel.jog(MenuDock.physics.weight);
    await tester.pumpAndSettle();
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    expect(find.text('Files'), findsOneWidget);
    expect(gaugeColor(tester).computeLuminance(), lessThan(0.5));
  });

  testWidgets('the menu follows the appearance', (tester) async {
    for (final brightness in Brightness.values) {
      Appearance.mode.value = brightness == Brightness.dark
          ? AppearanceMode.dark
          : AppearanceMode.light;
      await tester.pumpWidget(
        TomeApp(
          theme: Appearance.themeFor(brightness),
          debugShowCheckedModeBanner: false,
          home: MenuListScreen(entry: systemMenu.rootEntry),
        ),
      );
      await tester.pumpAndSettle();

      // An unselected row: the selected one is dark text on a lit band in
      // either theme, which is the selection speaking rather than the
      // appearance.
      final row = tester.widget<Text>(find.text('Settings'));
      expect(
        row.style!.color!.computeLuminance() > 0.5,
        brightness == Brightness.dark,
        reason: 'menu text in a ${brightness.name} theme',
      );
    }
    Appearance.mode.value = AppearanceMode.dark;
  });
}
