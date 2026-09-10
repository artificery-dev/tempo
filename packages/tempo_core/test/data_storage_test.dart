import 'package:flutter_test/flutter_test.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:file/memory.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

class FakeStorage extends ValueNotifier<DataStorageStatus>
    implements DataStorageController, RetryableDataStorage {
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
  @override
  Future<void> retryPending() async {
    calls.add('retry');
  }
}

void main() {
  testWidgets(
    'interrupted move offers retry without choosing a different store',
    (tester) async {
      final storage = FakeStorage(
        const DataStorageStatus(
          available: false,
          restarting: true,
          error: 'Move interrupted',
        ),
      );
      await tester.pumpWidget(DataStorageRecoveryApp(controller: storage));
      await tester.pumpAndSettle();
      expect(find.text('Internal'), findsNothing);
      expect(find.text('External'), findsNothing);
      await tester.tap(find.text('Retry move'));
      await tester.pumpAndSettle();
      expect(storage.calls, ['retry']);
    },
  );
  testWidgets('startup waits for an authoritative snapshot and prompts once', (
    tester,
  ) async {
    final storage = FakeStorage(const DataStorageStatus(available: false));
    final wheel = ClickWheelController();
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
        wheel: wheel,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('SD Card Inserted'), findsNothing);
    storage.value = const DataStorageStatus(
      cardPresent: true,
      cardProfileExists: true,
    );
    await tester.pumpAndSettle();
    expect(find.text('SD Card Inserted'), findsOneWidget);
    expect(
      find.textContaining('already contains a media library'),
      findsOneWidget,
    );
    wheel.jog(1);
    await tester.pump();
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    storage.value = const DataStorageStatus(
      cardPresent: true,
      cardProfileExists: true,
    );
    await tester.pumpAndSettle();
    expect(find.text('SD Card Inserted'), findsNothing);
    expect(storage.calls, ['no:false:false']);
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
      policy: DataStoragePolicy.no,
      cardPresent: true,
      cardProfileExists: true,
    );
    await tester.pumpAndSettle();
    expect(find.text('SD Card Inserted'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    storage.value = const DataStorageStatus(
      policy: DataStoragePolicy.no,
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
    expect(find.text('SD Card Inserted'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('unavailable profile permits recovery to device', (tester) async {
    final storage = FakeStorage(const DataStorageStatus(available: false));
    await tester.pumpWidget(DataStorageRecoveryApp(controller: storage));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Internal'));
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
          child: DataStoragePrompt(controller: storage),
        ),
      ),
    );
    await tester.pumpAndSettle();
    wheel.jog(1);
    await tester.pump();
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    expect(storage.calls, ['no:false:false']);
    storage.value = const DataStorageStatus(
      cardPresent: true,
      restarting: true,
    );
    await tester.pumpAndSettle();
    wheel.jog(-1);
    await tester.pump();
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    expect(storage.calls, ['no:false:false']);
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
  Future<void> show(WidgetTester tester, FakeStorage storage) async {
    tester.view.physicalSize = const Size(480, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      TomeApp(home: DataStorageChoices(controller: storage)),
    );
    await tester.pumpAndSettle();
  }

  /// The card prompt on the player's own screen, driven by the wheel.
  Future<ClickWheelController> showPrompt(
    WidgetTester tester,
    FakeStorage storage, {
    VoidCallback? done,
  }) async {
    tester.view.physicalSize = const Size(480, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final wheel = ClickWheelController();
    await tester.pumpWidget(
      TomeApp(
        theme: UiScale.regular.theme(Brightness.dark),
        home: ClickWheelInput(
          controller: wheel,
          child: DataStoragePrompt(controller: storage, onDone: done),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return wheel;
  }

  for (final entry in {
    'Use card': (0, 'yes:false:true'),
    'Use device': (1, 'no:false:false'),
  }.entries) {
    testWidgets(
      'card prompt ${entry.key} dispatches only its intended action',
      (tester) async {
        final storage = FakeStorage();
        var finished = false;
        final wheel = await showPrompt(
          tester,
          storage,
          done: () => finished = true,
        );
        expect(find.text('SD Card Inserted'), findsOneWidget);
        expect(find.text(entry.key), findsOneWidget);
        wheel.jog(entry.value.$1);
        await tester.pump();
        wheel.press(WheelButton.select);
        await tester.pumpAndSettle();
        expect(storage.calls, [entry.value.$2]);
        expect(finished, true);
        expect(tester.takeException(), isNull);
        if (entry.value.$1 == 1) {
          expect(storage.value.policy, DataStoragePolicy.no);
        }
      },
    );
  }
  testWidgets(
    'external location requires confirmation and cancel keeps Internal',
    (tester) async {
      final storage = FakeStorage(
        const DataStorageStatus(
          policy: DataStoragePolicy.no,
          cardPresent: true,
        ),
      );
      await show(tester, storage);
      await tester.tap(find.text('External'));
      await tester.pumpAndSettle();
      expect(storage.calls, isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(storage.value.policy, DataStoragePolicy.no);
      await tester.tap(find.text('External'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move data'));
      await tester.pumpAndSettle();
      expect(storage.calls, ['yes:false:false']);
      expect(find.text('Preferred: External'), findsOneWidget);
    },
  );
  testWidgets(
    'missing card disables Use card and failure preserves the prompt',
    (tester) async {
      final storage = FakeStorage(const DataStorageStatus());
      final wheel = await showPrompt(tester, storage);
      wheel.press(WheelButton.select);
      await tester.pumpAndSettle();
      expect(storage.calls, isEmpty);
      storage.value = const DataStorageStatus(
        cardPresent: true,
        cardProfileExists: true,
      );
      storage.fail = true;
      await tester.pumpAndSettle();
      wheel.press(WheelButton.select);
      await tester.pumpAndSettle();
      expect(find.textContaining('Card is read-only'), findsOneWidget);
      expect(find.text('Use device'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'existing destination requires explicit adoption or a non-overwriting move',
    (tester) async {
      final storage = FakeStorage();
      await show(tester, storage);
      await tester.tap(find.text('External'));
      await tester.pumpAndSettle();
      expect(storage.calls, isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(storage.calls, isEmpty);
      await tester.tap(find.text('External'));
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
      await tester.tap(find.text('Internal'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move current data'));
      await tester.pumpAndSettle();
      expect(storage.calls.last, 'no:false:false');
      storage.value = const DataStorageStatus(
        usingCard: true,
        deviceProfileExists: true,
        available: false,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Internal'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move current data'));
      await tester.pumpAndSettle();
      expect(storage.calls.last, 'no:false:false');
      await tester.tap(find.text('Use existing'));
      await tester.pumpAndSettle();
      expect(storage.calls.last, 'no:false:true');
    },
  );
}
