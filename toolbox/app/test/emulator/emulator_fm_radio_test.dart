import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tempo_toolbox/emulator/src/emulator_fm_radio.dart';
import 'package:tempo_toolbox/emulator/src/mock_fm_radio.dart';
import 'package:tempo_toolbox/emulator/src/rig.dart';
import 'package:tempo_toolbox/emulator/src/rig_panel.dart';
import 'package:tomeui/tomeui.dart';

void main() {
  testWidgets(
    'mock stations rotate RDS and clear it between stations and on pause',
    (tester) async {
      final radio = MockFmRadio();
      addTearDown(radio.dispose);
      await radio.tune(95500);
      expect(radio.value.programName, 'GRAVY FM');
      expect(radio.value.stereo, isTrue);
      final text = radio.value.radioText;
      await tester.pump(const Duration(seconds: 8));
      expect(radio.value.radioText, isNot(text));
      await radio.seek(FmSeekDirection.up);
      expect(radio.value.frequencyKhz, 98300);
      expect(radio.value.programName, 'GOOSE FM');
      await radio.tune(88100);
      expect(radio.value.stereo, isFalse);
      await radio.tune(88200);
      expect(radio.value.programName, isNull);
      expect(radio.value.radioText, isNull);
      await radio.setOn(false);
      expect(radio.value.stereo, isNull);
      expect(radio.value.rssi, isNull);
    },
  );

  test('no SDR forces mock mode and rejects toggle requests', () async {
    final radio = EmulatorFmRadio(
      live: FmRadioSwitch(),
      checkAttached: () async => false,
      watch: false,
    );
    addTearDown(radio.dispose);
    await radio.checkHardware();
    expect(radio.mocked, isTrue);
    expect(radio.canToggle, isFalse);
    await radio.setMocked(false);
    expect(radio.mocked, isTrue);
    await radio.tune(95500);
    expect(radio.value.programName, 'GRAVY FM');
  });

  test('provider switching and unplugging preserve tuning and release live reception', () async {
    var attached = true;
    final live = FmRadioSwitch();
    final radio = EmulatorFmRadio(
      live: live,
      checkAttached: () async => attached,
      watch: false,
    );
    addTearDown(radio.dispose);
    await radio.checkHardware();
    expect(radio.mocked, isFalse);
    expect(radio.canToggle, isTrue);
    await radio.tune(98300);
    expect(live.value.on, isTrue);
    await radio.setMocked(true);
    expect(live.value.on, isFalse);
    expect(radio.value.on, isTrue);
    expect(radio.value.frequencyKhz, 98300);
    expect(radio.value.programName, 'GOOSE FM');
    await radio.setMocked(false);
    expect(radio.mock.value.on, isFalse);
    expect(live.value.on, isTrue);
    expect(radio.value.programName, isNull);
    attached = false;
    await radio.checkHardware();
    expect(radio.mocked, isTrue);
    expect(radio.canToggle, isFalse);
    expect(live.value.on, isFalse);
    expect(radio.value.programName, 'GOOSE FM');
  });

  test(
    'mock preference survives attachment and is separate from forced fallback',
    () async {
      var attached = false;
      final radio = EmulatorFmRadio(
        live: FmRadioSwitch(),
        checkAttached: () async => attached,
        watch: false,
      );
      addTearDown(radio.dispose);
      await radio.restorePreference(true);
      attached = true;
      await radio.checkHardware();
      expect(radio.mocked, isTrue);
      expect(radio.preferMock, isTrue);
      expect(radio.canToggle, isTrue);
    },
  );

  testWidgets('emulator settings disable the mock toggle without an SDR', (
    tester,
  ) async {
    final rig = Rig();
    addTearDown(rig.dispose);
    await tester.pumpWidget(TomeApp(home: RigPanel(rig: rig)));
    final toggle = tester.widget<Switch>(
      find.byKey(const Key('Emulator.mockFm')),
    );
    expect(toggle.value, isTrue);
    expect(toggle.onChanged, isNull);
    expect(
      find.text('FM radio uses simulated stations.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
