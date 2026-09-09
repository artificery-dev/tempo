import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

/// Picking a time zone: the areas, then the places in one, and what
/// choosing one moves - the setting, and where Auto thinks it is.
///
/// Driven by the wheel throughout, because that is the only way around
/// this screen: the Y2 has no touch panel, so a row is reached by jogging
/// to it and thrown by the center button.
void main() {
  late Settings settings;
  late SettingsBridge bridge;
  late ClickWheelController wheel;

  final zone = playerSettingsTree.at('/settings/system/time/zone')!;
  const path = '/settings/system/time/zone';

  setUp(() {
    PlayerSettingScreens.install();
    settings = Settings(tree: playerSettingsTree);
    // The far end, as the player wires it: the sink alone moves nothing
    // until a bridge is carrying changes to it.
    SettingBindings.registerAll(PlayerSettings.sinks(PlayerServices.fallback));
    bridge = SettingsBridge(settings: settings)..attach();
    wheel = ClickWheelController();
  });

  tearDown(() {
    bridge.detach();
    ClockZone.selected.value = 'UTC';
    SettingBindings.clear();
    Appearance.place.value = null;
    Appearance.mode.value = AppearanceMode.dark;
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      TomeApp(
        debugShowCheckedModeBanner: false,
        home: SettingsScope(
          settings: settings,
          // Above the navigator, as TempoApp puts it: the words reach
          // whichever page is on top.
          child: ClickWheelInput(
            controller: wheel,
            child: Navigator(
              onGenerateRoute: (_) => PanelRoute(
                settings: const RouteSettings(name: '/settings/system/time'),
                builder: (_) => SettingScreens.pageFor(zone),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Walk [rows] rows down the list and throw the row landed on.
  Future<void> choose(WidgetTester tester, int rows) async {
    for (var i = 0; i < rows; i++) {
      wheel.jog(1);
      await tester.pump();
    }
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
  }

  test('the tree names a page, and the page is registered', () {
    PlayerSettingScreens.install();
    expect(zone.node.kind, SettingKind.screen);
    expect(zone.node.screen, 'time-zone');
    expect(SettingScreens.knows('time-zone'), isTrue);
    // A page can hold a value: this one is device state with a default and
    // a place in the first-run flow, which SettingNode.page had no way to
    // say before.
    expect(zone.node.store, SettingStore.device);
    expect(zone.node.defaultValue, 'UTC');
    expect(zone.node.oobe, 'welcome/20');
  });

  testWidgets('the areas come first, with UTC at the head of them', (
    tester,
  ) async {
    await pump(tester);
    if (TimeZones.areas.isEmpty) {
      // A rootfs with no tzdata says so rather than showing an empty list.
      expect(find.textContaining('no zone table'), findsOneWidget);
      return;
    }
    expect(find.text('UTC'), findsOneWidget);
    expect(
      find.text('Coordinated Universal Time; no daylight saving adjustment'),
      findsOneWidget,
    );
    expect(find.text(TimeZones.areas.first), findsOneWidget);
    // The places themselves are a level down, not on this page.
    expect(find.text('London'), findsNothing);
  });

  testWidgets('choosing a place writes the zone and moves where Auto '
      'thinks it is', (tester) async {
    final london = TimeZones.at('Europe/London');
    if (london == null) {
      markTestSkipped('this machine has no Europe/London in its zone table');
      return;
    }
    await pump(tester);
    expect(Appearance.place.value, isNull);

    // Into Europe: past UTC and the areas before it.
    await choose(tester, 1 + TimeZones.areas.indexOf('Europe'));
    expect(find.text('London'), findsOneWidget);

    // And onto London, from the top of that area's list.
    final europe = TimeZones.inArea('Europe');
    await choose(tester, europe.indexWhere((z) => z.id == 'Europe/London'));

    expect(settings.value(path), 'Europe/London');
    expect(ClockZone.selected.value, 'Europe/London');
    final place = Appearance.place.value;
    expect(place, isNotNull, reason: 'the zone should have moved the place');
    expect(place!.latitude, closeTo(51.5, 0.5));
    expect(place.longitude, closeTo(-0.13, 0.5));

    // Back past both lists to whatever sent us: the picker is done.
    expect(find.text('London'), findsNothing);
    expect(find.text('Europe'), findsNothing);
  });

  testWidgets('opening a saved zone reveals it before the wheel moves', (
    tester,
  ) async {
    final selected = TimeZones.at('America/New_York');
    if (selected == null) {
      markTestSkipped('this machine has no America/New_York in its zone table');
      return;
    }
    await tester.binding.setSurfaceSize(const Size(320, 240));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    settings.set(path, selected.id);
    await pump(tester);
    // The area is selected already; opening it must reveal its saved zone.
    await choose(tester, 0);
    final label = find.text(selected.location);
    expect(label, findsOneWidget);
    final viewport = tester.getRect(find.byType(Scrollable));
    final row = tester.getRect(label);
    expect(row.top, greaterThanOrEqualTo(viewport.top));
    expect(row.bottom, lessThanOrEqualTo(viewport.bottom));
    expect(
      tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels,
      greaterThan(0),
    );
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    expect(settings.value(path), selected.id);
  });

  testWidgets('UTC is a clock rather than a place, so Auto has nothing to '
      'follow', (tester) async {
    if (TimeZones.at('Europe/London') == null) {
      markTestSkipped('this machine has no Europe/London in its zone table');
      return;
    }
    settings.set(path, 'Europe/London');
    expect(Appearance.place.value, isNotNull);

    await pump(tester);
    // UTC leads the list, and the list opens on the chosen area - so walk
    // back up to it rather than down.
    final up = TimeZones.areas.indexOf('Europe') + 1;
    for (var i = 0; i < up; i++) {
      wheel.jog(-1);
      await tester.pump();
    }
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();

    expect(settings.value(path), 'UTC');
    expect(Appearance.place.value, isNull);
  });

  group('what Auto resolves to', () {
    testWidgets('with no place, it falls back to what the machine wears', (
      tester,
    ) async {
      ClockZone.selected.value = 'UTC';
      SettingBindings.clear();
      Appearance.place.value = null;
      Appearance.mode.value = AppearanceMode.auto;

      Appearance.systemBrightness.value = Brightness.light;
      expect(Appearance.brightness.value, Brightness.light);
      Appearance.systemBrightness.value = Brightness.dark;
      expect(Appearance.brightness.value, Brightness.dark);
    });

    testWidgets('with a place, the sun is asked instead of the machine', (
      tester,
    ) async {
      Appearance.mode.value = AppearanceMode.auto;
      // The machine says light; the sun should be asked regardless.
      Appearance.systemBrightness.value = Brightness.light;

      const svalbard = SolarPlace(latitude: 78.2232, longitude: 15.6267);
      Appearance.place.value = svalbard;
      final wanted = Solar.isDaylight(svalbard, DateTime.now())
          ? Brightness.light
          : Brightness.dark;
      expect(Appearance.brightness.value, wanted);
    });

    testWidgets('light and dark ignore both', (tester) async {
      ClockZone.selected.value = 'UTC';
      SettingBindings.clear();
      Appearance.place.value = null;
      Appearance.systemBrightness.value = Brightness.dark;
      Appearance.mode.value = AppearanceMode.light;
      expect(Appearance.brightness.value, Brightness.light);
      Appearance.mode.value = AppearanceMode.dark;
      expect(Appearance.brightness.value, Brightness.dark);
    });

    testWidgets('only Auto has a next change to report', (tester) async {
      Appearance.place.value = const SolarPlace(
        latitude: 51.5074,
        longitude: -0.1278,
      );
      Appearance.mode.value = AppearanceMode.dark;
      expect(Appearance.nextChange, isNull);
      Appearance.mode.value = AppearanceMode.auto;
      expect(Appearance.nextChange, isNotNull);
      expect(Appearance.nextChange!.isAfter(DateTime.now()), isTrue);
    });
  });
}
