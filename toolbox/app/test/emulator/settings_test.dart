import 'dart:io';

import 'package:tempo_core/tempo_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_toolbox/emulator/src/emulator_window.dart';
import 'package:tempo_toolbox/emulator/src/rig.dart';
import 'package:tempo_toolbox/emulator/src/settings.dart';

/// The emulator is meant to come back up where it was left - one file, and
/// all of it, rather than a window at the right size holding a battery at
/// the wrong one.
void main() {
  late Directory temp;

  setUp(
    () => temp = Directory.systemTemp.createTempSync('tempo-emulator-test'),
  );
  tearDown(() {
    temp.deleteSync(recursive: true);
    Appearance.mode.value = AppearanceMode.dark;
    Appearance.scale.value = UiScale.regular;
    ScreenSleep.inhibited.value = false;
  });

  EmulatorSettings settingsFor(EmulatorWindow window, Rig rig) =>
      EmulatorSettings(
        window: window,
        rig: rig,
        file: File('${temp.path}/emulator.json'),
      );

  test(
    'the requested FM provider persists even without an attached SDR',
    () async {
      final rig = Rig();
      addTearDown(rig.dispose);
      await rig.fmRadio.restorePreference(true);
      final settings = settingsFor(EmulatorWindow(), rig);
      settings.saveSync();
      final restored = Rig();
      addTearDown(restored.dispose);
      await settingsFor(EmulatorWindow(), restored).load();
      expect(restored.fmRadio.preferMock, isTrue);
      expect(restored.fmRadio.mocked, isTrue);
      expect(restored.fmRadio.canToggle, isFalse);
    },
  );

  test('a session comes back the way it was left', () async {
    final rig = Rig();
    addTearDown(rig.dispose);
    final window = EmulatorWindow();

    window.restoreZoom(3);
    Appearance.mode.value = AppearanceMode.light;
    Appearance.scale.value = UiScale.large;
    ScreenSleep.inhibited.value = true;
    rig.setCharge(12);
    rig.setCharging(true);
    rig.setWifi(WifiStatus.disconnected);
    rig.setBluetooth(BluetoothStatus.off);
    rig.cardSource = CardSource.hostFolder;
    rig.hostFolder = '${temp.path}/card';
    await settingsFor(window, rig).save();

    // A fresh everything, as if the emulator had been restarted.
    Appearance.mode.value = AppearanceMode.dark;
    Appearance.scale.value = UiScale.regular;
    ScreenSleep.inhibited.value = false;
    final second = Rig();
    addTearDown(second.dispose);
    final secondWindow = EmulatorWindow();
    await settingsFor(secondWindow, second).load();

    expect(secondWindow.zoom, 3);
    expect(Appearance.mode.value, AppearanceMode.light);
    expect(Appearance.scale.value, UiScale.large);
    expect(ScreenSleep.inhibited.value, isTrue);
    expect(second.battery.value.percent, 12);
    expect(second.battery.value.charging, isTrue);
    expect(second.wifi.value.status, WifiStatus.disconnected);
    expect(second.bluetooth.value.status, BluetoothStatus.off);
    expect(second.cardSource, CardSource.hostFolder);
    expect(second.hostFolder, '${temp.path}/card');
  });

  test(
    'old host mode restores safely into mocked data',
    () async {
      final host = MockRadios()..wifi = WifiReading.off;
      final rig = Rig(radios: RadioService(host: host));
      addTearDown(rig.dispose);
      rig.setBars(1);
      await rig.radios.setMode(RadioMode.host);
      expect(rig.wifi.value.status, WifiStatus.off);
      await settingsFor(EmulatorWindow(), rig).save();

      final restored = Rig(
        radios: RadioService(host: MockRadios()..wifi = WifiReading.off),
      );
      addTearDown(restored.dispose);
      await settingsFor(EmulatorWindow(), restored).load();
      expect(restored.radios.mode, RadioMode.mocked);
      await restored.radios.setMode(RadioMode.mocked);
      expect(restored.wifi.value.status, WifiStatus.connected);
      expect(restored.wifi.value.bars, 1);
    },
  );

  test('a change made just before closing is written, not dropped', () async {
    final rig = Rig();
    addTearDown(rig.dispose);
    final window = EmulatorWindow();
    final settings = settingsFor(window, rig)..watch();

    // Switched to the made-up card and closed within the settling time.
    rig.cardSource = CardSource.inMemory;
    settings.dispose();

    final second = Rig();
    addTearDown(second.dispose);
    await settingsFor(EmulatorWindow(), second).load();
    expect(second.cardSource, CardSource.inMemory);
  });

  test('a settings file that is nonsense is not a broken emulator', () async {
    final file = File('${temp.path}/emulator.json')..writeAsStringSync('{[');
    final rig = Rig();
    addTearDown(rig.dispose);
    final window = EmulatorWindow();

    await EmulatorSettings(window: window, rig: rig, file: file).load();

    expect(window.zoom, 2, reason: 'the default, still');
    expect(rig.battery.value.percent, 78);
  });
}
