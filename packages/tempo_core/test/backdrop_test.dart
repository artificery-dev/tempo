import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

/// Page Tint and Translucent Surfaces.
///
/// The model they answer to: a page is not a surface. The surfaces are the
/// things the wheel can land on - a card, a row, the dock, the bar - and
/// the room between them is the wallpaper. You see the picture *around* a
/// solid card and *through* a translucent one.
///
/// So the two settings are two different questions, and neither is about
/// the page:
///
///  * Translucent Surfaces is whether a surface lets the picture through
///    it at all. It is the one that moves opacity.
///  * Page Tint is how far a surface stands off the page behind it - a
///    shade on the neutral ramp. It moves color, never opacity.
void main() {
  setUp(() {
    Backdropped.tint.value = Backdropped.solid;
    Glass.enabled.value = true;
  });

  tearDown(() {
    Backdropped.tint.value = Backdropped.solid;
    Glass.enabled.value = true;
    MenuDock.reset();
    MenuDock.selected.value = null;
  });

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      TomeApp(debugShowCheckedModeBanner: false, home: child),
    );
    await tester.pumpAndSettle();
  }

  const dark = Palette(brightness: Brightness.dark);
  const light = Palette(brightness: Brightness.light);

  group('the tint is a tone', () {
    test('it moves the color of a surface and not its opacity', () {
      Glass.enabled.value = false;
      Backdropped.tint.value = Backdropped.faint;
      final flat = Backdropped.surfaceOf(dark);
      Backdropped.tint.value = 1;
      final full = Backdropped.surfaceOf(dark);

      expect(full, isNot(flat), reason: 'the tint moved nothing');
      expect(full.a, flat.a, reason: 'the tint moved the opacity');
    });

    test('and the same way with the surfaces translucent', () {
      Backdropped.tint.value = Backdropped.faint;
      final flat = Backdropped.surfaceOf(dark);
      Backdropped.tint.value = 1;
      final full = Backdropped.surfaceOf(dark);

      expect(full, isNot(flat));
      expect(full.a, closeTo(flat.a, 0.001));
    });

    test('turned up, a surface stands further off the page behind it', () {
      double apart(Palette palette) {
        final surface = Backdropped.tone(palette);
        return (surface.r - palette.background.r).abs() +
            (surface.g - palette.background.g).abs() +
            (surface.b - palette.background.b).abs();
      }

      for (final palette in [dark, light]) {
        Backdropped.tint.value = Backdropped.faint;
        final flat = apart(palette);
        Backdropped.tint.value = 1;
        final full = apart(palette);
        expect(
          full,
          greaterThan(flat),
          reason: '${palette.brightness}: turning it up flattened the card',
        );
      }
    });

    test('the ends of the range are the page and the page color', () {
      Backdropped.tint.value = Backdropped.faint;
      expect(Backdropped.tone(dark), dark.background);
      expect(Backdropped.tone(light), light.background);

      Backdropped.tint.value = 1;
      expect(Backdropped.tone(dark), dark.surface);
      expect(Backdropped.tone(light), light.surface);
    });
  });

  group('translucency is the opacity', () {
    test('off, a surface is solid, whatever the tint says', () {
      Glass.enabled.value = false;
      for (final at in [0.4, 0.7, 1.0]) {
        Backdropped.tint.value = at;
        expect(
          Backdropped.surfaceOf(dark).a,
          1.0,
          reason: 'a surface at tint $at still let the picture through',
        );
      }
    });

    test('on, the picture comes through - and more of it out in the flow, '
        'which is the picture\'s moment', () {
      expect(Backdropped.surfaceOf(dark).a, closeTo(Glass.tint, 0.001));
      expect(
        Backdropped.surfaceOf(dark, focus: 0).a,
        closeTo(Glass.faint, 0.001),
      );
    });
  });

  group('a page is not a surface', () {
    testWidgets('a page paints nothing: the wallpaper is what is behind it', (
      tester,
    ) async {
      await pump(
        tester,
        const Backdropped(backdrop: Backdrop.clear, child: SizedBox.expand()),
      );
      final inside = find.descendant(
        of: find.byType(Backdropped),
        matching: find.byType(ColoredBox),
      );
      expect(inside, findsNothing);

      // Neither setting gives it one. This is the whole of it: a solid
      // card is meant to have the picture around it, not a slab of page
      // color.
      Glass.enabled.value = false;
      Backdropped.tint.value = 1;
      await tester.pump();
      expect(inside, findsNothing);
    });

    testWidgets('and a screen that is a list of surfaces asks for that', (
      tester,
    ) async {
      await pump(
        tester,
        const PanelScreen(title: 'Files', child: SizedBox.expand()),
      );
      expect(
        tester.widget<PanelScreen>(find.byType(PanelScreen)).backdrop,
        Backdrop.clear,
      );
    });

    testWidgets('only a screen that is one surface takes a ground', (
      tester,
    ) async {
      await pump(
        tester,
        const Backdropped(backdrop: Backdrop.opaque, child: SizedBox.expand()),
      );
      expect(
        find.descendant(
          of: find.byType(Backdropped),
          matching: find.byType(ColoredBox),
        ),
        findsOneWidget,
      );
    });
  });

  group('the surfaces themselves', () {
    Color fillOf(WidgetTester tester, Finder of) =>
        (tester
                    .widgetList<DecoratedBox>(
                      find.descendant(
                        of: of,
                        matching: find.byType(DecoratedBox),
                      ),
                    )
                    .first
                    .decoration
                as BoxDecoration)
            .color!;

    testWidgets('a settings card wears the tone, at the opacity', (
      tester,
    ) async {
      await pump(
        tester,
        const SettingCard(first: true, last: true, child: SizedBox(height: 40)),
      );
      final finder = find.byType(SettingCard);

      final before = fillOf(tester, finder);
      expect(before.a, closeTo(Glass.tint, 0.01));

      // The tone moves with the tint, and only the tone.
      Backdropped.tint.value = 1;
      await tester.pump();
      final tinted = fillOf(tester, finder);
      expect(tinted, isNot(before));
      expect(tinted.a, closeTo(before.a, 0.01));

      // And the opacity with the other one, and only the opacity.
      Glass.enabled.value = false;
      await tester.pump();
      final solid = fillOf(tester, finder);
      expect(solid.a, 1.0);
      expect(
        (solid.r, solid.g, solid.b),
        (tinted.r, tinted.g, tinted.b),
        reason: 'turning translucency off changed the shade too',
      );
    });

    testWidgets('so does the dock\'s glass', (tester) async {
      await pump(tester, const Glass(child: SizedBox.expand()));
      final finder = find.byType(Glass);

      expect(fillOf(tester, finder).a, closeTo(Glass.tint, 0.01));

      Glass.enabled.value = false;
      await tester.pump();
      expect(fillOf(tester, finder).a, 1.0);
    });

    testWidgets('and the bar and the dock, which are surfaces too', (
      tester,
    ) async {
      final wheel = ClickWheelController();
      await tester.pumpWidget(PanelSurface(child: TempoApp(wheel: wheel)));
      await tester.pumpAndSettle();

      // Home > dock > Apps, then the dock back up over it, so the bar's
      // band and the dock are both on screen.
      wheel.press(WheelButton.select);
      await tester.pumpAndSettle();
      wheel.jog(MenuDock.physics.weight);
      await tester.pumpAndSettle();
      wheel.press(WheelButton.select);
      await tester.pumpAndSettle();
      MenuDock.shown.value = true;
      await tester.pumpAndSettle();

      final bar = find.byType(StatusBar).first;
      final dock = find.byType(Glass).first;

      Glass.enabled.value = false;
      Backdropped.tint.value = 1;
      await tester.pump();
      final barFull = fillOf(tester, bar);
      final dockFull = fillOf(tester, dock);
      expect(barFull.a, 1.0);
      expect(dockFull.a, 1.0);

      // The tint moves the shade of both.
      Backdropped.tint.value = Backdropped.faint;
      await tester.pump();
      expect(fillOf(tester, bar), isNot(barFull));
      expect(fillOf(tester, dock), isNot(dockFull));
      expect(
        fillOf(tester, bar).a,
        1.0,
        reason:
            'the tint moved the bar\'s '
            'opacity',
      );
      expect(fillOf(tester, dock).a, 1.0);

      // And translucency moves the opacity of both.
      Glass.enabled.value = true;
      await tester.pump();
      expect(fillOf(tester, bar).a, closeTo(Glass.tint, 0.01));
      expect(fillOf(tester, dock).a, closeTo(Glass.tint, 0.01));
    });

    testWidgets('and the bar over a page', (tester) async {
      final wheel = ClickWheelController();
      await tester.pumpWidget(PanelSurface(child: TempoApp(wheel: wheel)));
      await tester.pumpAndSettle();

      // Home > dock > Apps: a page whose bar has a ground under it.
      wheel.press(WheelButton.select);
      await tester.pumpAndSettle();
      wheel.jog(MenuDock.physics.weight);
      await tester.pumpAndSettle();
      wheel.press(WheelButton.select);
      await tester.pumpAndSettle();

      final bar = find.byType(StatusBar).first;
      expect(fillOf(tester, bar).a, closeTo(Glass.tint, 0.01));

      Glass.enabled.value = false;
      await tester.pump();
      expect(fillOf(tester, bar).a, 1.0);
    });
  });
}
