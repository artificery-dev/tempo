import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

void main() {
  late ClickWheelController wheel;
  late ValueNotifier<bool> enabled;
  var selected = 0;
  var activated = -1;
  Future<void> pump(
    WidgetTester tester, {
    bool alphabetical = false,
    int count = 100,
  }) async {
    wheel = ClickWheelController();
    enabled = ValueNotifier(true);
    selected = 0;
    activated = -1;
    addTearDown(enabled.dispose);
    await tester.pumpWidget(
      TomeApp(
        home: ClickWheelInput(
          controller: wheel,
          child: ValueListenableBuilder(
            valueListenable: enabled,
            builder: (context, on, _) => WheelAcceleration(
              enabled: on,
              child: Center(
                child: SizedBox(
                  width: 175,
                  height: 180,
                  child: WheelList.builder(
                    itemCount: count,
                    itemExtent: 20,
                    autofocus: true,
                    sectionOf: alphabetical
                        ? (i) => String.fromCharCode(65 + i ~/ 20)
                        : null,
                    onSelectionChanged: (i) => selected = i,
                    onActivate: (i) => activated = i,
                    itemBuilder: (context, i, chosen) => Text('Item $i'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> jog(
    WidgetTester tester, {
    int amount = 1,
    int delay = 50,
    bool page = false,
  }) async {
    await tester.pump(Duration(milliseconds: delay));
    wheel.jog(amount, page: page);
    await tester.pump();
  }

  Future<void> accelerate(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await jog(tester, delay: 150);
    }
  }

  testWidgets('long unordered lists accelerate, then return to single items', (
    tester,
  ) async {
    await pump(tester);
    for (var i = 0; i < 10; i++) {
      await jog(tester);
    }
    expect(selected, 10);
    await jog(tester);
    expect(selected, greaterThan(11));
    final fast = selected;
    await jog(tester, delay: 200);
    expect(selected, fast + 1);
    enabled.value = false;
    await tester.pump();
    final before = selected;
    for (var i = 0; i < 5; i++) {
      await jog(tester);
    }
    expect(selected, before + 5);
    expect(find.byKey(const ValueKey('WheelList.letters')), findsNothing);
  });

  testWidgets('letter browsing holds the list still and commits once on idle', (
    tester,
  ) async {
    await pump(tester, alphabetical: true, count: 200);
    await accelerate(tester);
    expect(selected, 4);
    final overlay = find.byKey(const ValueKey('WheelList.letters'));
    final scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    final offset = scrollable.position.pixels;
    await jog(tester);
    await jog(tester, delay: 250);
    await jog(tester, amount: -1, delay: 250);
    expect(selected, 4);
    expect(scrollable.position.pixels, offset);
    await tester.pump(const Duration(milliseconds: 990));
    expect(overlay, findsOneWidget);
    expect(selected, 4);
    await tester.pump(const Duration(milliseconds: 10));
    expect(selected, 20);
    expect(scrollable.position.pixels, selected * 20);
    expect(overlay, findsOneWidget);
    await tester.pumpAndSettle();
    expect(overlay, findsNothing);
    await jog(tester);
    expect(selected, 21);
    expect(tester.takeException(), isNull);
  });

  testWidgets('select commits the letter without activating its item', (
    tester,
  ) async {
    await pump(tester, alphabetical: true);
    await accelerate(tester);
    await jog(tester);
    expect(selected, 4);
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    expect(selected, 20);
    expect(activated, -1);
    wheel.press(WheelButton.select);
    expect(activated, 20);
  });

  testWidgets('overlay has one neighbor per side and a larger primary letter', (
    tester,
  ) async {
    await pump(tester, alphabetical: true, count: 200);
    await accelerate(tester);
    await jog(tester, amount: 3);
    await tester.pump(WheelList.modeTransition);
    final overlay = find.byKey(const ValueKey('WheelList.letters'));
    for (final letter in ['C', 'D', 'E']) {
      expect(
        find.descendant(of: overlay, matching: find.text(letter)),
        findsOneWidget,
      );
    }
    for (final letter in ['B', 'F']) {
      expect(
        find.descendant(of: overlay, matching: find.text(letter)),
        findsNothing,
      );
    }
    expect(
      find.descendant(of: overlay, matching: find.byType(AnimatedSwitcher)),
      findsNothing,
    );
    expect(
      find.descendant(of: overlay, matching: find.byType(Surface)),
      findsOneWidget,
    );
    final label = tester.widget<Text>(find.text('D'));
    final theme = ThemeProvider.of(tester.element(find.text('D')));
    expect(
      label.style?.fontSize,
      (theme.typography.display.fontSize ?? 20) * 2.4,
    );
    expect(
      label.style?.color,
      theme.widgets.surface
          .resolve(SemanticSwatch.primary, SurfaceVariant.soft)
          .foreground,
    );
    expect(tester.takeException(), isNull);
    await tester.pump(WheelList.accelerationIdle);
    await tester.pumpAndSettle();
    expect(selected, 60);
  });

  testWidgets(
    'brief fast bursts and hardware tiers cannot bypass entry delay',
    (tester) async {
      await pump(tester, alphabetical: true);
      for (var i = 0; i < 5; i++) {
        await jog(tester, page: true);
      }
      expect(selected, 5);
      expect(find.byKey(const ValueKey('WheelList.letters')), findsNothing);
      await jog(tester, delay: 1000);
      for (var i = 0; i < 5; i++) {
        await jog(tester, page: true);
      }
      expect(find.byKey(const ValueKey('WheelList.letters')), findsNothing);
      await tester.pump(WheelList.accelerationIdle);
    },
  );

  testWidgets(
    'slow scrolling enters letters only after sustained time in one direction',
    (tester) async {
      await pump(tester, alphabetical: true);
      await jog(tester);
      for (var i = 0; i < 4; i++) {
        await jog(tester, delay: 100, amount: i == 2 ? -1 : 1);
      }
      expect(find.byKey(const ValueKey('WheelList.letters')), findsNothing);
      // The last reversal was at 400 ms. The original 600 ms deadline
      // must not open letter mode; this direction needs its own full run.
      for (var i = 0; i < 5; i++) {
        await jog(tester, delay: 100);
        expect(find.byKey(const ValueKey('WheelList.letters')), findsNothing);
      }
      final before = selected;
      await jog(tester, delay: 100);
      expect(find.byKey(const ValueKey('WheelList.letters')), findsOneWidget);
      expect(selected, before);
      await tester.pump(WheelList.accelerationIdle);
      await tester.pumpAndSettle();
      expect(selected, 0);
    },
  );

  testWidgets('stopping before the duration never opens letters on its own', (
    tester,
  ) async {
    await pump(tester, alphabetical: true);
    await jog(tester);
    await jog(tester, delay: 250);
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.byKey(const ValueKey('WheelList.letters')), findsNothing);
    await tester.pump(WheelList.accelerationIdle);
    await jog(tester);
    expect(find.byKey(const ValueKey('WheelList.letters')), findsNothing);
    await tester.pump(WheelList.accelerationIdle);
  });

  testWidgets('disabling acceleration cancels pending letter selection', (
    tester,
  ) async {
    await pump(tester, alphabetical: true);
    await accelerate(tester);
    enabled.value = false;
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('WheelList.letters')), findsNothing);
    expect(selected, 4);
    await jog(tester, page: true);
    expect(selected, 5);
  });

  testWidgets(
    'letter browsing clamps to available sections before committing',
    (tester) async {
      await pump(tester, alphabetical: true);
      await accelerate(tester);
      await jog(tester, amount: 100);
      await tester.pump(WheelList.accelerationIdle);
      await tester.pumpAndSettle();
      expect(selected, 80);
      await accelerate(tester);
      await jog(tester, amount: -100);
      await jog(tester, amount: -1);
      expect(selected, 84);
      await tester.pump(WheelList.accelerationIdle);
      await tester.pumpAndSettle();
      expect(selected, 0);
      expect(tester.takeException(), isNull);
    },
  );

  test('the acceleration setting updates the shared input policy', () {
    final settings = Settings(tree: playerSettingsTree);
    SettingBindings.registerAll(PlayerSettings.sinks(PlayerServices.fallback));
    final bridge = SettingsBridge(settings: settings)..attach();
    addTearDown(() {
      bridge.detach();
      settings.dispose();
      SettingBindings.clear();
      WheelSettings.feel.value = WheelFeel.standard;
    });
    settings.set('/settings/controls/wheel/acceleration', false);
    expect(WheelSettings.feel.value.acceleration, isFalse);
    settings.set('/settings/controls/wheel/acceleration', true);
    expect(WheelSettings.feel.value.acceleration, isTrue);
  });

  test('the letter timing settings update the shared wheel timings', () {
    final settings = Settings(tree: playerSettingsTree);
    SettingBindings.registerAll(PlayerSettings.sinks(PlayerServices.fallback));
    final bridge = SettingsBridge(settings: settings)..attach();
    addTearDown(() {
      bridge.detach();
      settings.dispose();
      SettingBindings.clear();
      WheelSettings.letterEntry.value = WheelList.letterEntry;
      WheelSettings.letterIdle.value = WheelList.accelerationIdle;
    });
    settings.set('/settings/controls/wheel/letters-after', 1500);
    expect(WheelSettings.letterEntry.value, const Duration(milliseconds: 1500));
    settings.set('/settings/controls/wheel/letters-close', 3000);
    expect(WheelSettings.letterIdle.value, const Duration(seconds: 3));
    // Nonsense leaves the defaults in place.
    settings.set('/settings/controls/wheel/letters-close', 'soon');
    expect(WheelSettings.letterIdle.value, WheelList.accelerationIdle);
  });

  test('library letters use the same article handling as sorting', () {
    expect(MusicShelf.sectionOf('The Beatles'), 'B');
    expect(MusicShelf.sectionOf('An Artist'), 'A');
    expect(MusicShelf.sectionOf('123'), '#');
    expect(MusicShelf.sectionOf('Édith'), 'É');
    expect(MusicShelf.sectionOf('The File', ignoreArticles: false), 'T');
  });
}
