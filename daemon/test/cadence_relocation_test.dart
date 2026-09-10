import 'dart:convert';
import 'dart:io';

import 'package:tempod/src/services/cadence_relocation.dart';
import 'package:test/test.dart';

void main() {
  late Directory scratch;
  late File child;
  final move = CadenceRelocation(
    operationId: 'consent-1',
    datastoreId: 'library-1',
    source: '/home/tempo/.cadence',
    destination: '/mnt/sd/.cadence',
    destinationMountId: '42',
    mediaRoot: '/mnt/sd',
  );
  Map<String, Object?> completion() => {
    'event': 'relocation-complete',
    'operationId': move.operationId,
    'state': 'done',
    'datastoreId': move.datastoreId,
    'store': move.destination,
    'storageKind': 'portable',
    'resolvedMediaRoot': '/mnt/sd',
    'sourceRetired': true,
    'sourceRetained': true,
    'libraries': [
      {'id': 1, 'uuid': 'music'},
    ],
  };
  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('relocation-launcher-');
    child = File('${scratch.path}/child.dart');
    await child.writeAsString('''
import 'dart:io';
void main(List<String> args) {
  stdout.write(args[0]);
  stderr.writeln('child diagnostics');
  exitCode = int.parse(args[1]);
}
''');
  });
  tearDown(() => scratch.delete(recursive: true));
  Future<Map<String, Object?>> run(
    List<Map<String, Object?>> events, {
    int code = 0,
  }) => move.run(
    user: 'tempo',
    gid: 1000,
    event: (_) {},
    log: (_) {},
    start: (args) {
      expect(args, containsAllInOrder(['--destination-mount-id', '42']));
      return Process.start(Platform.resolvedExecutable, [
        child.path,
        '${events.map(jsonEncode).join('\n')}\n',
        '$code',
      ]);
    },
  );
  test('persisted move retains consent, store and mount identities', () {
    expect(CadenceRelocation.fromJson(move.toJson()).arguments, move.arguments);
    expect(move.arguments, isNot(contains('--source-mount-id')));
  });
  test(
    'acknowledges only complete result and successful process exit',
    () async {
      final result = await run([
        {
          'event': 'relocation-progress',
          'operationId': move.operationId,
          'phase': 'activated',
        },
        completion(),
      ]);
      expect(result['libraries'], [
        {'id': 1, 'uuid': 'music'},
      ]);
    },
  );
  test('activated progress cannot substitute for completion', () async {
    await expectLater(
      run([
        {
          'event': 'relocation-progress',
          'operationId': move.operationId,
          'phase': 'activated',
        },
      ]),
      throwsStateError,
    );
  });
  test(
    'nonzero exit keeps move pending even after a completion event',
    () async {
      await expectLater(run([completion()], code: 75), throwsStateError);
    },
  );
  test(
    'rejects wrong store, operation, datastore and retargeted media',
    () async {
      for (final change in [
        {'store': '/other/.cadence'},
        {'operationId': 'other'},
        {'datastoreId': 'other'},
        {'resolvedMediaRoot': '/home/tempo'},
        {'sourceRetired': false},
        {'storageKind': 'local'},
      ]) {
        await expectLater(
          run([
            {...completion(), ...change},
          ]),
          throwsStateError,
        );
      }
    },
  );
  test('error event cannot be overridden by success or exit zero', () async {
    await expectLater(
      run([
        {
          'event': 'relocation-error',
          'operationId': move.operationId,
          'error': {'code': 'relocation_conflict'},
        },
        completion(),
      ]),
      throwsStateError,
    );
  });
  test(
    'cancel safety requires an explicit backend rejection and failed exit',
    () async {
      final error = {
        'event': 'relocation-error',
        'operationId': move.operationId,
        'error': {'code': 'destination_exists'},
        'cancelSafe': true,
        'retryWithSameOperationId': false,
      };
      await expectLater(
        run([error], code: 75),
        throwsA(
          isA<CadenceRelocationFailure>().having(
            (e) => e.cancelSafe,
            'cancelSafe',
            isTrue,
          ),
        ),
      );
      for (final events in [
        [
          {...error, 'cancelSafe': false},
        ],
        [
          {...error, 'retryWithSameOperationId': true},
        ],
        [
          {...error, 'operationId': 'different'},
        ],
        [error, completion()],
      ]) {
        await expectLater(
          run(events, code: 75),
          throwsA(
            isA<CadenceRelocationFailure>().having(
              (e) => e.cancelSafe,
              'cancelSafe',
              isFalse,
            ),
          ),
        );
      }
    },
  );
}
