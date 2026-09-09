import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

/// The dock is the top of the menu as a row of icons, and the switcher
/// between the apps behind them: what is on it is data, double-tapping power
/// brings it up and puts it away, back at the root of any app brings it up
/// on that app, the apps stay exactly where they were left as you switch
/// between them, and the bar over all of it moves nothing but its ground.
void main() {
  tearDown(() {
    MenuDock.reset();
    MenuDock.selected.value = null;
    MenuDock.pins.value = const ['/apps/files'];
    DebugSettings.enabled.value = true;
    Glass.enabled.value = true;
    MenuOptions.view.value = MenuLayout.list;
    WheelSettings.feel.value = WheelFeel.standard;
  });

  Future<ClickWheelController> pumpApp(
    WidgetTester tester, {
    Settings? settings,
  }) async {
    final wheel = ClickWheelController();
    await tester.pumpWidget(TempoApp(wheel: wheel, settings: settings));
    await tester.pumpAndSettle();
    return wheel;
  }

  Future<void> doublePower(
    WidgetTester tester,
    ClickWheelController wheel,
  ) async {
    wheel.powerDown();
    wheel.powerUp();
    await tester.pump(const Duration(milliseconds: 100));
    wheel.powerDown();
    wheel.powerUp();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  Future<void> press(
    WidgetTester tester,
    ClickWheelController wheel,
    WheelButton button,
  ) async {
    wheel.press(button);
    await tester.pumpAndSettle();
  }

  Future<void> jog(
    WidgetTester tester,
    ClickWheelController wheel,
    int detents,
  ) async {
    wheel.jog(detents);
    await tester.pumpAndSettle();
  }

  /// From wherever the dock opens, [steps] items along, and in.
  Future<void> choose(
    WidgetTester tester,
    ClickWheelController wheel,
    int steps,
  ) async {
    if (steps != 0) await jog(tester, wheel, steps * MenuDock.physics.weight);
    await press(tester, wheel, WheelButton.select);
  }

  Finder rail() => find.byType(WheelRail<MenuLocation>);

  String under(WidgetTester tester) =>
      tester.widget<WheelRail<MenuLocation>>(rail()).value!.label;

  String barTitle(WidgetTester tester) => tester
      .widget<LabelText>(
        find.descendant(
          of: find.byType(StatusBar),
          matching: find.byType(LabelText),
        ),
      )
      .data;

  group('what is on the dock', () {
    List<String> labels() => [
      for (final entry in MenuDock.entries(systemMenu)) entry.label,
    ];

    test('the four that are always there and the pins', () {
      expect(labels(), ['Home', 'Apps', 'Library', 'Settings', 'Files']);
      expect(labels(), isNot(contains('Debug')));
    });

    test('Files is pinned by default, and Store is not', () {
      expect(MenuDock.pins.value, ['/apps/files']);
      expect(labels(), isNot(contains('Store')));
    });

    test('pins are the user\'s: any app, in any order, or none', () {
      MenuDock.pins.value = const ['/apps/store', '/apps/files'];
      expect(labels(), [
        'Home',
        'Apps',
        'Library',
        'Settings',
        'Store',
        'Files',
      ]);
      MenuDock.pins.value = const [];
      expect(labels(), ['Home', 'Apps', 'Library', 'Settings']);
      // A pin that names nothing is simply not there.
      MenuDock.pins.value = const ['/apps/nothing-of-the-sort'];
      expect(labels(), ['Home', 'Apps', 'Library', 'Settings']);
    });

    test('every built-in item has a glyph', () {
      for (final entry in systemMenu.rootEntry.children) {
        expect(entry.node.hint, isNotNull, reason: entry.path);
      }
      for (final entry in systemMenu.at('/apps')!.children) {
        expect(entry.node.hint, isNotNull, reason: entry.path);
      }
      expect(MenuIcons.of('house'), LucideIcons.house);
      expect(MenuIcons.of('shopping-bag'), LucideIcons.shoppingBag);
      expect(
        MenuIcons.of(null),
        LucideIcons.circleDashed,
        reason: 'a stand-in',
      );
    });
  });

  testWidgets(
    'double-tapping power brings the dock up and puts it away; so does '
    'a press',
    (tester) async {
      final wheel = await pumpApp(tester);
      expect(rail(), findsNothing);
      expect(find.byType(HomeScreen), findsOneWidget);

      await doublePower(tester, wheel);
      expect(rail(), findsOneWidget);
      expect(under(tester), 'Home');
      // In the rail itself: the Apps page shown small beside it carries a
      // Files glyph of its own.
      expect(
        find.descendant(of: rail(), matching: find.byIcon(LucideIcons.folder)),
        findsOneWidget,
        reason: 'Files',
      );
      expect(
        find.descendant(of: rail(), matching: find.byIcon(LucideIcons.bug)),
        findsNothing,
        reason: 'Developer tools belong in Settings',
      );

      await doublePower(tester, wheel);
      expect(rail(), findsNothing);

      await doublePower(tester, wheel);
      await press(tester, wheel, WheelButton.menu);
      expect(rail(), findsNothing);
      expect(find.byType(HomeScreen), findsOneWidget);
    },
  );

  testWidgets('the switcher opens on the app on stage', (tester) async {
    final wheel = await pumpApp(tester);
    await press(tester, wheel, WheelButton.select);
    await choose(tester, wheel, 3);
    expect(barTitle(tester), 'Settings');

    await doublePower(tester, wheel);
    expect(under(tester), 'Settings');
    expect(MenuDock.position.value, 3);
  });

  testWidgets('back at the root of an app is the switcher; deeper, it is '
      'back', (tester) async {
    final wheel = await pumpApp(tester);
    await press(tester, wheel, WheelButton.select);
    await choose(tester, wheel, 1);
    expect(find.text('Files'), findsOneWidget, reason: 'Apps, at its root');

    // Store gets its own stage, so Back at its root opens the switcher.
    wheel.jog(2);
    await tester.pumpAndSettle();
    await press(tester, wheel, WheelButton.select);
    expect(find.byType(PlaceholderScreen), findsOneWidget);
    await press(tester, wheel, WheelButton.menu);
    expect(rail(), findsOneWidget);
    expect(under(tester), 'Store');

    // Settings still pops deeper routes before opening the switcher.
    MenuDock.select(systemMenu.at('/settings')!);
    await tester.pumpAndSettle();
    await jog(tester, wheel, 3);
    await press(tester, wheel, WheelButton.select);
    expect(barTitle(tester), 'Appearance');
    await press(tester, wheel, WheelButton.menu);
    expect(barTitle(tester), 'Settings');
    expect(rail(), findsNothing);
    await press(tester, wheel, WheelButton.menu);
    expect(rail(), findsOneWidget);
    expect(under(tester), 'Settings');
  });

  testWidgets('switching apps never loses anyone\'s place', (tester) async {
    final wheel = await pumpApp(tester);

    // Settings > Appearance, then away to Files.
    await press(tester, wheel, WheelButton.select);
    await choose(tester, wheel, 3);
    await jog(tester, wheel, 3);
    await press(tester, wheel, WheelButton.select);
    expect(barTitle(tester), 'Appearance');
    expect(find.text('Theme'), findsOneWidget);

    await doublePower(tester, wheel);
    await choose(tester, wheel, 1);
    expect(find.byType(FilesScreen), findsOneWidget);
    expect(barTitle(tester), 'Files');
    expect(find.text('Theme'), findsNothing);

    // Into a folder and out again: the bar keeps the app's name; where
    // you are is the trail's to say.
    await press(tester, wheel, WheelButton.select);
    expect(barTitle(tester), 'Files');
    await press(tester, wheel, WheelButton.menu);
    expect(barTitle(tester), 'Files');

    // Home for a moment, then back to Settings: still on Appearance.
    await doublePower(tester, wheel);
    await choose(tester, wheel, -4);
    expect(find.byType(HomeScreen), findsOneWidget);
    await doublePower(tester, wheel);
    await choose(tester, wheel, 3);
    expect(barTitle(tester), 'Appearance');
    expect(find.text('Theme'), findsOneWidget);
    // And it is the very same screen, not one built again.
    await press(tester, wheel, WheelButton.menu);
    expect(barTitle(tester), 'Settings');
  });

  testWidgets('developer mode never adds a dock screen', (tester) async {
    final wheel = await pumpApp(tester);
    await doublePower(tester, wheel);
    expect(find.byIcon(LucideIcons.bug), findsNothing);
    DebugSettings.enabled.value = false;
    await tester.pumpAndSettle();
    expect(find.byIcon(LucideIcons.bug), findsNothing);
  });

  testWidgets('left and right step the box too', (tester) async {
    final wheel = await pumpApp(tester);
    await doublePower(tester, wheel);
    await press(tester, wheel, WheelButton.next);
    expect(under(tester), 'Apps');
    await press(tester, wheel, WheelButton.next);
    expect(under(tester), 'Library');
    await press(tester, wheel, WheelButton.previous);
    expect(under(tester), 'Apps');
  });

  testWidgets('the stage shows the apps themselves as covers, live', (
    tester,
  ) async {
    final wheel = await pumpApp(tester);
    await doublePower(tester, wheel);
    // Home in the middle, Apps beside it - its own list, not a copy -
    // and Settings out of reach.
    expect(MenuDock.preview.value?.label, 'Home');
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.text('Files'), findsOneWidget, reason: 'Apps, as a cover');
    expect(find.text('Appearance'), findsNothing);

    await jog(tester, wheel, 3 * MenuDock.physics.weight);
    expect(MenuDock.preview.value?.label, 'Settings');
    expect(find.text('Appearance'), findsOneWidget, reason: 'Settings, middle');
    expect(find.text('Music'), findsOneWidget, reason: 'Library, beside');
    expect(find.byType(HomeScreen), findsNothing, reason: 'out of reach');
    // The neighbors wear their names as pills; the middle one's name is
    // in the bar's slot, and the bar's own title stands aside for it.
    expect(
      find.text('Library'),
      findsNWidgets(2),
      reason: "Library's pill, and Settings' own Library row beside it",
    );
    expect(find.text('Files'), findsOneWidget, reason: "Files' pill");
    expect(find.text('Settings'), findsNWidgets(2), reason: 'pill and title');
    final titles = find.text('Settings');
    expect(
      tester.getTopLeft(titles.first).dx,
      closeTo(tester.getTopLeft(titles.last).dx, 0.01),
      reason: 'The switcher title shares the status-bar left inset',
    );

    // Put away without choosing: home is back, and the covers are gone.
    await doublePower(tester, wheel);
    expect(MenuDock.position.value, isNull);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.text('Appearance'), findsNothing);
  });

  testWidgets('a neighbor that has slid off the panel keeps its name on it', (
    tester,
  ) async {
    final wheel = await pumpApp(tester);
    await press(tester, wheel, WheelButton.select);
    await choose(tester, wheel, 3);
    await doublePower(tester, wheel);
    expect(under(tester), 'Settings');

    // Library before, Files after: both covers reach off the panel, and
    // both names stay on it, at the covers' inner edges.
    //
    // By the pill's own face, not by the words: Settings' page has a
    // Library row of its own on the cover behind it, and a bare text
    // finder would land on whichever it liked.
    Rect pill(String name) => tester.getRect(
      find.byWidgetPredicate(
        (widget) => widget is LabelText && widget.data == name,
      ),
    );
    final panel = tester.getRect(find.byKey(DockStage.stageKey));
    final library = pill('Library');
    final files = pill('Files');
    expect(library.left, greaterThanOrEqualTo(panel.left));
    expect(library.right, lessThan(panel.center.dx));
    expect(files.right, lessThanOrEqualTo(panel.right));
    expect(files.left, greaterThan(panel.center.dx));
  });

  for (final view in MenuLayout.values) {
    testWidgets('Apps $view context menu pins the highlighted app', (
      tester,
    ) async {
      MenuOptions.view.value = view;
      final settings = Settings(tree: playerSettingsTree);
      final wheel = await pumpApp(tester, settings: settings);
      MenuDock.select(systemMenu.at('/apps')!);
      await tester.pumpAndSettle();
      if (view == MenuLayout.list) {
        final row = tester.widget<MenuRow>(find.byType(MenuRow).first);
        expect(
          find.descendant(
            of: find.byWidget(row),
            matching: find.byIcon(MenuIcons.of(row.entry.node.hint)),
          ),
          findsOneWidget,
        );
      }
      await jog(tester, wheel, 2); // Store
      await press(tester, wheel, WheelButton.menu);
      expect(find.text('Pin to dock'), findsOneWidget);
      expect(MenuDock.shown.value, isFalse);
      await jog(tester, wheel, 1);
      await press(tester, wheel, WheelButton.select);
      expect(MenuDock.pins.value, contains('/apps/store'));
      expect(settings.value(MenuDock.pinsPath), contains('/apps/store'));
      expect(MenuDock.selected.value?.path, '/apps');
      await press(tester, wheel, WheelButton.menu);
      expect(find.text('Unpin from dock'), findsOneWidget);
      await jog(tester, wheel, 1);
      await press(tester, wheel, WheelButton.select);
      expect(MenuDock.pins.value, isNot(contains('/apps/store')));
      await press(tester, wheel, WheelButton.menu);
      await press(tester, wheel, WheelButton.select); // Open Store.
      expect(MenuDock.selected.value?.path, '/apps/store');
      await tester.pumpWidget(const SizedBox.shrink());
      settings.dispose();
    });
  }

  testWidgets(
    'hold Select moves built-in and pinned dock items and saves the order',
    (tester) async {
      final settings = Settings(tree: playerSettingsTree);
      final wheel = await pumpApp(tester, settings: settings);
      await doublePower(tester, wheel);
      wheel.hold(WheelButton.select);
      await tester.pumpAndSettle();
      expect(find.text('Turn to move · Select to place'), findsOneWidget);
      await jog(tester, wheel, 4); // Move Home past every entry.
      expect(MenuDock.current.value.last.path, '/home');
      expect(under(tester), 'Home');
      expect(MenuDock.preview.value?.path, '/home');
      expect(settings.value(MenuDock.orderPath), [
        '/apps',
        '/library',
        '/settings',
        '/apps/files',
        '/home',
      ]);
      await press(tester, wheel, WheelButton.select);
      expect(MenuDock.shown.value, isTrue);
      expect(find.text('Turn to move · Select to place'), findsNothing);
      await jog(tester, wheel, -1); // Files
      wheel.hold(WheelButton.select);
      await tester.pumpAndSettle();
      await jog(tester, wheel, -3);
      expect(MenuDock.current.value.first.path, '/apps/files');
      expect(under(tester), 'Files');
      await press(tester, wheel, WheelButton.menu);
      expect(MenuDock.shown.value, isTrue);
      await press(tester, wheel, WheelButton.select);
      expect(MenuDock.selected.value?.path, '/apps/files');
      expect(MenuDock.shown.value, isFalse);
      final saved = settings.stored;
      await tester.pumpWidget(const SizedBox.shrink());
      MenuDock.reset();
      final restored = Settings(tree: playerSettingsTree, values: saved);
      final bridge = PlayerSettings.install(
        restored,
        services: PlayerServices.fallback,
      );
      bridge.applyAll();
      expect(MenuDock.entries(systemMenu).first.path, '/apps/files');
      expect(MenuDock.entries(systemMenu).last.path, '/home');
      bridge.detach();
      restored.dispose();
      settings.dispose();
    },
  );

  testWidgets(
    'dock Menu hold owns focus, unpins, and closes the highlighted app',
    (tester) async {
      final settings = Settings(tree: playerSettingsTree);
      final wheel = await pumpApp(tester, settings: settings);
      MenuDock.select(systemMenu.at('/apps/files')!);
      await tester.pumpAndSettle();
      await doublePower(tester, wheel);
      wheel.hold(WheelButton.menu);
      await tester.pumpAndSettle();
      expect(find.text('Unpin from dock'), findsOneWidget);
      expect(find.text('Close app'), findsOneWidget);
      expect(MenuDock.shown.value, isTrue);
      await jog(tester, wheel, 1);
      expect(MenuDock.preview.value?.path, '/apps/files');
      await press(tester, wheel, WheelButton.select);
      expect(MenuDock.pins.value, isNot(contains('/apps/files')));
      expect(settings.value(MenuDock.pinsPath), isEmpty);
      expect(
        MenuDock.current.value.map((entry) => entry.path),
        contains('/apps/files'),
      );
      expect(under(tester), 'Files');
      wheel.hold(WheelButton.menu);
      await tester.pumpAndSettle();
      expect(find.text('Pin to dock'), findsOneWidget);
      await jog(tester, wheel, 3);
      await press(tester, wheel, WheelButton.select);
      expect(
        MenuDock.current.value.map((entry) => entry.path),
        isNot(contains('/apps/files')),
      );
      expect(MenuDock.selected.value?.path, '/home');
      expect(MenuDock.shown.value, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      settings.dispose();
    },
  );

  testWidgets(
    'built-in dock menus allow rearranging and Menu dismisses only the menu',
    (tester) async {
      final wheel = await pumpApp(tester);
      await doublePower(tester, wheel);
      wheel.hold(WheelButton.menu);
      await tester.pumpAndSettle();
      expect(find.text('Rearrange'), findsOneWidget);
      expect(find.text('Close app'), findsNothing);
      expect(find.text('Unpin from dock'), findsNothing);
      await press(tester, wheel, WheelButton.menu);
      expect(find.text('Rearrange'), findsNothing);
      expect(MenuDock.shown.value, isTrue);
      wheel.hold(WheelButton.menu);
      await tester.pumpAndSettle();
      await jog(tester, wheel, 1);
      await press(tester, wheel, WheelButton.select);
      expect(find.text('Turn to move · Select to place'), findsOneWidget);
      await jog(tester, wheel, 1);
      expect(MenuDock.current.value[1].path, '/home');
    },
  );

  testWidgets('closing a pinned app discards its navigator but keeps the pin', (
    tester,
  ) async {
    final wheel = await pumpApp(tester);
    MenuDock.select(systemMenu.at('/apps/files')!);
    await tester.pumpAndSettle();
    final before = Applet.maybeOf(tester.element(find.byType(FilesScreen)))!;
    await doublePower(tester, wheel);
    wheel.hold(WheelButton.menu);
    await tester.pumpAndSettle();
    await jog(tester, wheel, 3);
    await press(tester, wheel, WheelButton.select);
    expect(MenuDock.pins.value, contains('/apps/files'));
    expect(MenuDock.selected.value?.path, '/home');
    expect(under(tester), 'Files');
    await press(tester, wheel, WheelButton.select);
    final after = Applet.maybeOf(tester.element(find.byType(FilesScreen)))!;
    expect(after, isNot(same(before)));
    expect(after.navigator.currentState!.canPop(), isFalse);
  });

  testWidgets('closing the dock also dismisses its context menu', (
    tester,
  ) async {
    final wheel = await pumpApp(tester);
    await doublePower(tester, wheel);
    wheel.hold(WheelButton.menu);
    await tester.pumpAndSettle();
    await doublePower(tester, wheel);
    expect(MenuDock.shown.value, isFalse);
    expect(find.text('Rearrange'), findsNothing);
    await doublePower(tester, wheel);
    await jog(tester, wheel, 1);
    expect(under(tester), 'Apps');
  });

  testWidgets('wheel firmness applies once to dock clicks and updates live', (
    tester,
  ) async {
    final wheel = await pumpApp(tester);
    final settings = Settings(tree: playerSettingsTree);
    SettingBindings.registerAll(PlayerSettings.sinks(PlayerServices.fallback));
    final bridge = SettingsBridge(settings: settings)..attach();
    addTearDown(() {
      bridge.detach();
      settings.dispose();
      SettingBindings.clear();
    });
    await press(tester, wheel, WheelButton.select);
    await jog(tester, wheel, 1);
    expect(under(tester), 'Apps');
    settings.set('/settings/controls/wheel/sensitivity', 'standard');
    await tester.pump();
    await jog(tester, wheel, 1);
    expect(under(tester), 'Apps');
    await jog(tester, wheel, 1);
    expect(under(tester), 'Library');
    settings.set('/settings/controls/wheel/sensitivity', 'firm');
    await tester.pump();
    await jog(tester, wheel, -2);
    expect(under(tester), 'Library');
    await jog(tester, wheel, -1);
    expect(under(tester), 'Apps');
    settings.set('/settings/controls/wheel/sensitivity', 'light');
    await tester.pump();
    await jog(tester, wheel, -1);
    expect(under(tester), 'Home');
  });

  testWidgets(
    'page bodies ease behind dock clicks and retarget without jumping',
    (tester) async {
      final wheel = await pumpApp(tester);
      await press(tester, wheel, WheelButton.select);
      double shift() => tester
          .widgetList<Transform>(
            find.ancestor(
              of: find.text('Files'),
              matching: find.byType(Transform),
            ),
          )
          .firstWhere((w) => w.transform.entry(3, 2) != 0)
          .transform
          .entry(0, 3);
      final before = shift();
      wheel.jog(1);
      await tester.pump();
      expect(MenuDock.position.value, 1);
      expect(shift(), closeTo(before, 0.01));
      await tester.pump(const Duration(milliseconds: 60));
      final midway = shift();
      expect(midway, greaterThan(0));
      expect(midway, lessThan(before));
      wheel.jog(1);
      await tester.pump();
      expect(MenuDock.position.value, 2);
      expect(shift(), closeTo(midway, 0.01));
      await tester.pump(DockStage.catchUpDuration);
      expect(shift(), lessThan(0));
      await tester.pumpAndSettle();
      expect(under(tester), 'Library');
    },
  );

  testWidgets('a choice made before the box settles closes the '
      'flow while the chosen cover finishes catching up', (tester) async {
    final wheel = await pumpApp(tester);
    await press(tester, wheel, WheelButton.select);
    // One click reaches Apps; choose before the visual motion settles.
    wheel.jog(MenuDock.physics.weight);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(under(tester), 'Apps');
    expect(MenuDock.position.value, 1.0);
    wheel.press(WheelButton.select);
    await tester.pump();
    expect(MenuDock.position.value, 1.0, reason: 'pinned on the choice');

    double shiftOfApps() {
      final transforms = tester.widgetList<Transform>(
        find.ancestor(of: find.text('Files'), matching: find.byType(Transform)),
      );
      // The cover's own transform is the one with the perspective in it.
      final cover = transforms.firstWhere((w) => w.transform.entry(3, 2) != 0);
      return cover.transform.entry(0, 3);
    }

    // The selected page continues smoothly to the center while growing.
    var previousShift = shiftOfApps().abs();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 40));
      final shift = shiftOfApps().abs();
      expect(
        shift,
        lessThanOrEqualTo(previousShift + 0.01),
        reason: 'frame $i',
      );
      previousShift = shift;
      expect(MenuDock.position.value ?? 1.0, 1.0, reason: 'frame $i');
    }
    await tester.pumpAndSettle();
    expect(barTitle(tester), 'Apps');
    expect(previousShift, closeTo(0, 1e-6));
    expect(MenuDock.position.value, isNull);
  });

  testWidgets('the bar is one set of widgets that never moves', (tester) async {
    // Something playing: a stopped player draws no leading glyph, and
    // there is no rect to hold still.
    Playback.state.value = PlaybackState.playing;
    addTearDown(() => Playback.state.value = PlaybackState.stopped);
    final wheel = await pumpApp(tester);
    final battery = find.byType(BatteryGauge);
    final before = tester.element(battery);
    final at = tester.getRect(battery);
    final glyphAt = tester.getRect(find.byType(PlayStateGlyph));

    await doublePower(tester, wheel);
    expect(identical(tester.element(battery), before), isTrue);
    expect(tester.getRect(battery), at);
    expect(tester.getRect(find.byType(PlayStateGlyph)), glyphAt);

    await choose(tester, wheel, 1);
    expect(identical(tester.element(battery), before), isTrue);
    expect(tester.getRect(battery), at);
    expect(barTitle(tester), 'Apps');
  });

  testWidgets('the bar paints a ground over a page and none over home', (
    tester,
  ) async {
    final wheel = await pumpApp(tester);
    Color ground() {
      final box = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byType(StatusBar),
          matching: find.byType(DecoratedBox),
        ),
      );
      return (box.decoration as BoxDecoration).color!;
    }

    expect(ground().a, 0, reason: 'home: the readings on the wallpaper');
    await press(tester, wheel, WheelButton.select);
    await choose(tester, wheel, 1);
    // A page's bar is glass, the same wash the dock is: the bar is
    // chrome, and Translucent Surfaces is what says whether the picture
    // is felt through the chrome.
    expect(ground().a, closeTo(Glass.tint, 0.01), reason: 'a page: glass');
    Glass.enabled.value = false;
    await tester.pump();
    expect(ground().a, 1, reason: 'glass off: the page color, solid');
    Glass.enabled.value = true;
    MenuOptions.view.value = MenuLayout.list;
    WheelSettings.feel.value = WheelFeel.standard;
    await tester.pump();

    await doublePower(tester, wheel);
    await choose(tester, wheel, -1);
    expect(ground().a, 0, reason: 'home again');
  });

  testWidgets('the page steps back to fit between the bar and the dock, '
      'and forward again', (tester) async {
    final wheel = await pumpApp(tester);
    final panel = tester.getRect(find.byKey(DockStage.stageKey));
    Rect frame() => tester.getRect(find.byKey(DockStage.stageKey));
    expect(frame().height, panel.height, reason: 'the whole panel, at rest');

    await doublePower(tester, wheel);
    final theme = ThemeProvider.of(tester.element(find.byType(StatusBar)));
    final shrunk = frame();
    expect(
      shrunk.top,
      closeTo(MenuDock.bandExtent(theme), 1e-6),
      reason: 'below the bar',
    );
    expect(
      shrunk.bottom,
      closeTo(panel.height - MenuDock.dockExtent(theme), 1e-6),
      reason: 'above the dock',
    );
    final bar = tester.getRect(find.byType(StatusBar));
    expect(bar.bottom, lessThanOrEqualTo(shrunk.top));
    final dock = tester.getRect(find.byType(Glass));
    expect(dock.top, greaterThanOrEqualTo(shrunk.bottom));

    await doublePower(tester, wheel);
    expect(frame().height, panel.height);
  });

  testWidgets('the dock slides out, and the wheel is the screen\'s again '
      'before it has gone', (tester) async {
    final wheel = await pumpApp(tester);
    await press(tester, wheel, WheelButton.select);
    await choose(tester, wheel, 1);
    await doublePower(tester, wheel);
    expect(rail(), findsOneWidget);

    // Put away, and pressed again at once: the dock is still on its way
    // out, and the press is the list's - Files opens.
    wheel.press(WheelButton.menu);
    await tester.pump();
    expect(rail(), findsOneWidget, reason: 'still sliding');
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    expect(rail(), findsNothing);
    expect(find.byType(FilesScreen), findsOneWidget);
  });

  group('backdrops', () {
    Future<void> pumpPage(WidgetTester tester, Backdrop backdrop) async {
      await tester.pumpWidget(
        TomeApp(
          debugShowCheckedModeBanner: false,
          home: PanelScreen(
            title: 'Page',
            backdrop: backdrop,
            child: const SizedBox.expand(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a page paints nothing of its own: the wallpaper is what '
        'is behind it', (tester) async {
      Color? wash() {
        final boxes = find.descendant(
          of: find.byType(Backdropped),
          matching: find.byType(ColoredBox),
        );
        if (boxes.evaluate().isEmpty) return null;
        return tester.widget<ColoredBox>(boxes.first).color;
      }

      await tester.pumpWidget(
        TomeApp(
          debugShowCheckedModeBanner: false,
          home: const PanelScreen(title: 'Page', child: SizedBox.expand()),
        ),
      );
      await tester.pumpAndSettle();
      // A page is a list of surfaces standing on the picture, not a
      // surface itself.
      expect(
        tester.widget<PanelScreen>(find.byType(PanelScreen)).backdrop,
        Backdrop.clear,
      );
      expect(wash(), isNull);
      expect(find.byType(Wallpaper), findsNothing);

      // Only a screen that is genuinely one surface asks for a ground.
      await pumpPage(tester, Backdrop.opaque);
      expect(wash()!.a, 1);

      await pumpPage(tester, Backdrop.clear);
      expect(wash(), isNull);
    });

    testWidgets('one wallpaper under everything, and the covers are cards '
        'in the flow and the panel at rest', (tester) async {
      final wheel = await pumpApp(tester);
      expect(find.byType(Wallpaper), findsOneWidget);

      // Apps on stage, at rest: square, and the picture behind it.
      await press(tester, wheel, WheelButton.select);
      await choose(tester, wheel, 1);
      expect(find.byType(Wallpaper), findsOneWidget);
      final clip = find.ancestor(
        of: find.byWidgetPredicate(
          (widget) => widget is MenuListScreen && widget.entry.path == '/apps',
        ),
        matching: find.byType(ClipRRect),
      );
      expect(
        tester.widget<ClipRRect>(clip.first).borderRadius,
        BorderRadius.zero,
      );

      // The switcher up: every cover is a rounded card, and no blur
      // anywhere - the panel's GPU has none to give.
      await doublePower(tester, wheel);
      expect(
        tester.widget<ClipRRect>(clip.first).borderRadius,
        isNot(BorderRadius.zero),
      );
      expect(find.byType(BackdropFilter), findsNothing);
    });

    test('a surface out in the flow lets more of the picture through', () {
      // The fade that used to belong to a page's own wash: the page has
      // none now, so it belongs to the surfaces standing on it.
      const palette = Palette(brightness: Brightness.dark);
      expect(
        Backdropped.surfaceOf(palette, focus: 0).a,
        lessThan(Backdropped.surfaceOf(palette).a),
      );
    });
  });
}
