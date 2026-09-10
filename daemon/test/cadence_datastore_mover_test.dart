import 'package:daemon_client/daemon_client.dart';
import 'package:file/memory.dart';
import 'package:tempo_data/tempo_data.dart';
import 'package:tempod/src/services/cadence_datastore_mover.dart';
import 'package:tempod/src/services/cadence_relocation.dart';
import 'package:tempod/src/services/storage_host.dart';
import 'package:player_api/player_api.dart';
import 'package:test/test.dart';

void main() {
  late MemoryFileSystem fs;
  late DeviceSnapshot device;
  late CadenceDatastoreMover mover;
  final runs = <CadenceRelocation>[];
  bool fail = false, failAfterCommit = false, rejectSafely = false;
  TempoStorageManager manager() => TempoStorageManager(
    fs: fs,
    devicePaths: const TempoProfilePaths(
      data: '/home/tempo/.cadence',
      config: '/home/tempo/.config/tempo',
    ),
    selectorPath: '/home/tempo/.local/state/tempo/selector.json',
    cardRoot: device.cardPath,
    datastoreMover: mover,
    checkpoint: (phase) async {
      if (phase == 'request-applied' && failAfterCommit) {
        throw StateError('power interrupted');
      }
    },
  );
  setUp(() {
    fs = MemoryFileSystem();
    fs.directory('/mnt/sd').createSync(recursive: true);
    fs.directory('/home/tempo/.cadence').createSync(recursive: true);
    fs.directory('/home/tempo/.config/tempo').createSync(recursive: true);
    fs
        .file('/home/tempo/.config/tempo/settings.json')
        .writeAsStringSync('settings');
    device = const DeviceSnapshot(
      cardPath: '/mnt/sd',
      cardMountId: '40',
      cardSourceId: 'card-a',
    );
    runs.clear();
    fail = false;
    failAfterCommit = false;
    rejectSafely = false;
    mover = CadenceDatastoreMover(
      volume: () async => {
        'state': 'attached',
        'id': 'datastore-a',
        'storageKind': 'local',
        'resolvedMediaRoot': '/mnt/sd',
      },
      device: () => device,
      user: 'tempo',
      log: (_) {},
      event: (_) {},
      run: (request) async {
        runs.add(request);
        if (rejectSafely) {
          throw TempoDatastoreMoveRejected(
            'Destination contains an active library',
          );
        }
        if (fail) throw StateError('interrupted after source retirement');
        fs.directory(request.destination).createSync(recursive: true);
      },
    );
  });
  test(
    'selection only saves identity; stopped startup executes and preserves settings',
    () async {
      final prepared = await manager().prepareRequest(
        const TempoStorageRequest(policy: TempoStoragePolicy.yes),
      );
      expect(runs, isEmpty);
      expect(prepared.relocation!['datastoreId'], 'datastore-a');
      expect(fs.directory('/mnt/sd/.cadence').existsSync(), isFalse);
      final decision = await manager().applyPendingAtStartup();
      expect(decision.location, TempoStorageLocation.sd);
      expect(runs.single.operationId, prepared.id);
      expect(manager().readPendingRequest(), isNull);
      expect(
        fs.file('/home/tempo/.config/tempo/settings.json').readAsStringSync(),
        'settings',
      );
    },
  );
  test(
    'failed move cannot be cleared, replaced or bypassed; retry uses same operation',
    () async {
      final prepared = await manager().prepareRequest(
        const TempoStorageRequest(policy: TempoStoragePolicy.yes),
      );
      fail = true;
      await expectLater(manager().applyPendingAtStartup(), throwsStateError);
      expect(manager().readPendingRequest()!.started, isTrue);
      expect(manager().readSelector(), TempoStoragePolicy.ask);
      await expectLater(manager().clearPendingRequest(), throwsStateError);
      await expectLater(
        manager().setPolicy(TempoStoragePolicy.no),
        throwsStateError,
      );
      await expectLater(
        manager().prepareRequest(
          const TempoStorageRequest(
            policy: TempoStoragePolicy.no,
            adoptExisting: true,
          ),
          replacePending: true,
        ),
        throwsStateError,
      );
      fail = false;
      await manager().applyPendingAtStartup();
      expect(runs.map((r) => r.operationId), [prepared.id, prepared.id]);
    },
  );
  test(
    'failed startup exposes retry and refuses selecting another datastore',
    () async {
      final prepared = await manager().prepareRequest(
        const TempoStorageRequest(policy: TempoStoragePolicy.yes),
      );
      fail = true;
      var restarts = 0;
      final host = StorageHost(
        manager: manager,
        mediaHome: '/home/tempo',
        restart: () async {
          restarts++;
        },
        restartDelay: Duration.zero,
      );
      await host.initialize();
      expect(host.status.available, isFalse);
      expect(host.status.restartPending, isTrue);
      await expectLater(
        host.select(const StorageSelection(policy: 'no', adoptExisting: true)),
        throwsStateError,
      );
      host.retryPending();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(restarts, 1);
      expect(manager().readPendingRequest()!.id, prepared.id);
      await host.close();
      fail = false;
      final next = StorageHost(
        manager: manager,
        mediaHome: '/home/tempo',
        restart: () async {},
      );
      await next.initialize();
      expect(next.status.available, isTrue);
      expect(next.status.location, 'sd');
      await next.close();
    },
  );
  test(
    'safe backend rejection clears intent and reopens the unchanged source',
    () async {
      await manager().prepareRequest(
        const TempoStorageRequest(policy: TempoStoragePolicy.yes),
      );
      rejectSafely = true;
      final host = StorageHost(
        manager: manager,
        mediaHome: '/home/tempo',
        restart: () async {},
      );
      await host.initialize();
      expect(manager().readPendingRequest(), isNull);
      expect(host.status.available, isTrue);
      expect(host.status.location, 'device');
      expect(host.status.error, contains('active library'));
      await host.close();
    },
  );
  test('reboot reacquires mount ID for the same physical card', () async {
    await manager().prepareRequest(
      const TempoStorageRequest(policy: TempoStoragePolicy.yes),
    );
    device = const DeviceSnapshot(
      cardPath: '/mnt/sd',
      cardMountId: '91',
      cardSourceId: 'card-a',
    );
    await manager().applyPendingAtStartup();
    expect(runs.single.destinationMountId, '91');
  });
  test('a different card cannot receive a pending move', () async {
    await manager().prepareRequest(
      const TempoStorageRequest(policy: TempoStoragePolicy.yes),
    );
    device = const DeviceSnapshot(
      cardPath: '/mnt/sd',
      cardMountId: '91',
      cardSourceId: 'card-b',
    );
    await expectLater(manager().applyPendingAtStartup(), throwsStateError);
    expect(runs, isEmpty);
    expect(manager().readPendingRequest(), isNotNull);
  });
  test(
    'acknowledged selector survives interruption before pending intent cleanup',
    () async {
      await manager().prepareRequest(
        const TempoStorageRequest(policy: TempoStoragePolicy.yes),
      );
      failAfterCommit = true;
      await expectLater(manager().applyPendingAtStartup(), throwsStateError);
      expect(manager().readSelector(), TempoStoragePolicy.yes);
      failAfterCommit = false;
      await manager().applyPendingAtStartup();
      expect(runs, hasLength(1));
      expect(manager().readPendingRequest(), isNull);
    },
  );
}
