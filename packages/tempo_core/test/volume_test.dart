import 'dart:async';

import 'package:tempo_core/tempo_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

class LiveVolumeTempod extends Tempod {
  int level = 40;
  String? device;
  bool hardware = false;
  Completer<Map<String, Object?>>? heldRead;
  @override
  bool get available => true;
  @override
  Future<Map<String, Object?>> request(Map<String, Object?> request) async {
    if (request['level'] case final int requested) {
      level = requested;
    } else if (heldRead case final pending?) {
      return pending.future;
    }
    return {
      'ok': true,
      'level': level,
      'muted': false,
      'device': device,
      'hardware': hardware,
    };
  }
}

/// The rocker moves the level a step at a time and puts the volume on
/// screen while it does; the wheel does the same on home; asleep, the
/// level still moves but the panel stays dark; and the display goes away
/// on its own once the presses stop.
void main() {
  testWidgets(
    'remote volume changes refresh and stale reads cannot undo a press',
    (tester) async {
      final daemon = LiveVolumeTempod();
      final volume = DeviceVolume(
        tempod: daemon,
        period: const Duration(milliseconds: 50),
      );
      await tester.pump();
      expect(volume.value.level, 40);
      daemon.level = 65;
      await tester.pump(const Duration(milliseconds: 50));
      expect(volume.value.level, 65);
      final stale = Completer<Map<String, Object?>>();
      daemon.heldRead = stale;
      await tester.pump(const Duration(milliseconds: 50));
      await volume.setLevel(70);
      stale.complete({'ok': true, 'level': 20, 'muted': false});
      daemon.heldRead = null;
      await tester.pump();
      expect(volume.value.level, 70);
      volume.dispose();
    },
  );

  testWidgets(
    'API confirmation rejects deferred Bluetooth volume without queuing it',
    (tester) async {
      final daemon = LiveVolumeTempod()
        ..device = 'Soundcore Flare+'
        ..hardware = true;
      final volume = DeviceVolume(tempod: daemon);
      await tester.pump();
      volume.setPlaybackActive(false);
      await expectLater(
        volume.setLevelConfirmed(10),
        throwsA(isA<TempodError>()),
      );
      expect(volume.value.level, 40);
      volume.setPlaybackActive(true);
      await tester.pump();
      expect(daemon.level, 40);
      volume.dispose();
    },
  );

  testWidgets('Bluetooth changes while paused wait for playback to resume', (
    tester,
  ) async {
    final daemon = LiveVolumeTempod()
      ..device = 'Soundcore Flare+'
      ..hardware = true;
    final volume = DeviceVolume(tempod: daemon);
    await tester.pump();
    volume.setPlaybackActive(false);
    await volume.setLevel(10);
    await volume.setLevel(35);
    await tester.pump(const Duration(seconds: 1));
    expect(daemon.level, 40);
    expect(volume.value.level, 35);
    volume.setPlaybackActive(true);
    await tester.pump();
    expect(daemon.level, 35);
    volume.dispose();
  });

  testWidgets(
    'queued Bluetooth volume does not change a replacement local output',
    (tester) async {
      final daemon = LiveVolumeTempod()
        ..device = 'Soundcore Flare+'
        ..hardware = true;
      final volume = DeviceVolume(tempod: daemon);
      await tester.pump();
      volume.setPlaybackActive(false);
      await volume.setLevel(90);
      daemon.device = null;
      daemon.hardware = false;
      daemon.level = 30;
      volume.setPlaybackActive(true);
      await tester.pump();
      expect(daemon.level, 30);
      expect(volume.value.level, 30);
      volume.dispose();
    },
  );

  late ClickWheelController wheel;
  late ScreenSwitch screen;
  late VolumeSwitch volume;

  Future<void> pumpApp(WidgetTester tester, {int level = 50}) async {
    wheel = ClickWheelController();
    screen = ScreenSwitch();
    volume = VolumeSwitch(level: level);
    final services = PlayerServices(
      battery: ValueNotifier(const BatteryReading(percent: 50)),
      wifi: ValueNotifier(WifiReading.off),
      bluetooth: ValueNotifier(BluetoothReading.off),
      storage: ValueNotifier(StorageReading.empty),
      places: PlayerServices.fallback.places,
      screen: screen,
      volume: volume,
      output: OutputSwitch(),
      feedback: FeedbackSwitch(),
    );
    await tester.pumpWidget(
      PanelSurface(
        child: TempoApp(wheel: wheel, services: services),
      ),
    );
    await tester.pump();
  }

  /// The display's fade, frame by frame: one frame starts the ticker,
  /// the fade's worth finishes it, and one more lets the tree follow.
  Future<void> fade(WidgetTester tester) async {
    await tester.pump(VolumeOsd.fade);
    await tester.pump(VolumeOsd.fade);
    await tester.pump();
  }

  /// Put the display away before the test ends: its clock is a pending
  /// timer, and the binding wants none left over.
  Future<void> settle(WidgetTester tester) async {
    VolumeOsd.hide();
    await fade(tester);
  }

  Finder card() => find.byKey(VolumeOsd.cardKey);

  testWidgets('external volume changes show and extend the OSD', (
    tester,
  ) async {
    await pumpApp(tester);
    volume.value = const VolumeReading(level: 35);
    await fade(tester);
    expect(card(), findsOneWidget);
    await tester.pump(VolumeOsd.linger - const Duration(milliseconds: 200));
    volume.value = const VolumeReading(level: 40);
    await tester.pump(const Duration(milliseconds: 250));
    expect(Osd.current.value, isNotNull);
    await tester.pump(VolumeOsd.linger);
    await fade(tester);
    expect(card(), findsNothing);
    await settle(tester);
  });

  testWidgets('external volume changes leave a sleeping screen dark', (
    tester,
  ) async {
    await pumpApp(tester);
    await screen.setOn(false);
    await tester.pump();
    volume.value = const VolumeReading(level: 35);
    await fade(tester);
    expect(Osd.current.value, isNull);
    expect(screen.value, isFalse);
    await settle(tester);
  });

  testWidgets(
    'Bluetooth OSD names the device and distinguishes hardware volume',
    (tester) async {
      await pumpApp(tester);
      volume.value = const VolumeReading(
        level: 35,
        device: 'Soundcore Flare+',
        hardware: true,
      );
      await fade(tester);
      expect(find.text('Soundcore Flare+'), findsOneWidget);
      expect(find.text('35%'), findsOneWidget);
      expect(find.byIcon(LucideIcons.bluetooth), findsWidgets);
      expect(tester.takeException(), isNull);
      volume.value = const VolumeReading(level: 35, device: 'Soundcore Flare+');
      await tester.pump();
      expect(find.text('Player 35%'), findsOneWidget);
      await settle(tester);
    },
  );

  testWidgets('the rocker steps the level and shows it', (tester) async {
    await pumpApp(tester);
    expect(
      card(),
      findsNothing,
      reason: 'idle, the display is not in the tree',
    );

    wheel.press(WheelButton.volumeUp);
    await tester.pump();
    expect(volume.value.level, 55);
    await fade(tester);
    expect(card(), findsOneWidget);
    // The level is the bar, not a number: the card carries no digits.
    expect(find.byKey(OsdBar.fillKey), findsOneWidget);
    expect(find.text('55'), findsNothing);
    // And the card is square.
    final size = tester.getSize(card());
    expect(size.width, closeTo(size.height, 0.5));

    wheel.press(WheelButton.volumeDown);
    wheel.press(WheelButton.volumeDown);
    await tester.pump();
    expect(volume.value.level, 45);
    await settle(tester);
  });

  testWidgets('the display goes away after the last press', (tester) async {
    await pumpApp(tester);
    wheel.press(WheelButton.volumeUp);
    await fade(tester);
    expect(card(), findsOneWidget);

    // A press inside the linger keeps it up.
    await tester.pump(VolumeOsd.linger - const Duration(milliseconds: 200));
    wheel.press(WheelButton.volumeUp);
    await tester.pump(const Duration(milliseconds: 400));
    expect(card(), findsOneWidget);

    await tester.pump(VolumeOsd.linger);
    await fade(tester);
    expect(card(), findsNothing, reason: 'faded out, it leaves the tree');
  });

  testWidgets('on home the wheel is the volume', (tester) async {
    await pumpApp(tester);
    wheel.jog(1);
    await tester.pump();
    expect(volume.value.level, 55, reason: 'clockwise is louder');
    wheel.jog(-1, page: true);
    await tester.pump();
    expect(volume.value.level, 45, reason: 'the fast tier is two steps');
    await fade(tester);
    expect(card(), findsOneWidget);
    await settle(tester);
  });

  testWidgets('the level stops at the ends', (tester) async {
    await pumpApp(tester, level: 97);
    wheel.press(WheelButton.volumeUp);
    await tester.pump();
    expect(volume.value.level, 100);
    for (var i = 0; i < 25; i++) {
      wheel.press(WheelButton.volumeDown);
    }
    await tester.pump();
    expect(volume.value.level, 0);
    await settle(tester);
  });

  testWidgets('the bar is the level', (tester) async {
    await pumpApp(tester, level: 25);
    wheel.press(WheelButton.volumeUp); // 30
    await fade(tester);
    final bar = tester.getSize(find.byType(OsdBar));
    final lit = tester.getSize(find.byKey(OsdBar.fillKey));
    expect(
      lit.height,
      tester.getSize(find.byType(OsdBar)).height,
      reason: 'the fill is as tall as the bar, not a line of zero',
    );
    expect(lit.width / bar.width, closeTo(0.30, 0.02));
    for (var i = 0; i < 10; i++) {
      wheel.press(WheelButton.volumeUp); // 80
    }
    await tester.pump();
    final wider = tester.getSize(find.byKey(OsdBar.fillKey));
    expect(wider.width / bar.width, closeTo(0.80, 0.02));
    await settle(tester);
  });

  testWidgets('a change of output puts its name up', (tester) async {
    final output = OutputSwitch();
    wheel = ClickWheelController();
    screen = ScreenSwitch();
    volume = VolumeSwitch();
    final services = PlayerServices(
      battery: ValueNotifier(const BatteryReading(percent: 50)),
      wifi: ValueNotifier(WifiReading.off),
      bluetooth: ValueNotifier(BluetoothReading.off),
      storage: ValueNotifier(StorageReading.empty),
      places: PlayerServices.fallback.places,
      screen: screen,
      volume: volume,
      output: output,
      feedback: FeedbackSwitch(),
    );
    await tester.pumpWidget(
      PanelSurface(
        child: TempoApp(wheel: wheel, services: services),
      ),
    );
    await tester.pump();
    expect(card(), findsNothing, reason: 'the output at start is no news');

    output.value = AudioOutput.headphones;
    await fade(tester);
    expect(card(), findsOneWidget);
    expect(find.text('Headphones'), findsOneWidget);

    output.value = AudioOutput.speaker;
    await tester.pump();
    expect(find.text('Speaker'), findsOneWidget);

    // The same toast, the same clock: it goes away on its own.
    await tester.pump(VolumeOsd.linger);
    await fade(tester);
    expect(card(), findsNothing);

    output.value = const AudioOutput(OutputKind.bluetooth, name: 'WH-1000XM4');
    await fade(tester);
    expect(find.text('WH-1000XM4'), findsOneWidget);
    await settle(tester);
  });

  testWidgets('asleep, the rocker still moves the level, quietly', (
    tester,
  ) async {
    await pumpApp(tester);
    await screen.setOn(false);
    await tester.pumpAndSettle();

    wheel.press(WheelButton.volumeDown);
    await fade(tester);
    expect(volume.value.level, 45);
    expect(card(), findsNothing, reason: 'the panel is dark; nothing to show');

    // And the wheel is still silent: a pocket must not turn the volume.
    wheel.jog(1);
    await tester.pump();
    expect(volume.value.level, 45);
    await settle(tester);
  });
}
