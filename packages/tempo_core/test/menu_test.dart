import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

/// The menu is data, and data can be wrong in ways a compiler doesn't see:
/// two entries at one path, a leaf naming a screen nobody registered. And
/// the walk itself - home, into the menu, down through the library to a
/// song list that isn't there yet - is the whole point of the tree, so it
/// is walked.
void main() {
  group('the system menu tree', () {
    test('has the top level the plan asks for, in order', () {
      expect(systemMenu.rootEntry.children.map((entry) => entry.label), [
        'Home',
        'Apps',
        'Library',
        'Settings',
      ]);
      // About is in the settings tree, not this one.
      expect(systemMenu.at('/settings/general/about'), isNull);
      expect(systemMenu.at('/about'), isNull);
    });

    test('gives every entry a unique path, and siblings unique ids', () {
      final paths = <String>{};
      for (final entry in systemMenu.entries) {
        expect(paths.add(entry.path), isTrue, reason: 'twice: ${entry.path}');
        final ids = entry.node.children.map((child) => child.id).toList();
        expect(ids.toSet().length, ids.length, reason: 'under ${entry.path}');
      }
      // Paths are made of ids, and ids are wheel-safe: lower case, no
      // spaces, nothing that needs escaping in a file or a URL.
      for (final entry in systemMenu.entries.skip(1)) {
        expect(entry.id, matches(RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$')));
        expect(entry.path, startsWith('/'));
        expect(entry.path.endsWith('/${entry.id}'), isTrue);
      }
    });

    test('every leaf resolves to a screen', () {
      expect(systemMenu.leaves, isNotEmpty);
      for (final leaf in systemMenu.leaves) {
        final screen = leaf.node.screen;
        expect(
          screen == null || MenuScreens.knows(screen),
          isTrue,
          reason: '${leaf.path} names an unknown screen: $screen',
        );
        if (screen != MenuScreens.home) {
          expect(MenuScreens.routeFor(leaf), isA<Route<void>>());
        }
      }
      // And the ones with real screens are where the plan puts them.
      expect(systemMenu.at('/home')!.node.screen, MenuScreens.home);
      expect(systemMenu.at('/apps/files')!.node.screen, MenuScreens.files);
      expect(systemMenu.at('/apps/fm-radio')!.node.screen, MenuScreens.fmRadio);
      expect(systemMenu.at('/debug'), isNull);
      // Settings is a leaf here and a tree of its own behind it: the
      // items under it are switches and sliders, not menu rows.
      expect(systemMenu.at('/settings')!.node.screen, MenuScreens.settings);
      expect(systemMenu.at('/settings')!.isLeaf, isTrue);
    });

    test('is deep where the plan is deep', () {
      expect(systemMenu.at('/library/music/songs'), isNotNull);
      expect(systemMenu.at('/library/podcasts'), isNotNull);
      expect(systemMenu.at('/library/audio'), isNull);
      expect(systemMenu.at('/library/video'), isNull);
      expect(systemMenu.at('/library')!.children.map((entry) => entry.label), [
        'Music',
        'Podcasts',
        'Recordings',
        'Audiobooks',
        'Movies',
        'Shows',
      ]);
      expect(systemMenu.at('/apps/files'), isNotNull);
      // The depth that used to live under /settings is the settings
      // tree's now - see settings_test.dart.
      expect(systemMenu.at('/settings/system/reset/device'), isNull);
    });

    test('round-trips through JSON unchanged', () {
      final json = systemMenuRoot.toJson();
      expect(MenuNode.fromJson(json), systemMenuRoot);
      // The shape a later source will hand back: plain values only.
      expect(json['children'], isA<List<Object?>>());
      expect(json.keys, containsAll(['id', 'label', 'children']));
    });
  });

  group('walking the menu', () {
    tearDown(() {
      MenuDock.reset();
      MenuDock.selected.value = null;
    });

    Future<ClickWheelController> pumpApp(WidgetTester tester) async {
      final wheel = ClickWheelController();
      await tester.pumpWidget(TempoApp(wheel: wheel));
      await tester.pumpAndSettle();
      return wheel;
    }

    /// [index] rows below the current selection, then in.
    Future<void> jogTo(
      WidgetTester tester,
      ClickWheelController wheel,
      int index,
    ) async {
      if (index != 0) wheel.jog(index);
      await tester.pumpAndSettle();
      wheel.press(WheelButton.select);
      await tester.pumpAndSettle();
    }

    /// The dock, from home: up with the center button, along to [index],
    /// and in.
    Future<void> dockTo(
      WidgetTester tester,
      ClickWheelController wheel,
      int index,
    ) async {
      wheel.press(WheelButton.select);
      await tester.pumpAndSettle();
      expect(MenuDock.shown.value, isTrue);
      if (index != 0) wheel.jog(index * MenuDock.physics.weight);
      await tester.pumpAndSettle();
      wheel.press(WheelButton.select);
      await tester.pumpAndSettle();
      expect(MenuDock.shown.value, isFalse);
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

    testWidgets('home > dock > Library > Music > Playlists lands on the '
        'placeholder, and menu backs out one level at a time', (tester) async {
      final wheel = await pumpApp(tester);
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(MenuListScreen), findsNothing);

      // Home, Apps, Library: two along the dock.
      await dockTo(tester, wheel, 2);
      expect(find.text('Music'), findsOneWidget);
      expect(find.text('Podcasts'), findsOneWidget);

      await jogTo(tester, wheel, 0);
      expect(find.text('Playlists'), findsOneWidget);
      expect(find.text('Songs'), findsOneWidget);

      await jogTo(tester, wheel, 0);
      expect(find.byType(PlaceholderScreen), findsOneWidget);
      expect(find.text('Playlists'), findsOneWidget);
      expect(find.text('/library/music/playlists'), findsOneWidget);
      expect(find.text('nothing here yet - menu goes back'), findsOneWidget);

      // One press of menu, one level.
      wheel.press(WheelButton.menu);
      await tester.pumpAndSettle();
      expect(find.byType(PlaceholderScreen), findsNothing);
      expect(find.text('Songs'), findsOneWidget);

      wheel.press(WheelButton.menu);
      await tester.pumpAndSettle();
      expect(find.text('Music'), findsOneWidget);
      expect(find.text('Playlists'), findsNothing);
    });

    testWidgets('the dock\'s Home goes back to the home screen', (
      tester,
    ) async {
      final wheel = await pumpApp(tester);

      await dockTo(tester, wheel, 1);
      expect(find.text('Files'), findsOneWidget);
      // The dock over Apps - opening on Apps - and back along it to Home.
      await doublePower(tester, wheel);
      expect(MenuDock.shown.value, isTrue);
      wheel.jog(-MenuDock.physics.weight);
      await tester.pumpAndSettle();
      wheel.press(WheelButton.select);
      await tester.pumpAndSettle();

      expect(MenuDock.shown.value, isFalse);
      expect(find.byType(MenuListScreen), findsNothing);
      expect(find.byType(HomeScreen), findsOneWidget);
    });

    testWidgets('a real screen opens where the tree names one', (tester) async {
      final wheel = await pumpApp(tester);

      // Apps > Files.
      await dockTo(tester, wheel, 1);
      await jogTo(tester, wheel, 0);
      expect(find.byType(FilesScreen), findsOneWidget);
    });

    testWidgets('rapid activation opens only one app stage', (tester) async {
      final wheel = await pumpApp(tester);

      await dockTo(tester, wheel, 1);
      // Two presses before the stage changes must not create a second copy.
      wheel.jog(2);
      await tester.pumpAndSettle();
      wheel.press(WheelButton.select);
      wheel.press(WheelButton.select);
      await tester.pumpAndSettle();
      expect(find.byType(PlaceholderScreen), findsOneWidget);

      expect(
        MenuDock.current.value.where((entry) => entry.path == '/apps/store'),
        hasLength(1),
      );
      wheel.press(WheelButton.menu);
      await tester.pumpAndSettle();
      expect(MenuDock.shown.value, isTrue);
      expect(MenuDock.selected.value?.path, '/apps/store');
      MenuDock.select(systemMenu.at('/apps')!);
      await tester.pumpAndSettle();
      expect(find.byType(PlaceholderScreen), findsNothing);
      expect(find.text('Store'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('an app pinned in the dock is the dock\'s, not a copy', (
      tester,
    ) async {
      final wheel = await pumpApp(tester);
      await dockTo(tester, wheel, 1);
      wheel.press(WheelButton.select);
      await tester.pumpAndSettle();
      // Files is on stage - the dock's Files, with its own stack, so that
      // menu at its root is the switcher and not Apps.
      expect(find.byType(FilesScreen), findsOneWidget);
      expect(MenuDock.selected.value?.path, '/apps/files');
      wheel.press(WheelButton.menu);
      await tester.pumpAndSettle();
      expect(MenuDock.shown.value, isTrue);
    });

    testWidgets('a leaf with a registered screen opens it', (tester) async {
      MenuScreens.register(
        'test-screen',
        (entry) => PlaceholderScreen(title: 'Registered ${entry.label}'),
      );
      final tree = MenuTree(
        const MenuNode(
          id: 'root',
          label: 'Root',
          children: [
            MenuNode(id: 'plugged', label: 'Plugged', screen: 'test-screen'),
          ],
        ),
      );
      final wheel = ClickWheelController();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        TomeApp(
          debugShowCheckedModeBanner: false,
          navigatorKey: navigator,
          builder: (context, child) =>
              ClickWheelInput(controller: wheel, child: child!),
          home: const SizedBox.shrink(),
        ),
      );
      unawaited(
        navigator.currentState!.push(MenuListScreen.route(tree.rootEntry)),
      );
      await tester.pumpAndSettle();

      wheel.press(WheelButton.select);
      await tester.pumpAndSettle();
      // The name goes to the bar, which this bare app has none of; the
      // screen is there, and named.
      expect(find.byType(PlaceholderScreen), findsOneWidget);
      expect(
        tester.widget<PlaceholderScreen>(find.byType(PlaceholderScreen)).title,
        'Registered Plugged',
      );
    });
  });
}
