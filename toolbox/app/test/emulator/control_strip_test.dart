import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tempo_toolbox/emulator/emulator.dart';
import 'package:tempo_toolbox/emulator/src/emulator_window.dart';
import 'package:tempo_toolbox/emulator/src/rig.dart';
import 'package:tomeui/tomeui.dart';

void main() {
  testWidgets('machine settings remain usable at minimum device zoom', (
    tester,
  ) async {
    final rig = Rig();
    await rig.initializeStorage();
    final window = EmulatorWindow(managesWindow: false)..restoreZoom(1);
    tester.view.physicalSize = window.windowSize(0);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(EmulatorApp(window: window, rig: rig));
    await tester.pumpAndSettle();
    final player = tester.state(find.byType(TempoApp));
    final barrierCount = find.byType(ModalBarrier).evaluate().length;
    await tester.ensureVisible(find.byIcon(LucideIcons.slidersHorizontal));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(LucideIcons.slidersHorizontal));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Emulated Device State'), findsOneWidget);
    final overlay = tester.getRect(
      find.byKey(const ValueKey('emulator-frame-settings')),
    );
    final frame = tester.getRect(
      find.byKey(const ValueKey('emulator-player-frame')),
    );
    expect(overlay, frame);
    expect(find.byType(ModalBarrier).evaluate().length, barrierCount);
    expect(tester.state(find.byType(TempoApp)), same(player));
    await tester.ensureVisible(
      find.byKey(const ValueKey('emulator-section-SD card')),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Done'), findsNothing);
    await tester.ensureVisible(find.byIcon(LucideIcons.slidersHorizontal));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(LucideIcons.slidersHorizontal));
    await tester.pumpAndSettle();
    expect(find.text('Emulated Device State'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    rig.dispose();
    window.dispose();
  });

  testWidgets(
    'control strip toggles simulated hardware and closes its window',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final rig = Rig();
      await rig.initializeStorage();
      final window = EmulatorWindow(managesWindow: false);
      var closed = false;
      var dragged = false;
      await tester.pumpWidget(
        EmulatorApp(
          window: window,
          rig: rig,
          onClose: () => closed = true,
          onDrag: () => dragged = true,
        ),
      );
      await tester.pumpAndSettle();

      Future<void> tapControl(IconData icon) async {
        await tester.tap(find.byIcon(icon).last);
        await tester.pumpAndSettle();
      }

      final strip = find.byKey(const ValueKey('emulator-control-strip'));
      expect(
        find.descendant(of: strip, matching: find.byIcon(LucideIcons.power)),
        findsNothing,
      );
      final stripSize = tester.getSize(strip);
      expect(stripSize.width, 54);
      final frame = find.byKey(const ValueKey('emulator-player-frame'));
      expect(
        tester.getTopLeft(strip).dy,
        closeTo(tester.getTopLeft(frame).dy, .01),
      );
      final chargingIcon = find.byIcon(LucideIcons.batteryCharging);
      expect(tester.getSize(chargingIcon), const Size(20, 20));
      expect(stripSize.height, lessThan(560));
      await tapControl(LucideIcons.gripHorizontal);
      expect(dragged, isTrue);

      final charging = rig.battery.value.charging;
      await tapControl(LucideIcons.batteryCharging);
      expect(rig.battery.value.charging, !charging);
      await tapControl(LucideIcons.batteryCharging);
      expect(rig.battery.value.charging, charging);

      rig.setWifi(WifiStatus.off);
      await tester.pump();
      await tapControl(LucideIcons.wifi);
      expect(rig.wifi.value.status, WifiStatus.connected);
      await tapControl(LucideIcons.wifi);
      expect(rig.wifi.value.status, WifiStatus.off);

      rig.setBluetooth(BluetoothStatus.off);
      await tester.pump();
      await tapControl(LucideIcons.bluetooth);
      expect(rig.bluetooth.value.status, BluetoothStatus.connected);
      await tapControl(LucideIcons.bluetooth);
      expect(rig.bluetooth.value.status, BluetoothStatus.off);

      final inserted = rig.cardInserted;
      await tapControl(LucideIcons.hardDrive);
      expect(rig.cardInserted, !inserted);
      await tapControl(LucideIcons.hardDrive);
      expect(rig.cardInserted, inserted);

      await tapControl(LucideIcons.plus);
      expect(window.zoom, 2.5);
      await tapControl(LucideIcons.minus);
      expect(window.zoom, 2);
      await tapControl(LucideIcons.ellipsis);
      expect(find.text('Restart emulator'), findsOneWidget);
      await tester.tap(find.text('Dock emulator'));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await rig.cardSettled;
      rig.dispose();
      window.dispose();
    },
  );
}
