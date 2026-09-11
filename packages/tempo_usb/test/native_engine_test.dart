import 'dart:async';
import 'dart:io';

import 'package:tempo_usb/tempo_usb.dart';
import 'package:test/test.dart';

void main() {
  final fixture = File('test/fixtures/native_helper.dart').absolute.path;
  late Directory directory;
  late File marker;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tempo-native-cancel-');
    marker = File('${directory.path}/cleanup');
  });
  tearDown(() => directory.delete(recursive: true));
  // The helpers here are real Dart processes, so a machine running several
  // jobs at once can be slow to start, signal and reap them. Both graces
  // match the engine's own defaults rather than cutting them fine: each wait
  // ends the moment the process does, so escalation still proceeds in order.
  NativeUsbEngine engine({
    Duration grace = const Duration(seconds: 30),
    Future<Process> Function(String, List<String>)? start,
  }) => NativeUsbEngine(
    executable: Platform.resolvedExecutable,
    cancellationGrace: grace,
    terminationGrace: const Duration(seconds: 15),
    // The fixtures pad megabytes through both pipes before their terminal
    // line, and that padding is what a loaded machine is slowest to deliver.
    drainGrace: const Duration(seconds: 30),
    startProcess: start,
  );

  test(
    'stop drains both pipes and holds operation until cooperative cleanup',
    () async {
      final usb = engine();
      addTearDown(usb.stop);
      final ready = Completer<void>();
      final events = <EngineEvent>[];
      final operation = usb.run(
        [fixture, 'cooperative', marker.path],
        onEvent: (event) {
          events.add(event);
          if (event['event'] == 'ready') ready.complete();
        },
      );
      await ready.future.timeout(const Duration(seconds: 10));
      final stopped = usb.stop();
      final stoppedAgain = usb.stop();
      await expectLater(
        usb.run([fixture, 'result', marker.path], onEvent: (_) {}),
        throwsStateError,
      );
      await stopped.timeout(const Duration(seconds: 60));
      await stoppedAgain;
      expect(await marker.readAsString(), 'cancel cleanup complete');
      expect(await operation, {'event': 'cancelled'});
      expect(events.map((event) => event['event']), ['ready']);
      expect(
        (await usb.run([
          fixture,
          'result',
          marker.path,
        ], onEvent: (_) {}))['event'],
        'result',
      );
    },
  );

  test(
    'cancelled result retains late helper cleanup error without progress',
    () async {
      final usb = engine();
      addTearDown(usb.stop);
      final ready = Completer<void>();
      final events = <EngineEvent>[];
      final operation = usb.run(
        [fixture, 'cleanup-error', marker.path],
        onEvent: (event) {
          events.add(event);
          if (event['event'] == 'ready') ready.complete();
        },
      );
      await ready.future.timeout(const Duration(seconds: 10));
      await usb.stop();
      final result = await operation;
      expect(result['event'], 'cancelled');
      expect(result['message'], contains('could not be reset'));
      expect(result['message'], contains('reconnect or reset'));
      expect(events.map((event) => event['event']), ['ready']);
    },
  );

  test(
    'stop during delayed process start waits for cleanup before reuse',
    () async {
      final release = Completer<void>();
      var starts = 0;
      final usb = engine(
        start: (name, args) async {
          if (starts++ == 0) await release.future;
          return Process.start(name, args);
        },
      );
      addTearDown(usb.stop);
      final operation = usb.run([
        fixture,
        'cooperative',
        marker.path,
      ], onEvent: (_) {});
      var stopFinished = false;
      final stopped = usb.stop().then((_) => stopFinished = true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(stopFinished, false);
      await expectLater(
        usb.run([fixture, 'result', marker.path], onEvent: (_) {}),
        throwsStateError,
      );
      release.complete();
      await stopped.timeout(const Duration(seconds: 60));
      expect(await operation, {'event': 'cancelled'});
      expect(await marker.readAsString(), 'cancel cleanup complete');
      expect(
        (await usb.run([
          fixture,
          'result',
          marker.path,
        ], onEvent: (_) {}))['event'],
        'result',
      );
    },
  );

  test(
    'failed process start releases a pending stop and operation slot',
    () async {
      final release = Completer<void>();
      var starts = 0;
      final usb = engine(
        start: (name, args) async {
          if (starts++ == 0) {
            await release.future;
            throw ProcessException(name, args, 'fixture failure');
          }
          return Process.start(name, args);
        },
      );
      final operation = usb.run([
        fixture,
        'cooperative',
        marker.path,
      ], onEvent: (_) {});
      final failed = expectLater(operation, throwsA(isA<ProcessException>()));
      final stopped = usb.stop();
      release.complete();
      await failed;
      await stopped.timeout(const Duration(seconds: 60));
      expect(
        (await usb.run([
          fixture,
          'result',
          marker.path,
        ], onEvent: (_) {}))['event'],
        'result',
      );
    },
  );

  test('broken helper escalates and is reaped before next operation', () async {
    final usb = engine(grace: const Duration(milliseconds: 100));
    addTearDown(usb.stop);
    final ready = Completer<void>();
    final operation = usb.run([
      fixture,
      'broken',
      marker.path,
    ], onEvent: (_) => ready.complete());
    await ready.future.timeout(const Duration(seconds: 10));
    await usb.stop().timeout(const Duration(seconds: 30));
    expect(await operation, {'event': 'cancelled'});
    expect(marker.existsSync(), false);
    expect(
      (await usb.run([
        fixture,
        'result',
        marker.path,
      ], onEvent: (_) {}))['event'],
      'result',
    );
  });

  test(
    'legacy Unix helper can finish cleanup on signal fallback',
    () async {
      final usb = engine(grace: const Duration(milliseconds: 100));
      addTearDown(usb.stop);
      final ready = Completer<void>();
      final operation = usb.run([
        fixture,
        'legacy',
        marker.path,
      ], onEvent: (_) => ready.complete());
      await ready.future.timeout(const Duration(seconds: 10));
      await usb.stop().timeout(const Duration(seconds: 30));
      expect(await operation, {'event': 'cancelled'});
      expect(await marker.readAsString(), 'legacy cleanup');
    },
    skip: Platform.isWindows ? 'Unix signal compatibility' : false,
  );

  for (final mode in ['malformed', 'callback']) {
    test(
      '$mode failure cooperatively cleans up and releases operation',
      () async {
        final usb = engine();
        addTearDown(usb.stop);
        final operation = usb.run(
          [fixture, mode, marker.path],
          onEvent: (_) {
            if (mode == 'callback') throw FormatException('callback fixture');
          },
        );
        await expectLater(operation, throwsA(isA<FormatException>()));
        expect(await marker.readAsString(), 'cancel cleanup complete');
        expect(
          (await usb.run([
            fixture,
            'result',
            marker.path,
          ], onEvent: (_) {}))['event'],
          'result',
        );
      },
    );
  }

  test(
    'offline raw inspection returns its terminal result on clean exit',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'tempo-usb-result-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final helper = File('${directory.path}/helper.dart');
      await helper.writeAsString('''
void main() {
  print('{"event":"progress","completed":1,"total":1}');
  print('{"event":"raw-image-info","image":{"target":"logo","size":512}}');
}
''');
      final events = <EngineEvent>[];
      final engine = NativeUsbEngine(executable: Platform.resolvedExecutable);
      final result = await engine.run([helper.path], onEvent: events.add);
      expect(result['event'], 'raw-image-info');
      expect((result['image'] as Map)['target'], 'logo');
      expect(events.map((event) => event['event']), ['progress']);
    },
  );
}
