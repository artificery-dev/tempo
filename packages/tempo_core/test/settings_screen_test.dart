import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

/// The settings applet: the tree, drawn as rows that carry their own
/// controls, driven by the wheel. A switch is thrown where it stands, a
/// slider takes the wheel and gives it back, a group opens a page of its
/// own, and every row that cannot do anything yet says so by being
/// disabled rather than by pretending.
void main() {
  const tree = SettingNode.group(
    id: 'settings',
    label: 'Settings',
    children: [
      SettingNode.toggle(
        id: 'gapless',
        label: 'Gapless',
        summary: 'No silence between two tracks',
        bind: 'thing.gapless',
        defaultValue: true,
      ),
      SettingNode.slider(
        id: 'brightness',
        label: 'Brightness',
        bind: 'thing.brightness',
        defaultValue: 80,
        min: 10,
        max: 100,
        step: 5,
        unit: '%',
      ),
      SettingNode.divider(id: 'div'),
      SettingNode.choice(
        id: 'theme',
        label: 'Theme',
        bind: 'thing.theme',
        defaultValue: 'dark',
        options: [
          SettingOption(value: 'light', label: 'Light'),
          SettingOption(value: 'dark', label: 'Dark'),
        ],
      ),
      SettingNode.choice(
        id: 'recheck',
        label: 'Look for Changes',
        bind: 'thing.recheck',
        defaultValue: 'startup',
        layout: SettingLayout.page,
        options: [
          SettingOption(value: 'startup', label: 'On Startup'),
          SettingOption(value: 'card', label: 'When a Card Arrives'),
          SettingOption(value: 'never', label: 'Never'),
        ],
      ),
      SettingNode.toggle(
        id: 'unbound',
        label: 'Not Wired Yet',
        bind: 'thing.nobody',
        defaultValue: false,
      ),
      SettingNode.toggle(
        id: 'radio',
        label: 'Needs a Radio',
        defaultValue: false,
        needs: {'wifi'},
      ),
      SettingNode.group(
        id: 'deeper',
        label: 'Deeper',
        children: [
          SettingNode.toggle(
            id: 'inside',
            label: 'Inside',
            bind: 'thing.inside',
            defaultValue: false,
          ),
        ],
      ),
      SettingNode.action(
        id: 'erase',
        label: 'Erase Everything',
        bind: 'thing.erase',
        danger: true,
        confirm: 'Erase it all?',
      ),
    ],
  );

  late Settings settings;
  late List<String> done;

  setUp(() {
    settings = Settings(tree: SettingsTree(tree));
    done = [];
    SettingBindings.clear();
    SettingBindings.registerAll({
      for (final key in [
        'thing.gapless',
        'thing.brightness',
        'thing.theme',
        'thing.recheck',
        'thing.inside',
      ])
        key: (_) {},
    });
    SettingBindings.registerAction('thing.erase', done.add);
  });

  tearDown(() {
    settings.dispose();
    SettingBindings.clear();
    SettingCapabilities.available.value = const {};
  });

  Future<ClickWheelController> pump(WidgetTester tester) async {
    final wheel = ClickWheelController();
    await tester.pumpWidget(
      SettingsScope(
        settings: settings,
        child: TomeApp(
          debugShowCheckedModeBanner: false,
          theme: UiScale.regular.theme(Brightness.dark),
          builder: (context, child) =>
              ClickWheelInput(controller: wheel, child: child!),
          home: UiScaleScope(
            scale: UiScale.regular,
            child: SettingsScreen(entry: settings.tree.rootEntry),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return wheel;
  }

  Future<void> press(WidgetTester tester, ClickWheelController wheel) async {
    wheel.press(WheelButton.select);
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

  testWidgets(
    'section kickers stay above cards and do not consume wheel steps',
    (tester) async {
      settings.dispose();
      settings = Settings(tree: playerSettingsTree);
      final wheel = await pump(tester);
      expect(find.text('PLAYBACK'), findsOneWidget);
      expect(tester.widget<WheelList>(find.byType(WheelList)).itemCount, 11);
      await jog(tester, wheel, 3);
      expect(find.text('INTERFACE'), findsOneWidget);
      await press(tester, wheel);
      expect(
        tester
            .widget<SettingsScreen>(find.byType(SettingsScreen).last)
            .entry
            .path,
        '/settings/appearance',
      );
      expect(tester.takeException(), isNull);
    },
  );

  group('what it draws', () {
    testWidgets('a row per item, with its control on it', (tester) async {
      await pump(tester);
      expect(find.byType(SettingSwitchTile), findsWidgets);
      expect(find.text('Gapless'), findsOneWidget);
      expect(find.text('No silence between two tracks'), findsOneWidget);
      expect(find.byType(SettingSliderTile), findsOneWidget);
      // Two short answers ride the row as a track the wheel turns; three
      // wordy ones get a page.
      expect(find.byType(WheelRail<Object?>), findsOneWidget);
      expect(find.text('On Startup'), findsOneWidget);
    });

    testWidgets('a divider ends a card rather than drawing a line: the '
        'rows between two of them are one card, and the wheel never stops '
        'on the gap', (tester) async {
      final wheel = await pump(tester);
      final cards = tester.widgetList<SettingCard>(find.byType(SettingCard));

      // Gapless and Brightness open and close the first card; Theme opens
      // the second.
      expect(cards.first.first, isTrue);
      expect(cards.first.last, isFalse, reason: 'Brightness is under it');
      expect(cards.elementAt(1).last, isTrue, reason: 'the divider is here');
      expect(cards.elementAt(2).first, isTrue, reason: 'a new card');

      // A rule under every row but the last of its card.
      expect(find.byType(SettingRule), findsWidgets);

      // And the wheel walks rows, not cards: two detents from the first
      // row is the choice, with nothing to stop on in between.
      await jog(tester, wheel, 2);
      await press(tester, wheel);
      await jog(tester, wheel, -6);
      expect(settings.value('/settings/theme'), 'light');
    });

    testWidgets('the page has no ground of its own: the cards are the '
        'ground, and the wallpaper runs between them', (tester) async {
      await pump(tester);
      final screen = tester.widget<PanelScreen>(find.byType(PanelScreen));
      expect(screen.backdrop, Backdrop.clear);

      // The card itself is the ground inside the row's box: in from the
      // panel's edges by the gap, and touching the row of its own card
      // above it.
      const scale = UiScale.regular;
      Rect groundOf(int index) => tester.getRect(
        find
            .descendant(
              of: find.byType(SettingCard).at(index),
              matching: find.byType(ClipRRect),
            )
            .first,
      );

      final panel = tester.getRect(find.byType(WheelList));
      expect(groundOf(0).left - panel.left, closeTo(scale.cardGap, 0.01));
      expect(panel.right - groundOf(0).right, closeTo(scale.cardGap, 0.01));
      expect(
        groundOf(1).top - groundOf(0).bottom,
        closeTo(0, 0.01),
        reason: 'two rows of one card touch',
      );

      // And the card after the divider stands off the one before it by
      // the same air as the edges.
      expect(
        groundOf(2).top - groundOf(1).bottom,
        closeTo(scale.cardGap, 0.01),
        reason: 'the gap between cards is the gap at the edge',
      );
    });

    testWidgets('every row of a card is the same height: three settings in '
        'one card are three equal rows', (tester) async {
      await pump(tester);

      Rect rowOf(int index) => tester.getRect(
        find
            .descendant(
              of: find.byType(SettingCard).at(index),
              matching: find.byType(ClipRRect),
            )
            .first,
      );

      // The second card runs from Theme to Erase Everything. Look for
      // Changes sits in the middle of it and Erase Everything closes it,
      // and both are a name and nothing else - so both are exactly as
      // tall as that tile, and no taller for where they sit.
      final cards = tester.widgetList<SettingCard>(find.byType(SettingCard));
      expect(cards.elementAt(2).first, isTrue);
      expect(cards.elementAt(3).first, isFalse);
      expect(cards.elementAt(3).last, isFalse);
      expect(cards.elementAt(6).last, isTrue);

      final tile = SettingTile.extentOf(UiScale.regular);
      expect(rowOf(3).height, closeTo(tile, 0.01), reason: 'a middle row');
      expect(
        rowOf(6).height,
        closeTo(tile, 0.01),
        reason: 'and the row that closes the card, to the pixel',
      );

      // The only thing a card's edge rows carry is the air outside the
      // card, which is the gap - not a taller row.
      expect(
        SettingCard.extraOf(UiScale.regular, first: false, lastOfPage: false),
        0,
      );
    });

    testWidgets('an item this player cannot offer is not there at all', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('Needs a Radio'), findsNothing);

      SettingCapabilities.available.value = const {'wifi'};
      await pump(tester);
      expect(find.text('Needs a Radio'), findsOneWidget);
    });

    testWidgets('an item nobody answers is shown, and disabled', (
      tester,
    ) async {
      await pump(tester);
      final row = tester.widget<SettingSwitchTile>(
        find.ancestor(
          of: find.text('Not Wired Yet'),
          matching: find.byType(SettingSwitchTile),
        ),
      );
      expect(row.enabled, isFalse);
      expect(row.onChanged, isNull);
    });
  });

  group('moving one', () {
    testWidgets('the center throws a switch where it stands', (tester) async {
      final wheel = await pump(tester);
      expect(settings.value('/settings/gapless'), isTrue);
      await press(tester, wheel);
      expect(settings.value('/settings/gapless'), isFalse);
      await press(tester, wheel);
      expect(settings.value('/settings/gapless'), isTrue);
    });

    testWidgets('a disabled row does nothing when activated', (tester) async {
      final wheel = await pump(tester);
      // Down to the unbound switch. The rule between brightness and theme
      // is not a row, so it costs no detent: gapless, brightness, theme,
      // recheck, unbound.
      await jog(tester, wheel, 4);
      await press(tester, wheel);
      expect(settings.value('/settings/unbound'), isFalse);
    });

    testWidgets('a slider takes the wheel, moves by its step, and gives it '
        'back', (tester) async {
      final wheel = await pump(tester);
      await jog(tester, wheel, 1);
      expect(find.text('80%'), findsOneWidget);

      // The list is still driving until the row is activated.
      await jog(tester, wheel, 1);
      await jog(tester, wheel, -1);
      expect(settings.value('/settings/brightness'), 80);

      await press(tester, wheel);
      await jog(tester, wheel, 2);
      expect(settings.value('/settings/brightness'), 90);
      expect(find.text('90%'), findsOneWidget);

      // And it stops at the end rather than running past it.
      await jog(tester, wheel, 10);
      expect(settings.value('/settings/brightness'), 100);

      // The center gives the wheel back, and the list walks again.
      await press(tester, wheel);
      await jog(tester, wheel, 2);
      expect(settings.value('/settings/brightness'), 100);
    });

    testWidgets('menu gives the wheel back too, and does not leave the '
        'page', (tester) async {
      final wheel = await pump(tester);
      await jog(tester, wheel, 1);
      await press(tester, wheel);
      await jog(tester, wheel, -2);
      expect(settings.value('/settings/brightness'), 70);

      wheel.press(WheelButton.menu);
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      await jog(tester, wheel, 1);
      expect(settings.value('/settings/brightness'), 70);
    });

    testWidgets('an inline choice advances one option per click', (
      tester,
    ) async {
      final wheel = await pump(tester);
      await jog(tester, wheel, 2);
      await press(tester, wheel);
      await jog(tester, wheel, -1);
      expect(settings.value('/settings/theme'), 'light');
      await jog(tester, wheel, 1);
      expect(settings.value('/settings/theme'), 'dark');
    });

    testWidgets('a paged choice opens its answers, marks the current one, '
        'and takes the one chosen', (tester) async {
      final wheel = await pump(tester);
      await jog(tester, wheel, 3);
      await press(tester, wheel);

      expect(find.byType(SettingOptionsScreen), findsOneWidget);
      expect(find.text('When a Card Arrives'), findsOneWidget);

      await jog(tester, wheel, 1);
      await press(tester, wheel);
      expect(settings.value('/settings/recheck'), 'card');
      expect(find.byType(SettingOptionsScreen), findsNothing);
    });
  });

  group('going deeper', () {
    testWidgets('a group opens a page of its own', (tester) async {
      final wheel = await pump(tester);
      await jog(tester, wheel, 5);
      await press(tester, wheel);
      expect(find.text('Inside'), findsOneWidget);
      expect(find.text('Gapless'), findsNothing);

      wheel.press(WheelButton.menu);
      await tester.pumpAndSettle();
      expect(find.text('Gapless'), findsOneWidget);
    });

    testWidgets('a destructive action asks first, and cancel is where the '
        'wheel lands', (tester) async {
      final wheel = await pump(tester);
      await jog(tester, wheel, 6);
      await press(tester, wheel);
      expect(find.text('Erase it all?'), findsOneWidget);
      expect(done, isEmpty);

      await press(tester, wheel);
      expect(done, isEmpty, reason: 'the first row is Cancel');
      expect(find.byType(SettingConfirmScreen), findsNothing);

      await press(tester, wheel);
      await jog(tester, wheel, 1);
      await press(tester, wheel);
      expect(done, ['/settings/erase']);
    });
  });
}
