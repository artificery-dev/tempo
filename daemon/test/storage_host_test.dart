import 'dart:async';
import 'dart:io';
import 'package:file/local.dart';
import 'package:tempo_data/tempo_data.dart';
import 'package:player_api/player_api.dart';
import 'package:daemon_client/daemon_client.dart';
import 'package:tempod/tempod.dart';
import 'package:tempod/src/services/storage_host.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late String home, card;
  var attached = true;
  Future<void> Function(String)? checkpoint;
  const fs = LocalFileSystem();
  TempoStorageManager manager() => TempoStorageManager(
    fs: fs,
    devicePaths: TempoProfilePaths.device(
      fs,
      home: home,
      configHome: '$home/.config',
    ),
    selectorPath: TempoStorageManager.defaultSelectorPath(fs, home),
    cardRoot: attached ? card : null,
    checkpoint: checkpoint,
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('tempo-storage-host-');
    home = '${root.path}/home';
    card = '${root.path}/sd';
    attached = true;
    checkpoint = null;
    Directory('$home/.cadence').createSync(recursive: true);
    Directory('$home/.config/tempo').createSync(recursive: true);
    Directory(card).createSync();
    await manager().setPolicy(TempoStoragePolicy.ask);
    File('$home/.cadence/library.db').writeAsStringSync('old database');
    File(
      '$home/.config/tempo/settings.json',
    ).writeAsStringSync('{"volume":42}');
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'card removal keeps internal settings available and does not restart owners',
    () async {
      Directory('$card/.cadence').createSync();
      await manager().acceptExistingSd();
      var restarts = 0;
      final host = StorageHost(
        manager: manager,
        mediaHome: home,
        restartDelay: Duration.zero,
        restart: () async {
          restarts++;
        },
      );
      await host.initialize();
      host.observeCard('card-a');
      attached = false;
      host.observeCard(null);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(restarts, 0);
      expect(host.status.available, isTrue);
      expect(host.status.configPath, '$home/.config/tempo');
      expect(host.status.location, 'sd');
      attached = true;
      host.observeCard('card-a');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(restarts, 1);
      await host.close();
    },
  );

  test(
    'device Ask and No updates leave owners and restart queue untouched',
    () async {
      var restarts = 0;
      final host = StorageHost(
        manager: manager,
        mediaHome: home,
        restart: () async {
          restarts++;
        },
        restartDelay: Duration.zero,
      );
      await host.initialize();
      for (final policy in ['no', 'no', 'ask']) {
        final result = await host.select(StorageSelection(policy: policy));
        expect(result.policy, policy);
        expect(result.restartPending, isFalse);
        expect(result.dataPath, '$home/.cadence');
        expect(manager().readSelector().name, policy);
        expect(manager().readPendingRequest(), isNull);
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(restarts, 0);
      expect(
        File('$home/.cadence/library.db').readAsStringSync(),
        'old database',
      );
      await host.close();
    },
  );

  test(
    'authenticated selection stages intent, then new lifetime copies final old-owner bytes',
    () async {
      final queued = Completer<void>();
      final host = StorageHost(
        manager: manager,
        mediaHome: home,
        restart: () async {
          queued.complete();
        },
        restartDelay: const Duration(milliseconds: 10),
      );
      await host.initialize();
      final player = DemoPlayer();
      final server = PlayerServer(
        player: player,
        token: 'storage-test',
        storageHost: host,
      );
      await server.start();
      final uri = Uri.parse('http://127.0.0.1:${server.port}');
      final client = StorageClient(baseUri: uri, token: 'storage-test');
      try {
        expect((await client.status()).policy, 'ask');
        await expectLater(
          StorageClient(
            baseUri: uri,
            token: 'wrong',
          ).select(const StorageSelection(policy: 'yes')),
          throwsA(isA<HttpException>()),
        );
        expect(manager().readPendingRequest(), isNull);
        final accepted = await client.select(
          const StorageSelection(policy: 'yes'),
        );
        expect(accepted.restartPending, isTrue);
        expect(accepted.location, 'device');
        expect(accepted.dataPath, '$home/.cadence');
        expect(Directory('$card/.cadence').existsSync(), isFalse);
        await queued.future.timeout(const Duration(seconds: 1));
        File(
          '$home/.cadence/library.db',
        ).writeAsStringSync('checkpoint after response');
      } finally {
        await server.close();
        await host.close();
        await player.close();
      }
      final next = StorageHost(
        manager: manager,
        mediaHome: home,
        restart: () async {},
      );
      await next.initialize();
      expect(next.status.location, 'sd');
      expect(next.status.mediaHome, home);
      expect(next.status.configPath, '$home/.config/tempo');
      expect(
        File('$card/.cadence/library.db').readAsStringSync(),
        'checkpoint after response',
      );
      expect(
        File('$home/.cadence/library.db').readAsStringSync(),
        'checkpoint after response',
      );
      expect(manager().readPendingRequest(), isNull);
      await next.close();
    },
  );

  test(
    'offer decline keeps ask; adoption preserves existing card bytes',
    () async {
      Directory('$card/.cadence/config').createSync(recursive: true);
      File('$card/.cadence/library.db').writeAsStringSync('card database');
      final host = StorageHost(
        manager: manager,
        mediaHome: home,
        restart: () async {},
      );
      await host.initialize();
      expect(host.status.needsPrompt, isTrue);
      expect(host.dismissOffer().needsPrompt, isFalse);
      expect(manager().readSelector(), TempoStoragePolicy.ask);
      await expectLater(
        host.select(const StorageSelection(policy: 'yes')),
        throwsA(isA<TempoProfileConflict>()),
      );
      await host.select(
        const StorageSelection(policy: 'yes', adoptExisting: true),
      );
      await host.close();
      final next = StorageHost(
        manager: manager,
        mediaHome: home,
        restart: () async {},
      );
      await next.initialize();
      expect(next.status.available, isTrue);
      expect(next.status.location, 'sd');
      expect(
        File('$card/.cadence/library.db').readAsStringSync(),
        'card database',
      );
      expect(
        File('$home/.cadence/library.db').readAsStringSync(),
        'old database',
      );
      await next.close();
    },
  );

  test(
    'failed restart queue rolls back intent without changing active profile',
    () async {
      final failed = Completer<void>();
      final host = StorageHost(
        manager: manager,
        mediaHome: home,
        restartDelay: Duration.zero,
        restart: () async {
          throw StateError('systemd unavailable');
        },
        log: (_) {
          if (!failed.isCompleted) failed.complete();
        },
      );
      await host.initialize();
      await host.select(const StorageSelection(policy: 'yes'));
      await failed.future.timeout(const Duration(seconds: 1));
      expect(manager().readPendingRequest(), isNull);
      expect(host.status.location, 'device');
      expect(host.status.available, isTrue);
      expect(host.status.error, contains('Restart was not queued'));
      expect(Directory('$card/.cadence').existsSync(), isFalse);
      await host.close();
    },
  );

  test(
    'selected missing card retains internal settings and uses internal library fallback',
    () async {
      Directory('$card/.cadence').createSync();
      await manager().acceptExistingSd();
      attached = false;
      final host = StorageHost(
        manager: manager,
        mediaHome: home,
        restart: () async {},
      );
      await host.initialize();
      final player = DemoPlayer();
      final server = PlayerServer(
        player: player,
        token: 'storage-test',
        storageHost: host,
      );
      await server.start();
      try {
        final client = StorageClient(
          baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
          token: 'storage-test',
        );
        final state = await client.status();
        expect(state.location, 'device');
        expect(state.available, isTrue);
        expect(state.dataPath, '$home/.cadence');
        expect(state.configPath, '$home/.config/tempo');
        expect(state.sdAvailable, isFalse);
        expect(
          File('$home/.config/tempo/settings.json').readAsStringSync(),
          '{"volume":42}',
        );
        await client.select(
          const StorageSelection(policy: 'no', adoptExisting: true),
        );
      } finally {
        await server.close();
        await host.close();
        await player.close();
      }
      final next = StorageHost(
        manager: manager,
        mediaHome: home,
        restart: () async {},
      );
      await next.initialize();
      expect(next.status.location, 'device');
      expect(next.status.available, isTrue);
      await next.close();
    },
  );
  test(
    'failed startup intent can be replaced without opening a fallback profile',
    () async {
      await manager().prepareRequest(
        const TempoStorageRequest(policy: TempoStoragePolicy.yes),
      );
      attached = false;
      final host = StorageHost(
        manager: manager,
        mediaHome: home,
        restart: () async {},
      );
      await host.initialize();
      expect(host.status.available, isFalse);
      expect(host.status.dataPath, isNull);
      expect(host.status.restartPending, isTrue);
      await host.select(
        const StorageSelection(policy: 'no', adoptExisting: true),
      );
      await host.close();
      final next = StorageHost(
        manager: manager,
        mediaHome: home,
        restart: () async {},
      );
      await next.initialize();
      expect(next.status.available, isTrue);
      expect(next.status.policy, 'no');
      expect(
        File('$home/.cadence/library.db').readAsStringSync(),
        'old database',
      );
      await next.close();
    },
  );
  test(
    'failed copy is recovered before API recovery selection adopts original device',
    () async {
      await manager().prepareRequest(
        const TempoStorageRequest(policy: TempoStoragePolicy.yes),
      );
      checkpoint = (phase) async {
        if (phase == 'preparing') throw StateError('copy failure');
      };
      final host = StorageHost(
        manager: manager,
        mediaHome: home,
        restart: () async {},
      );
      await host.initialize();
      expect(host.status.available, isFalse);
      expect(host.status.dataPath, isNull);
      expect(
        File('${manager().selectorPath}.transaction').existsSync(),
        isFalse,
      );
      await host.select(
        const StorageSelection(policy: 'no', adoptExisting: true),
      );
      await host.close();
      checkpoint = null;
      final next = StorageHost(
        manager: manager,
        mediaHome: home,
        restart: () async {},
      );
      await next.initialize();
      expect(next.status.available, isTrue);
      expect(next.status.location, 'device');
      expect(
        File('$home/.cadence/library.db').readAsStringSync(),
        'old database',
      );
      await next.close();
    },
  );
}
