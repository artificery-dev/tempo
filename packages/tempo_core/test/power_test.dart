import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

/// The power dialog takes the wheel over: half a revolution of the wheel
/// slides the box between Restart and Power Off, the same past either end
/// lets go up to the close button, a turn from there comes back down, and
/// the center takes whatever is lit. Menu - the reflex that leaves every
/// other screen - only walks up. And it is one dialog, however many times
/// the key is held.
void main() {
  final systemctl = PowerDialog.perform;
  final performed = <PowerCommand>[];

  setUp(() {
    performed.clear();
    PowerDialog.perform = (command) async => performed.add(command);
  });
  tearDown(() => PowerDialog.perform = systemctl);

  Future<void> hold(WidgetTester tester, ClickWheelController wheel) async {
    wheel.powerDown();
    await tester.pump(const Duration(milliseconds: 1600));
    wheel.powerUp();
    await tester.pumpAndSettle();
  }

  Future<ClickWheelController> pumpAndOpen(WidgetTester tester) async {
    final wheel = ClickWheelController();
    await tester.pumpWidget(TempoApp(wheel: wheel));
    await tester.pumpAndSettle();
    await hold(tester, wheel);
    expect(find.byType(PowerDialog), findsOneWidget);
    return wheel;
  }

  /// The option under the rail's box: the only place the wheel can be on
  /// this card.
  String lit(WidgetTester tester) {
    final rail = tester.widget<WheelRail<PowerCommand>>(
      find.byType(WheelRail<PowerCommand>),
    );
    return switch (rail.value) {
      PowerCommand.restart => 'Restart',
      PowerCommand.shutDown => 'Power Off',
      null => 'nothing',
    };
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

  /// One turn of the rail: the weight every rail of options shares - the
  /// distance between its two options, and off an end to the close button.
  final turn = panelRailWeight;

  /// The detent that carries the box's center over the line between the
  /// options.
  final cross = turn ~/ 2 + 1;

  /// A rest, for the box to settle where it is.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  testWidgets('power failure remains visible and can be retried', (
    tester,
  ) async {
    final wheel = await pumpAndOpen(tester);
    PowerDialog.perform = (_) async => throw StateError('daemon refused');
    await press(tester, wheel, WheelButton.select);
    expect(find.byType(PowerDialog), findsOneWidget);
    expect(find.textContaining('daemon refused'), findsOneWidget);
    PowerDialog.perform = (command) async => performed.add(command);
    await press(tester, wheel, WheelButton.select);
    expect(performed, [PowerCommand.restart]);
    expect(find.byType(PowerDialog), findsNothing);
  });

  testWidgets('pending power action only sends once', (tester) async {
    final wheel = await pumpAndOpen(tester);
    final completed = Completer<void>();
    PowerDialog.perform = (command) {
      performed.add(command);
      return completed.future;
    };
    wheel.press(WheelButton.select);
    await tester.pump();
    wheel.press(WheelButton.select);
    await tester.pump();
    expect(performed, [PowerCommand.restart]);
    completed.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('opens on a hold with Restart under the box, and the wheel '
      'slides, gives, lets go, and comes back', (tester) async {
    final wheel = await pumpAndOpen(tester);
    expect(lit(tester), 'Restart');

    await jog(tester, wheel, cross - 1);
    expect(lit(tester), 'Restart', reason: 'on the line, not over it');
    await jog(tester, wheel, 1);
    expect(lit(tester), 'Power Off', reason: 'over the line: the click');
    await settle(tester);
    await jog(tester, wheel, turn);
    expect(
      lit(tester),
      'Power Off',
      reason:
          'off the end the box waits at the give: there is nowhere else '
          'on this card for the wheel to be',
    );

    // And comes back the way it went out.
    await jog(tester, wheel, -turn);
    expect(lit(tester), 'Power Off');
    await jog(tester, wheel, -cross);
    expect(lit(tester), 'Restart');
    await settle(tester);
    await jog(tester, wheel, -turn);
    expect(lit(tester), 'Restart', reason: 'the start gives the same way');

    // A fast spin is one detent.
    wheel.jog(turn, page: true);
    await tester.pumpAndSettle();
    expect(lit(tester), 'Restart');
  });

  testWidgets('the ring buttons walk it as a d-pad', (tester) async {
    final wheel = await pumpAndOpen(tester);

    await press(tester, wheel, WheelButton.next);
    expect(lit(tester), 'Power Off');
    await press(tester, wheel, WheelButton.next);
    expect(lit(tester), 'Power Off', reason: 'a button never lets go');
    await press(tester, wheel, WheelButton.previous);
    expect(lit(tester), 'Restart');
    await press(tester, wheel, WheelButton.previous);
    expect(lit(tester), 'Restart', reason: 'and never off the near end');
    await press(tester, wheel, WheelButton.playPause);
    expect(lit(tester), 'Restart', reason: 'play says nothing here');
  });

  testWidgets('a turn past the end keeps the rail: there is nowhere else '
      'on this card to go', (tester) async {
    final wheel = await pumpAndOpen(tester);
    await jog(tester, wheel, turn);
    expect(lit(tester), 'Power Off');
    await jog(tester, wheel, turn);
    expect(lit(tester), 'Power Off', reason: 'the box waits at the give');
    await settle(tester);
    expect(lit(tester), 'Power Off');
    expect(find.byType(PowerDialog), findsOneWidget);
  });

  testWidgets('menu does not leave it, and says nothing at all', (
    tester,
  ) async {
    final wheel = await pumpAndOpen(tester);

    await press(tester, wheel, WheelButton.menu);
    expect(find.byType(PowerDialog), findsOneWidget);
    expect(lit(tester), 'Restart', reason: 'the box did not move');
    expect(performed, isEmpty);
  });

  testWidgets('the center takes the option under the box', (tester) async {
    final wheel = await pumpAndOpen(tester);

    await jog(tester, wheel, turn);
    await press(tester, wheel, WheelButton.select);
    expect(find.byType(PowerDialog), findsNothing);
    expect(performed, [PowerCommand.shutDown]);

    await hold(tester, wheel);
    expect(lit(tester), 'Restart', reason: 'a fresh dialog starts safe');
    await press(tester, wheel, WheelButton.select);
    expect(performed, [PowerCommand.shutDown, PowerCommand.restart]);
  });

  testWidgets('the hold that opened it closes it, and does nothing else', (
    tester,
  ) async {
    final wheel = await pumpAndOpen(tester);
    await jog(tester, wheel, turn);

    await hold(tester, wheel);
    expect(find.byType(PowerDialog, skipOffstage: false), findsNothing);
    expect(performed, isEmpty);
    expect(find.byType(HomeScreen), findsOneWidget);

    // And the next hold is a fresh dialog, not a second copy of anything.
    await hold(tester, wheel);
    expect(find.byType(PowerDialog, skipOffstage: false), findsOneWidget);
    expect(lit(tester), 'Restart');
  });

  testWidgets('the wheel underneath does not hear it, and the dock steps '
      'aside', (tester) async {
    addTearDown(() => MenuDock.shown.value = false);
    final wheel = ClickWheelController();
    await tester.pumpWidget(TempoApp(wheel: wheel));
    await tester.pumpAndSettle();
    await press(tester, wheel, WheelButton.select);
    expect(MenuDock.shown.value, isTrue);

    await hold(tester, wheel);
    expect(MenuDock.shown.value, isFalse, reason: 'one thing holds the wheel');
    // Along the rail and out on the hold - and the screen under it is
    // exactly where it was.
    await jog(tester, wheel, turn);
    expect(lit(tester), 'Power Off');
    await hold(tester, wheel);
    expect(find.byType(PowerDialog), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(MenuListScreen), findsNothing);
    // And the center is home's again: the dock comes up.
    await press(tester, wheel, WheelButton.select);
    expect(MenuDock.shown.value, isTrue);
  });

  testWidgets('Settings > Power > Power Off asks first, and then does it', (
    tester,
  ) async {
    // The menu no longer carries a Power leaf: the dialog is the power
    // key's, and Settings has the two commands as actions of its own.
    expect(systemMenu.at('/settings/system/power'), isNull);

    final done = <PowerCommand>[];
    final was = PowerDialog.perform;
    PowerDialog.perform = (command) async => done.add(command);
    addTearDown(() {
      PowerDialog.perform = was;
      MenuDock.shown.value = false;
      SettingBindings.clear();
    });

    final settings = Settings(tree: playerSettingsTree);
    SettingBindings.registerActions({
      'power.shutdown': (_) =>
          unawaited(PowerDialog.perform(PowerCommand.shutDown)),
    });

    final wheel = ClickWheelController();
    await tester.pumpWidget(TempoApp(wheel: wheel, settings: settings));
    await tester.pumpAndSettle();

    // The dock, three along to Settings, then down to Power and into it.
    await press(tester, wheel, WheelButton.select);
    await jog(tester, wheel, 3 * MenuDock.physics.weight);
    await press(tester, wheel, WheelButton.select);
    // The rows the wheel walks: what the screen shows, which is every
    // item the player can offer and no dividers - those are rules over the
    // row below them, not rows.
    int rowOf(SettingLocation group, String id) {
      final rows = [
        for (final child in group.children)
          if (child.node.kind != SettingKind.divider &&
              settings.visible(child.path))
            child,
      ];
      return rows.indexWhere((row) => row.id == id);
    }

    await jog(tester, wheel, rowOf(settings.tree.rootEntry, 'power'));
    await press(tester, wheel, WheelButton.select);
    expect(find.text('Restart'), findsOneWidget);

    // Power Off is the last row, and it asks before it does anything.
    await jog(
      tester,
      wheel,
      rowOf(settings.tree.at('/settings/power')!, 'shutdown'),
    );
    await press(tester, wheel, WheelButton.select);
    expect(find.byType(PowerDialog), findsOneWidget);
    expect(lit(tester), 'Power Off');
    expect(done, isEmpty, reason: 'nothing done on the way in');
    await press(tester, wheel, WheelButton.select);
    expect(done, [PowerCommand.shutDown]);
  });
}
