import 'package:tempo_core/tempo_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

/// One tap of the power key and the screen sleeps: the shade comes down
/// and the wheel goes quiet. One more and it wakes, to exactly where it
/// was. The hold still opens the power screen, awake or not.
const _a = TrackSummary(id: 1, fileId: 1, path: '/m/a', title: 'A');
const _b = TrackSummary(id: 2, fileId: 2, path: '/m/b', title: 'B');

void main() {
  late ClickWheelController wheel;
  late ScreenSwitch screen;
  late SilentPlayback playback;

  setUp(() {
    MenuDock.reset();
    Playback.state.value = PlaybackState.stopped;
  });

  Future<void> pumpApp(WidgetTester tester) async {
    wheel = ClickWheelController();
    screen = ScreenSwitch();
    playback = SilentPlayback();
    final services = PlayerServices(
      battery: ValueNotifier(const BatteryReading(percent: 50)),
      wifi: ValueNotifier(WifiReading.off),
      bluetooth: ValueNotifier(BluetoothReading.off),
      storage: ValueNotifier(StorageReading.empty),
      places: PlayerServices.fallback.places,
      screen: screen,
      volume: VolumeSwitch(),
      output: OutputSwitch(),
      feedback: FeedbackSwitch(),
      playback: playback,
    );
    await tester.pumpWidget(
      PanelSurface(
        child: TempoApp(wheel: wheel, services: services),
      ),
    );
    await tester.pump();
  }

  /// A tap: down, up, and the tap window the chord waits out.
  Future<void> tap(WidgetTester tester) async {
    wheel.powerDown();
    await tester.pump(const Duration(milliseconds: 50));
    wheel.powerUp();
    await tester.pump(const Duration(milliseconds: 400));
  }

  double shade(WidgetTester tester) {
    final shade = find.byKey(ScreenShade.shadeKey);
    return shade.evaluate().isEmpty
        ? 0
        : tester.widget<FadeTransition>(shade).opacity.value;
  }

  testWidgets(
    'double Power toggles the dock without sleeping and wakes it from off',
    (tester) async {
      await pumpApp(tester);
      var changes = 0;
      screen.addListener(() => changes++);
      Future<void> doublePower() async {
        wheel.powerDown();
        wheel.powerUp();
        await tester.pump(const Duration(milliseconds: 100));
        wheel.powerDown();
        wheel.powerUp();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
      }

      await doublePower();
      expect(MenuDock.shown.value, isTrue);
      expect(screen.value, isTrue);
      expect(changes, 0, reason: 'the first tap must not blank the screen');
      await doublePower();
      expect(MenuDock.shown.value, isFalse);
      await screen.setOn(false);
      await tester.pumpAndSettle();
      await doublePower();
      expect(screen.value, isTrue);
      expect(MenuDock.shown.value, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'holding Menu without an app menu does not open the dock or go back',
    (tester) async {
      await pumpApp(tester);
      wheel.menuDown();
      await tester.pump(const Duration(milliseconds: 1600));
      wheel.menuUp();
      await tester.pumpAndSettle();
      expect(MenuDock.shown.value, isFalse);
      expect(find.byType(HomeScreen), findsOneWidget);
    },
  );

  testWidgets('one tap sleeps, one tap wakes', (tester) async {
    await pumpApp(tester);
    expect(screen.value, isTrue);
    expect(shade(tester), 0, reason: 'awake: no shade in the tree');

    await tap(tester);
    expect(screen.value, isFalse);
    await tester.pump(const Duration(milliseconds: 200));
    final midway = shade(tester);
    expect(midway, greaterThan(0));
    expect(midway, lessThan(1), reason: 'it fades rather than cuts');
    await tester.pumpAndSettle();
    expect(shade(tester), 1);

    await tap(tester);
    expect(screen.value, isTrue);
    await tester.pumpAndSettle();
    expect(shade(tester), 0, reason: 'lifted, the shade leaves the tree');
  });

  testWidgets('asleep, the wheel is silent and the center only wakes; '
      'awake again, it is heard', (tester) async {
    await pumpApp(tester);
    addTearDown(() => MenuDock.shown.value = false);
    await tap(tester);
    await tester.pumpAndSettle();
    expect(screen.value, isFalse);

    // The wheel: nothing. The center would bring up the dock on home;
    // asleep it wakes the screen instead, and the dock stays down.
    wheel.jog(3);
    await tester.pumpAndSettle();
    expect(screen.value, isFalse);
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    expect(screen.value, isTrue);
    expect(MenuDock.shown.value, isFalse);

    // Awake, the same press is heard.
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    expect(MenuDock.shown.value, isTrue);
  });

  testWidgets('asleep, the media buttons still speak, and menu says '
      'nothing', (tester) async {
    await pumpApp(tester);
    await playback.play(const [_a, _b]);
    await tester.pumpAndSettle();
    await tap(tester);
    await tester.pumpAndSettle();
    expect(screen.value, isFalse);

    wheel.press(WheelButton.playPause);
    await tester.pumpAndSettle();
    expect(playback.value.state, PlaybackState.paused);
    wheel.press(WheelButton.next);
    await tester.pumpAndSettle();
    expect(playback.value.track, _b);
    expect(screen.value, isFalse, reason: 'the pocket presses did not wake it');

    // Menu says nothing in the dark: not a back, not a wake.
    wheel.press(WheelButton.menu);
    await tester.pumpAndSettle();
    expect(screen.value, isFalse);
    expect(find.byType(HomeScreen), findsOneWidget, reason: 'no back taken');
  });

  testWidgets('holding play stops the player, and leaves the screen on', (
    tester,
  ) async {
    await pumpApp(tester);
    await playback.play(const [_a, _b]);
    await tester.pumpAndSettle();
    wheel.hold(WheelButton.playPause);
    await tester.pumpAndSettle();
    expect(screen.value, isTrue);
    expect(playback.value, NowPlaying.nothing);
    expect(find.byKey(NowPlayingCard.cardKey), findsNothing);
  });

  testWidgets('fifteen seconds in the screen dims, and a word brings the '
      'light back', (tester) async {
    await pumpApp(tester);
    double dim() {
      final wash = find.byKey(DimShade.dimKey);
      return wash.evaluate().isEmpty ? 0 : tester.widget<Opacity>(wash).opacity;
    }

    await tester.pump(const Duration(seconds: 14));
    expect(screen.dimmed.value, isFalse);
    expect(dim(), 0);
    await tester.pump(const Duration(seconds: 2));
    expect(screen.dimmed.value, isTrue);
    await tester.pump(ScreenService.fade);
    await tester.pump();
    expect(dim(), closeTo(DimShade.depth, 0.01));
    expect(screen.value, isTrue, reason: 'dim, not asleep');

    // A word lifts the dim and winds the clock from the top.
    wheel.jog(1);
    await tester.pump();
    expect(screen.dimmed.value, isFalse);
    await tester.pump(ScreenService.fade);
    await tester.pump();
    expect(dim(), 0);
    await tester.pump(const Duration(seconds: 14));
    expect(screen.dimmed.value, isFalse);
    await tester.pump(const Duration(seconds: 2));
    expect(screen.dimmed.value, isTrue);
    await tester.pump(const Duration(seconds: 15));
    expect(screen.value, isFalse);
    expect(screen.dimmed.value, isFalse, reason: 'asleep is not dimmed');
    await tester.pumpAndSettle();
  });

  testWidgets('a dim set at or past the sleep never lands: the light goes '
      'from full to dark', (tester) async {
    addTearDown(() {
      ScreenSleep.dimAfter.value = const Duration(seconds: 15);
    });
    await pumpApp(tester);

    // Both waits are counted from the last word, so one at the other's
    // length is a dim the sleep beats to it.
    ScreenSleep.dimAfter.value = const Duration(seconds: 30);
    wheel.jog(1);
    await tester.pump();

    await tester.pump(const Duration(seconds: 29));
    expect(screen.dimmed.value, isFalse);
    await tester.pump(const Duration(seconds: 2));
    expect(screen.value, isFalse, reason: 'asleep');
    expect(screen.dimmed.value, isFalse, reason: 'and never dimmed');
    await tester.pumpAndSettle();
  });

  testWidgets('and no dim at all is a legal answer', (tester) async {
    addTearDown(() {
      ScreenSleep.dimAfter.value = const Duration(seconds: 15);
    });
    await pumpApp(tester);

    ScreenSleep.dimAfter.value = null;
    wheel.jog(1);
    await tester.pump();

    await tester.pump(const Duration(seconds: 20));
    expect(screen.dimmed.value, isFalse);
    expect(screen.value, isTrue);
    await tester.pump(const Duration(seconds: 11));
    expect(screen.value, isFalse);
    await tester.pumpAndSettle();
  });

  testWidgets('a hand on the clock, and the screen stays awake; lifted, '
      'the wait starts over', (tester) async {
    addTearDown(() => ScreenSleep.inhibited.value = false);
    ScreenSleep.inhibited.value = true;
    await pumpApp(tester);

    await tester.pump(const Duration(seconds: 60));
    expect(screen.value, isTrue);
    expect(screen.dimmed.value, isFalse, reason: 'not even the warning');

    // The power key still works: a hold on the clock is not a hold on
    // the button.
    await tap(tester);
    expect(screen.value, isFalse);
    await tap(tester);
    expect(screen.value, isTrue);

    ScreenSleep.inhibited.value = false;
    await tester.pump(const Duration(seconds: 29));
    expect(screen.value, isTrue);
    await tester.pump(const Duration(seconds: 2));
    expect(screen.value, isFalse);
  });

  testWidgets('left alone, the screen sleeps after its wait; a word '
      'resets the clock; waking winds it again', (tester) async {
    await pumpApp(tester);
    expect(ScreenSleep.after.value, const Duration(seconds: 30));

    await tester.pump(const Duration(seconds: 29));
    expect(screen.value, isTrue);
    wheel.jog(1);
    await tester.pump(const Duration(seconds: 29));
    expect(screen.value, isTrue, reason: 'the jog wound the clock again');
    await tester.pump(const Duration(seconds: 2));
    expect(screen.value, isFalse);

    // A press of the center wakes it, and the clock runs from there.
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    expect(screen.value, isTrue);
    await tester.pump(const Duration(seconds: 31));
    expect(screen.value, isFalse);

    // Told never: it stays.
    ScreenSleep.after.value = null;
    addTearDown(() => ScreenSleep.after.value = const Duration(seconds: 30));
    await tap(tester);
    await tester.pumpAndSettle();
    expect(screen.value, isTrue);
    await tester.pump(const Duration(minutes: 5));
    expect(screen.value, isTrue);
  });

  testWidgets('a hold wakes the screen and opens the power dialog', (
    tester,
  ) async {
    await pumpApp(tester);
    await tap(tester);
    expect(screen.value, isFalse);

    wheel.powerDown();
    await tester.pump(const Duration(milliseconds: 1600));
    wheel.powerUp();
    await tester.pumpAndSettle();
    expect(screen.value, isTrue);
    expect(find.byType(PowerDialog), findsOneWidget);
  });

  testWidgets('the rig switch and the button move the same screen', (
    tester,
  ) async {
    await pumpApp(tester);
    await screen.setOn(false);
    await tester.pumpAndSettle();
    expect(shade(tester), 1);
    await tap(tester);
    expect(screen.value, isTrue);
  });
}
