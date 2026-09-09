import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:toolbox_core/a2dp_capture.dart';
import 'package:test/test.dart';

class FakeCapture extends CaptureCommands {
  final calls = <List<String>>[];
  final done = Completer<int>();
  final started = Completer<void>();
  bool sinkExists = true, missingTool = false, transientInputFailure = false;
  int inputReads = 0;
  List<String>? recorded;
  @override
  Future<ProcessResult> capture(String executable, List<String> args) async {
    calls.add([executable, ...args]);
    if (missingTool) throw ProcessException(executable, args, 'missing');
    Object body = '';
    if (args.contains('sinks'))
      body = sinkExists
          ? [
              {'name': 'bt_diag', 'index': 17},
            ]
          : [];
    if (args.first == 'load-module') {
      sinkExists = true;
      body = '99';
    }
    if (args.contains('sink-inputs')) {
      inputReads++;
      if (transientInputFailure && inputReads == 1)
        return ProcessResult(1, 1, '', 'temporary failure');
      body = [
        {
          'index': 3,
          'sink': 1,
          'properties': {'api.bluez5.address': 'AA:BB:CC:DD:EE:FF'},
        },
        {
          'index': 4,
          'sink': 17,
          'properties': {'api.bluez5.address': 'aa:bb:cc:dd:ee:ff'},
        },
        {
          'index': 5,
          'sink': 1,
          'properties': {'api.bluez5.address': '00:11:22:33:44:55'},
        },
        {'index': 6, 'sink': 1, 'properties': {}},
      ];
    }
    return ProcessResult(1, 0, body is String ? body : jsonEncode(body), '');
  }

  @override
  Future<int> record(List<String> args) async {
    recorded = args;
    started.complete();
    return done.future;
  }

  @override
  Future<void> cancel() async {
    if (!done.isCompleted) done.complete(-2);
  }
}

void main() {
  late Directory directory;
  late FakeCapture host;
  late A2dpCapture session;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('a2dp-capture-test');
    host = FakeCapture();
    session = A2dpCapture(
      commands: host,
      log: (_) {},
      routePeriod: const Duration(milliseconds: 1),
      now: () => DateTime.utc(2026, 9, 8, 12, 30),
    );
  });
  tearDown(() => directory.deleteSync(recursive: true));
  Future<void> until(bool Function() ready) async {
    for (var i = 0; i < 100; i++) {
      if (ready()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('router did not run');
  }

  Future<int> run() =>
      session.run(peer: 'aa:bb:cc:dd:ee:ff', outputDirectory: directory.path);
  test(
    'reuses sink and moves only selected peer streams not already routed',
    () async {
      final result = run();
      await host.started.future;
      await until(() => host.calls.any((c) => c.contains('move-sink-input')));
      host.done.complete(7);
      expect(await result, 7);
      expect(host.calls.where((c) => c.contains('load-module')), isEmpty);
      expect(
        host.calls
            .where((c) => c.contains('move-sink-input'))
            .every((c) => c[2] == '3' && c[3] == 'bt_diag'),
        true,
      );
      expect(host.recorded!.take(8), [
        '--target',
        '17',
        '--rate',
        '48000',
        '--channels',
        '2',
        '--format',
        's16',
      ]);
      final meta = directory
          .listSync()
          .whereType<File>()
          .singleWhere((f) => f.path.endsWith('.meta'))
          .readAsStringSync();
      expect(
        meta,
        contains(
          'peer_address=aa:bb:cc:dd:ee:ff\nsink_name=bt_diag\nsink_index=17\nsample_rate=48000\nchannels=2\nsample_format=s16\n',
        ),
      );
      expect(meta, contains('capture_started_at='));
      expect(meta, contains('capture_stopped_at='));
    },
  );
  test(
    'creates the matching silent stereo sink and cancellation finalizes metadata',
    () async {
      host.sinkExists = false;
      final result = run();
      await host.started.future;
      await session.cancel();
      expect(await result, 130);
      expect(
        host.calls.singleWhere((c) => c.contains('load-module')),
        containsAll([
          'module-null-sink',
          'sink_name=bt_diag',
          'rate=48000',
          'channels=2',
          'channel_map=front-left,front-right',
        ]),
      );
      expect(host.calls.where((c) => c.contains('unload-module')), isEmpty);
      expect(
        directory.listSync().whereType<File>().single.readAsStringSync(),
        contains('capture_stopped_at='),
      );
    },
  );
  test('router recovers from transient host enumeration failure', () async {
    host.transientInputFailure = true;
    final result = run();
    await host.started.future;
    await until(() => host.calls.any((c) => c.contains('move-sink-input')));
    await session.cancel();
    await result;
    expect(host.inputReads, greaterThanOrEqualTo(2));
  });
  test(
    'invalid peer and missing dependencies do not start recording',
    () async {
      await expectLater(session.run(peer: 'not-a-mac'), throwsArgumentError);
      expect(host.calls, isEmpty);
      session = A2dpCapture(commands: host, log: (_) {});
      host.missingTool = true;
      await expectLater(run(), throwsStateError);
      expect(host.recorded, isNull);
    },
  );
  test('recording failure still writes stop time and stops routing', () async {
    final result = run();
    await host.started.future;
    final expected = expectLater(result, throwsStateError);
    host.done.completeError(StateError('recorder crashed'));
    await expected;
    expect(
      directory.listSync().whereType<File>().single.readAsStringSync(),
      contains('capture_stopped_at='),
    );
    final count = host.calls.length;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(host.calls.length, count);
  });
}
