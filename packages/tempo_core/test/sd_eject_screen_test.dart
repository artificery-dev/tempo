import 'package:flutter_test/flutter_test.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tempo_core/src/settings/sd_eject_screen.dart';
import 'package:file/memory.dart';

class Maintenance extends ValueNotifier<CardMaintenanceStatus>
    implements CardMaintenanceController {
  Maintenance() : super(const CardMaintenanceStatus());
  @override
  Future<void> format() async {}
  int ejects = 0, resumes = 0;
  @override
  Future<void> eject() async {
    ejects++;
    value = const CardMaintenanceStatus(phase: CardMaintenancePhase.ejecting);
  }

  @override
  Future<void> resume() async {
    resumes++;
    value = const CardMaintenanceStatus(phase: CardMaintenancePhase.resuming);
  }
}

void main() {
  testWidgets(
    'small-screen eject stays pending and offers retry or resume on failure',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(480, 360));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final maintenance = Maintenance();
      final services = PlayerServices(
        battery: ValueNotifier(const BatteryReading(percent: 50)),
        wifi: ValueNotifier(WifiReading.off),
        bluetooth: ValueNotifier(BluetoothReading.off),
        storage: ValueNotifier(
          const StorageReading(present: true, path: '/mnt/sd'),
        ),
        places: ValueNotifier(
          Places(fileSystem: MemoryFileSystem(), home: '/home/tempo'),
        ),
        screen: ScreenSwitch(),
        volume: VolumeSwitch(),
        output: OutputSwitch(),
        feedback: FeedbackSwitch(),
        cardMaintenance: maintenance,
      );
      await tester.pumpWidget(
        TomeApp(
          home: PlayerServicesScope(
            services: services,
            child: const SdEjectScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Eject card'));
      await tester.pumpAndSettle();
      expect(maintenance.ejects, 1);
      await tester.tap(find.text('Eject card'));
      expect(maintenance.ejects, 1);
      maintenance.value = const CardMaintenanceStatus(
        phase: CardMaintenancePhase.failed,
        error: 'Card is busy',
      );
      await tester.pumpAndSettle();
      expect(find.text('Retry eject'), findsOneWidget);
      expect(find.text('Resume library'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Resume library'));
      await tester.pumpAndSettle();
      expect(maintenance.resumes, 1);
      maintenance.value = const CardMaintenanceStatus(
        phase: CardMaintenancePhase.ejected,
      );
      await tester.pumpAndSettle();
      expect(find.text('You can now remove the SD card.'), findsOneWidget);
      expect(find.text('Retry eject'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
