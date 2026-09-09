import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

class RoutingTempod extends Tempod {
  Map<String, Object?> reply = {
    'ok': true,
    'ready': true,
    'output': 'speaker',
    'jack': false,
    'sinks': <Object>[],
  };
  final requests = <Map<String, Object?>>[];
  @override
  bool get available => true;
  @override
  Future<Map<String, Object?>> request(Map<String, Object?> request) async {
    requests.add(request);
    return reply;
  }
}

void main() {
  test(
    'arrivals distinguish baseline, Bluetooth arrival, and both jack edges',
    () async {
      final daemon = RoutingTempod();
      final output = DeviceOutput(tempod: daemon);
      final events = <AudioOutput>[];
      final sub = output.arrivals.listen(events.add);
      await output.read();
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
      daemon.reply = {
        ...daemon.reply,
        'sinks': [
          {'id': 'bluez_output.one', 'name': 'Flare'},
        ],
      };
      await output.read();
      await output.read();
      daemon.reply = {...daemon.reply, 'jack': true};
      await output.read();
      daemon.reply = {...daemon.reply, 'jack': false, 'sinks': <Object>[]};
      await output.read();
      await Future<void>.delayed(Duration.zero);
      expect(events, [
        const AudioOutput(
          OutputKind.bluetooth,
          name: 'Flare',
          id: 'bluez_output.one',
        ),
        AudioOutput.headphones,
        AudioOutput.speaker,
      ]);
      await output.select(events.first);
      expect(
        daemon.requests,
        contains(equals({'op': 'output', 'target': 'bluez_output.one'})),
      );
      await sub.cancel();
      output.dispose();
    },
  );

  for (final mode in ['switch', 'ask', 'ignore']) {
    testWidgets('$mode controls routing rather than device detection', (
      tester,
    ) async {
      MenuDock.reset();
      final output = OutputSwitch()..onNewDevice.value = mode;
      final wheel = ClickWheelController();
      final services = PlayerServices(
        battery: ValueNotifier(const BatteryReading(percent: 50)),
        wifi: ValueNotifier(WifiReading.off),
        bluetooth: ValueNotifier(BluetoothReading.off),
        storage: ValueNotifier(StorageReading.empty),
        places: PlayerServices.fallback.places,
        screen: ScreenSwitch(),
        volume: VolumeSwitch(),
        output: output,
        feedback: FeedbackSwitch(),
      );
      await tester.pumpWidget(
        PanelSurface(
          child: TempoApp(wheel: wheel, services: services),
        ),
      );
      await tester.pump();
      // Local jack changes are automatic in every policy mode.
      output.value = AudioOutput.headphones;
      output.detect(AudioOutput.headphones);
      await tester.pumpAndSettle();
      expect(find.text('Switch to Headphones?'), findsNothing);
      output.value = AudioOutput.speaker;
      output.detect(AudioOutput.speaker);
      await tester.pumpAndSettle();
      expect(find.text('Switch to Speaker?'), findsNothing);
      output.detect(
        const AudioOutput(
          OutputKind.bluetooth,
          id: 'bluez_output.first',
          name: 'First',
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      if (mode == 'ask') {
        expect(output.value, AudioOutput.speaker);
        expect(find.text('Switch to First?'), findsOneWidget);
        // A newer event replaces the question and its destination.
        output.detect(
          const AudioOutput(
            OutputKind.bluetooth,
            id: 'bluez_output.one',
            name: 'Flare',
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('Switch to Flare?'), findsOneWidget);
        await tester.pumpAndSettle();
        wheel.press(WheelButton.select);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(output.value.kind, OutputKind.bluetooth);
        output.detect(AudioOutput.headphones);
        await tester.pumpAndSettle();
        wheel.press(WheelButton.menu);
        await tester.pumpAndSettle();
        expect(output.value.kind, OutputKind.bluetooth);
      } else {
        expect(
          output.value,
          mode == 'switch'
              ? const AudioOutput(
                  OutputKind.bluetooth,
                  id: 'bluez_output.first',
                  name: 'First',
                )
              : AudioOutput.speaker,
        );
        expect(find.text('Switch to Headphones?'), findsNothing);
      }
      Osd.hide();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      output.dispose();
    });
  }
}
