import 'dart:async';
import 'package:tempo_toolbox/emulator/src/event_log.dart';
import 'package:tempo_logger/tempo_logger.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_toolbox/engine_native.dart';
import 'package:tempo_toolbox/toolbox_controller.dart';
import 'package:tempo_usb/tempo_usb.dart' show DeviceSetup;

class FakeUsbEngine extends UsbEngine {
  int connections = 0;
  late void Function(Map<String, dynamic>) onEvent;
  @override
  Future<Map<String, dynamic>> initialize(
    void Function(Map<String, dynamic>) callback,
  ) async {
    onEvent = callback;
    return {'supported': true, 'message': 'Ready'};
  }

  @override
  Future<Map<String, dynamic>> prepareRestore({
    bool legacy = false,
    String? path,
  }) async => {'ready': true, 'filename': 'backup.img.gz'};
  @override
  Future<Map<String, dynamic>> prepareFirmware() async => {
    'ready': true,
    'firmware': {'name': 'Tempo', 'version': 'test'},
    'includes_preloader': false,
    'images': 2,
    'writes': 2,
    'bytes': 1024,
  };
  @override
  Future<void> choose({
    bool backup = false,
    bool flash = false,
    bool allowPreloader = false,
    bool resume = false,
  }) async {
    connections++;
    onEvent({'event': 'waiting', 'message': 'Waiting for test device'});
  }

  @override
  Future<void> stop() async {}
}

class DeferredStopEngine extends FakeUsbEngine {
  final cleanup = Completer<void>();
  int stops = 0;
  @override
  Future<void> stop() {
    stops++;
    return cleanup.future;
  }
}

class FailingFirmwareEngine extends FakeUsbEngine {
  @override
  Future<Map<String, dynamic>> prepareFirmware() async => {
    'ready': false,
    'message': 'Disk quota exceeded',
  };
}

void main() {
  test('reboot defaults on and cannot change during an operation', () async {
    final model = ToolboxController(engine: FakeUsbEngine());
    await Future<void>.delayed(Duration.zero);
    expect(model.rebootAfterSuccess, isTrue);
    model.setRebootAfterSuccess(false);
    expect(model.rebootAfterSuccess, isFalse);
    model.busy = true;
    model.setRebootAfterSuccess(true);
    expect(model.rebootAfterSuccess, isFalse);
    model.dispose();
  });

  test('package preparation errors enter global logs', () async {
    final history = EmulatorEventLog();
    final model = ToolboxController(
      engine: FailingFirmwareEngine(),
      log: history,
    );
    await Future<void>.delayed(Duration.zero);
    await model.prepareFirmware();
    expect(model.busy, isFalse);
    expect(model.firmwareReady, isFalse);
    expect(model.status, 'Disk quota exceeded');
    expect(history.entries.last.level, LogLevel.error);
    expect(history.entries.last.tag, 'flasher');
    expect(history.entries.last.message, 'Disk quota exceeded');
    model.dispose();
    history.dispose();
  });

  test(
    'preparation progress stays labeled and waiting clears its counters',
    () async {
      final model = ToolboxController(engine: FakeUsbEngine());
      await model.initialize();
      model.event({
        'event': 'firmware-prepare-started',
        'message': 'Extracting and verifying firmware package…',
      });
      model.event({
        'event': 'firmware-prepare-progress',
        'completed': 50,
        'total': 100,
      });
      expect(model.status, 'Extracting and verifying firmware package…');
      expect(model.firmwareReady, isFalse);
      expect(model.backupCompleted, 50);
      model.event({
        'event': 'waiting',
        'message': 'Waiting for Tempo Recovery…',
      });
      expect(model.status, 'Waiting for Tempo Recovery…');
      expect(model.backupCompleted, isNull);
      expect(model.backupTotal, isNull);
      model.dispose();
    },
  );

  test(
    'recovery is default and transfer method cannot change while busy',
    () async {
      final engine = FakeUsbEngine();
      final model = ToolboxController(engine: engine);
      addTearDown(model.dispose);
      await Future<void>.delayed(Duration.zero);
      expect(model.useLegacyDownloadAgent, isFalse);
      model.setLegacyDownloadAgent(true);
      expect(engine.useLegacyDownloadAgent, isTrue);
      model.busy = true;
      model.setLegacyDownloadAgent(false);
      expect(model.useLegacyDownloadAgent, isTrue);
      model.busy = false;
      model.setLegacyDownloadAgent(false);
      expect(engine.useLegacyDownloadAgent, isFalse);
    },
  );

  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'stop stays busy until cleanup finishes and ignores repeated requests',
    () async {
      final engine = DeferredStopEngine();
      final model = ToolboxController(engine: engine);
      addTearDown(model.dispose);
      await Future<void>.delayed(Duration.zero);
      model.busy = true;
      final stop = model.stop();
      expect(model.stopping, isTrue);
      expect(model.busy, isTrue);
      await model.stop();
      expect(engine.stops, 1);
      model.event({'event': 'stopped', 'message': 'Draining output'});
      expect(model.busy, isTrue);
      engine.cleanup.complete();
      await stop;
      expect(model.stopping, isFalse);
      expect(model.busy, isFalse);
    },
  );

  test(
    'operation events reach global Logs with their source and metadata',
    () async {
      final history = EmulatorEventLog();
      final model = ToolboxController(engine: FakeUsbEngine(), log: history);
      addTearDown(model.dispose);
      addTearDown(history.dispose);
      await Future<void>.delayed(Duration.zero);
      for (final operation in {
        'Backup': 'backup',
        'Restore': 'restore',
        'Flash': 'flasher',
      }.entries) {
        model.selectTask(operation.key);
        model.event({
          'event': 'error',
          'message': 'Test failure',
          'offset': 42,
        });
        final record = history.entries.last;
        expect(record.tag, operation.value);
        expect(record.level, LogLevel.error);
        expect(record.message, 'Test failure');
        expect((record.metadata as Map)['offset'], 42);
        expect(record.timestamp.isUtc, isTrue);
      }
      for (final kind in [
        'firmware-prepare-progress',
        'recovery-boot-progress',
        'recovery-starting',
        'flash-progress',
        'firmware-verify-progress',
        'progress',
      ]) {
        model.event({
          'event': kind,
          'message': 'CLI event $kind',
          'completed': 12,
          'total': 40,
        });
        expect(history.entries.last.message, 'CLI event $kind');
        expect((history.entries.last.metadata as Map)['completed'], 12);
      }
      expect(history.sources, ['backup', 'flasher', 'restore']);
    },
  );

  test('device setup reaches the engine for a Recovery flash only', () async {
    final engine = FakeUsbEngine();
    final model = ToolboxController(engine: engine);
    await model.initialize();
    model.selectTask('Flash');
    await model.prepareFirmware();
    model.setDeviceSetup(const DeviceSetup(hostname: 'y2'));
    expect(model.deviceSetupAvailable, isTrue);
    model.setDeviceSetup(const DeviceSetup(hostname: '-y2'));
    await model.start();
    expect(engine.connections, 0);
    expect(model.phase, 'error');
    expect(model.status, contains('device name'));
    model.setDeviceSetup(const DeviceSetup(hostname: 'y2'));
    await model.start();
    expect(engine.connections, 1);
    expect(engine.deviceSetup?.hostname, 'y2');
    model.event({
      'event': 'result',
      'report': {'storage_written': true},
    });
    model.setLegacyDownloadAgent(true);
    expect(model.deviceSetupAvailable, isFalse);
    await model.start();
    expect(engine.connections, 2);
    expect(engine.deviceSetup, isNull);
    model.dispose();
  });

  test(
    'changing restore to flash invalidates the old preparation and write permission',
    () async {
      final engine = FakeUsbEngine();
      final model = ToolboxController(engine: engine);
      await Future<void>.delayed(Duration.zero);
      await model.prepareRestore();
      expect(model.task, 'Restore');
      expect(model.firmwareReady, isTrue);
      model.setPreloaderFlashing(true);
      model.selectTask('Flash');
      expect(model.firmwareReady, isFalse);
      expect(model.firmware, isNull);
      expect(model.allowPreloaderFlash, isFalse);
      await model.start();
      expect(engine.connections, 0);
      await model.prepareFirmware();
      await model.start();
      expect(engine.connections, 1);
      expect(model.busy, isTrue);
      model.selectTask('Backup');
      expect(model.task, 'Flash');
      await model.stop();
      expect(model.busy, isFalse);
      expect(model.events.last['event'], 'stopped');
      model.dispose();
    },
  );
}
