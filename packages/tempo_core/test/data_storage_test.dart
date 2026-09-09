import 'package:flutter_test/flutter_test.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:file/memory.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

class FakeStorage extends ValueNotifier<DataStorageStatus>
    implements DataStorageController {
  FakeStorage([
    super.value = const DataStorageStatus(
      cardPresent: true,
      cardProfileExists: true,
    ),
  ]);
  @override
  Future<void> Function()? beforeChange;
  final calls = <String>[];
  bool fail = false;
  @override
  Future<void> setPolicy(
    DataStoragePolicy policy, {
    bool replaceExisting = false,
    bool adoptExisting = false,
  }) async {
    calls.add('${policy.name}:$replaceExisting:$adoptExisting');
    if (fail) throw StateError('Card is read-only');
    value = DataStorageStatus(
      policy: policy,
      cardPresent: true,
      usingCard: policy == DataStoragePolicy.yes,
    );
  }

  @override
  Future<void> adoptCardForStartup() async {
    calls.add('adopt');
    if (fail) throw StateError('Card is read-only');
  }

  @override
  void skipStartup() => calls.add('skip');
}

void main() {
  testWidgets('startup waits for an authoritative snapshot and prompts once', (
    tester,
  ) async {
    final storage = FakeStorage(const DataStorageStatus(available: false));
    final services = PlayerServices(
      battery: ValueNotifier(const BatteryReading(percent: 50)),
      wifi: ValueNotifier(WifiReading.off),
      bluetooth: ValueNotifier(BluetoothReading.off),
      storage: ValueNotifier(const StorageReading()),
      places: ValueNotifier(
        Places(fileSystem: MemoryFileSystem(), home: '/home/tempo'),
      ),
      screen: ScreenSwitch(),
      volume: VolumeSwitch(),
      output: OutputSwitch(),
      feedback: FeedbackSwitch(),
      dataStorage: storage,
    );
    await tester.pumpWidget(
      TempoApp(
        settings: Settings(tree: playerSettingsTree),
        services: services,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Use SD card data?'), findsNothing);
    storage.value = const DataStorageStatus(
      cardPresent: true,
      cardProfileExists: true,
    );
    await tester.pumpAndSettle();
    expect(find.text('Use SD card data?'), findsOneWidget);
    await tester.tap(find.text('No'));
    await tester.pumpAndSettle();
    storage.value = const DataStorageStatus(
      cardPresent: true,
      cardProfileExists: true,
    );
    await tester.pumpAndSettle();
    expect(find.text('Use SD card data?'), findsNothing);
    expect(storage.calls, ['skip']);
    await tester.pumpWidget(const SizedBox());
    storage.value = const DataStorageStatus();
    await tester.pumpWidget(
      TempoApp(
        settings: Settings(tree: playerSettingsTree),
        services: services,
      ),
    );
    await tester.pumpAndSettle();
    storage.value = const DataStorageStatus(
      cardPresent: true,
      cardProfileExists: true,
    );
    await tester.pumpAndSettle();
    expect(find.text('Use SD card data?'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    storage.value = const DataStorageStatus(
      cardPresent: true,
      cardProfileExists: true,
      promptAvailable: false,
    );
    await tester.pumpWidget(
      TempoApp(
        settings: Settings(tree: playerSettingsTree),
        services: services,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Use SD card data?'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('unavailable profile permits recovery to device', (tester) async {
    final storage = FakeStorage(const DataStorageStatus(available: false));
    await tester.pumpWidget(DataStorageRecoveryApp(controller: storage));
    await tester.pumpAndSettle();
    await tester.tap(find.text('No'));
    await tester.pumpAndSettle();
    expect(storage.calls, ['no:false:false']);
  });
  testWidgets('wheel can decline startup and restart blocks changes', (
    tester,
  ) async {
    final storage = FakeStorage();
    final wheel = ClickWheelController();
    await tester.pumpWidget(
      TomeApp(
        home: ClickWheelInput(
          controller: wheel,
          child: DataStorageChoices(controller: storage, startup: true),
        ),
      ),
    );
    await tester.pumpAndSettle();
    wheel.jog(1);
    await tester.pump();
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    expect(storage.calls, ['skip']);
    storage.value = const DataStorageStatus(
      cardPresent: true,
      restarting: true,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yes'));
    await tester.pumpAndSettle();
    expect(storage.calls, ['skip']);
  });
  test(
    'storage flush waits for remote success and pause stops stale writes',
    () async {
      final settings = Settings(tree: playerSettingsTree);
      final writes = <Map<String, Object?>>[];
      var fail = true;
      final file = SettingsFile(
        settings: settings,
        file: MemoryFileSystem().file('/settings.json'),
        writeRemote: (value) async {
          if (fail) throw StateError('offline');
          writes.add(value);
        },
      );
      await expectLater(file.flushForStorageChange(), throwsStateError);
      fail = false;
      await file.flushForStorageChange();
      await file.save();
      file.saveSync();
      expect(writes, hasLength(1));
      file.watch();
      await file.save();
      expect(writes, hasLength(2));
      file.dispose();
    },
  );
  Future<void> show(
    WidgetTester tester,
    FakeStorage storage, {
    bool startup = false,
    VoidCallback? done,
  }) async {
    tester.view.physicalSize = const Size(480, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      TomeApp(
        home: DataStorageChoices(
          controller: storage,
          startup: startup,
          onDone: done,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final entry in {
    'Yes': 'adopt',
    'No': 'skip',
    'Don’t Ask Again': 'no:false:false',
  }.entries) {
    testWidgets('startup ${entry.key} dispatches only its intended action', (
      tester,
    ) async {
      final storage = FakeStorage();
      var finished = false;
      await show(tester, storage, startup: true, done: () => finished = true);
      await tester.tap(find.text(entry.key));
      await tester.pumpAndSettle();
      expect(storage.calls, [entry.value]);
      expect(finished, true);
      if (entry.key == 'No') {
        expect(storage.value.policy, DataStoragePolicy.ask);
      }
    });
  }
  testWidgets('picker updates policy without ordinary Settings persistence', (
    tester,
  ) async {
    final storage = FakeStorage(const DataStorageStatus(cardPresent: true));
    await show(tester, storage);
    await tester.tap(find.text('Yes'));
    await tester.pumpAndSettle();
    expect(find.text('Current choice: Yes'), findsOneWidget);
    await tester.tap(find.text('Ask'));
    await tester.pumpAndSettle();
    expect(storage.value.policy, DataStoragePolicy.ask);
  });
  testWidgets(
    'missing card disables Yes and failure preserves startup dialog',
    (tester) async {
      final storage = FakeStorage(const DataStorageStatus());
      await show(tester, storage, startup: true);
      await tester.tap(find.text('Yes'));
      expect(storage.calls, isEmpty);
      storage.value = const DataStorageStatus(
        cardPresent: true,
        cardProfileExists: true,
      );
      storage.fail = true;
      await tester.pumpAndSettle();
      await tester.tap(find.text('Yes'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Card is read-only'), findsOneWidget);
      expect(find.text('No'), findsOneWidget);
    },
  );
  testWidgets(
    'existing destination requires explicit adoption or replacement',
    (tester) async {
      final storage = FakeStorage();
      await show(tester, storage);
      await tester.tap(find.text('Yes'));
      await tester.pumpAndSettle();
      expect(storage.calls, isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(storage.calls, isEmpty);
      await tester.tap(find.text('Yes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use existing'));
      await tester.pumpAndSettle();
      expect(storage.calls, ['yes:false:true']);
      storage.value = const DataStorageStatus(
        cardPresent: true,
        usingCard: true,
        deviceProfileExists: true,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('No'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.text('Move current data'),
      );
      await tester.pumpAndSettle();
      expect(storage.calls.last, 'no:true:false');
      storage.value = const DataStorageStatus(
        usingCard: true,
        deviceProfileExists: true,
        available: false,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ask'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.text('Move current data'),
      );
      await tester.pumpAndSettle();
      expect(storage.calls.last, 'no:true:false');
      await tester.tap(find.text('Use existing'));
      await tester.pumpAndSettle();
      expect(storage.calls.last, 'ask:false:true');
    },
  );
}
