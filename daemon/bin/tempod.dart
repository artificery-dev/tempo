import 'package:tempod/src/services/profile_access.dart';
import 'package:file/local.dart';
import 'package:tempo_data/tempo_data.dart';
import 'package:tempod/src/services/storage_host.dart';
import 'package:tempod/src/services/shutdown.dart';
import 'package:tempod/src/services/bluetooth_player.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:daemon_client/daemon_client.dart';
import 'package:tempod/src/services/remote_player.dart';
import 'package:tempod/src/services/device_monitor.dart';
import 'package:tempod/src/services/cadence_process.dart';
import 'package:tempod/src/services/cadence_roots.dart';
import 'package:tempod/src/services/card_host.dart';
import 'package:tempod/src/services/cadence_datastore_mover.dart';
import 'package:tempod/src/services/cadence_coordinator.dart';
import 'package:tempod/src/services/settings_host.dart';
import 'package:tempod/src/services/credentials.dart';
import 'package:tempod/src/services/service_notify.dart';
import 'package:tempod/src/native/native_control.dart';
import 'package:tempod/tempod.dart';
import 'package:tempod/src/services/radio_host.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage.')
    ..addFlag(
      'init-credentials',
      negatable: false,
      help: 'Initialize per-device credential files and exit.',
    )
    ..addOption('credential-dir', defaultsTo: '/var/lib/tempod/credentials')
    ..addOption(
      'credential-group',
      help: 'Group allowed to read frontend credentials.',
    )
    ..addOption(
      'bind',
      defaultsTo: '127.0.0.1',
      help: 'HTTP listen IP address.',
    )
    ..addOption(
      'port',
      defaultsTo: '8765',
      help: 'HTTP/WebSocket port; 0 selects a free port.',
    )
    ..addOption(
      'token-file',
      help: 'Bearer token file; otherwise use TEMPOD_API_TOKEN.',
    )
    ..addMultiOption(
      'allow-origin',
      help: 'Exact browser origins allowed to use the API.',
    )
    ..addOption(
      'owner-token-file',
      help:
          'App owner credential; otherwise TEMPOD_OWNER_TOKEN. Separate from API token.',
    )
    ..addOption('settings-file', help: 'Own the player settings JSON file.')
    ..addOption(
      'profile-user',
      help: 'Frontend account owning selected profile files.',
    )
    ..addOption(
      'profile-home',
      help: 'Enable device/SD profile selection for this user home.',
    )
    ..addOption(
      'sd-root',
      help: 'Mounted SD profile root; defaults to /mnt/sd.',
    )
    ..addOption(
      'media-home',
      help: 'Media folder home, independent of the database location.',
    )
    ..addFlag(
      'bluetooth-player',
      negatable: false,
      help: 'Publish the playback owner through BlueZ AVRCP.',
    )
    ..addFlag('radios', negatable: false, help: 'Enable host radio operations.')
    ..addOption('tls-cert', help: 'PEM certificate chain for HTTPS/WSS.')
    ..addOption('tls-key', help: 'PEM private key; required with --tls-cert.')
    ..addFlag(
      'demo-player',
      negatable: false,
      help: 'Simulate one track; does not play audio.',
    )
    ..addOption(
      'native-library',
      help: 'Enable native Unix control using this shared library.',
    )
    ..addOption(
      'socket',
      defaultsTo: '/run/tempod/tempod.sock',
      help: 'Native control socket (unless socket-activated).',
    );
  PlayerServer? server;
  NativeControl? native;
  DemoPlayer? demo;
  RemotePlayer? remote;
  BluetoothPlayer? bluetoothPlayer;
  DeviceMonitor? devices;
  CadenceProcess? cadence;
  CadenceCoordinator? coordinator;
  CardHost? cardHost;
  SettingsHost? settings;
  StorageHost? storage;
  ProfileStartupDeadline? profileStartup;
  var failedProfileOwner = false;
  final signals = <StreamSubscription<ProcessSignal>>[];
  try {
    final args = parser.parse(arguments);
    if (args.flag('help')) {
      stdout.writeln('Tempo Dart daemon (development host)\n${parser.usage}');
      return;
    }
    if (args.rest.isNotEmpty) {
      throw const FormatException('Unexpected positional arguments.');
    }
    if (args.flag('init-credentials')) {
      await initializeCredentials(
        args.option('credential-dir')!,
        group: args.option('credential-group'),
      );
      return;
    }
    final port = int.tryParse(args.option('port')!);
    final address = InternetAddress.tryParse(args.option('bind')!);
    if (port == null || port < 0 || port > 65535 || address == null) {
      throw const FormatException(
        'Supply a valid IP address and port (0–65535).',
      );
    }
    final tokenFile = args.option('token-file');
    final token =
        (tokenFile == null
                ? Platform.environment['TEMPOD_API_TOKEN'] ?? ''
                : await File(tokenFile).readAsString())
            .trim();
    if (token.isEmpty) {
      throw const FormatException('Set TEMPOD_API_TOKEN or --token-file.');
    }
    final ownerFile = args.option('owner-token-file');
    final ownerToken =
        (ownerFile == null
                ? Platform.environment['TEMPOD_OWNER_TOKEN'] ?? ''
                : await File(ownerFile).readAsString())
            .trim();
    if (ownerToken == token ||
        (ownerToken.isNotEmpty && args.flag('demo-player'))) {
      throw const FormatException(
        'Owner credentials must differ from API credentials and cannot be combined with demo playback.',
      );
    }
    final origins = args.multiOption('allow-origin').toSet();
    for (final origin in origins) {
      final uri = Uri.tryParse(origin);
      if (uri == null ||
          !['http', 'https'].contains(uri.scheme) ||
          !uri.hasAuthority ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          uri.path.isNotEmpty) {
        throw const FormatException(
          'Origins must be exact http(s) origins without paths.',
        );
      }
    }
    final cert = args.option('tls-cert');
    final key = args.option('tls-key');
    if ((cert == null) != (key == null)) {
      throw const FormatException(
        '--tls-cert and --tls-key must be used together.',
      );
    }
    final tls = cert == null
        ? null
        : (SecurityContext()
            ..useCertificateChain(cert)
            ..usePrivateKey(key!));
    final stopped = Completer<void>();
    for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
      signals.add(
        signal.watch().listen((_) {
          if (!stopped.isCompleted) stopped.complete();
        }),
      );
    }
    final library = args.option('native-library');
    if (library != null) {
      var fd = -1;
      if (int.tryParse(Platform.environment['LISTEN_PID'] ?? '') == pid) {
        final count = int.tryParse(Platform.environment['LISTEN_FDS'] ?? '');
        if (count != 1) {
          throw const FormatException(
            'Expected one systemd activation socket.',
          );
        }
        fd = 3;
      }
      native = NativeControl.start(
        libraryPath: File(library).absolute.path,
        socketPath: args.option('socket')!,
        activatedFd: fd,
      );
      stderr.writeln(
        'Native Unix control started (metrics sampler not yet migrated).',
      );
    }
    if (args.flag('demo-player')) {
      demo = DemoPlayer();
      stderr.writeln('Demo player enabled: state simulation only, no audio.');
    }
    devices = DeviceMonitor(native: Tempod(socket: args.option('socket')))
      ..start();
    final profileHome =
        args.option('profile-home') ??
        Platform.environment['TEMPOD_PROFILE_HOME'];
    final mediaHome =
        args.option('media-home') ??
        Platform.environment['TEMPOD_MEDIA_HOME'] ??
        profileHome ??
        Platform.environment['HOME'] ??
        Directory.current.path;
    String? storePath, settingsPath;
    var storeKind = 'directory';
    if (profileHome != null) {
      profileStartup = ProfileStartupDeadline()..start();
      const fs = LocalFileSystem();
      final sdRoot =
          args.option('sd-root') ??
          Platform.environment['TEMPOD_SD_ROOT'] ??
          '/mnt/sd';
      final configHome =
          Platform.environment['XDG_CONFIG_HOME'] ??
          fs.path.join(profileHome, '.config');
      await devices.refresh();
      final monitor = devices;
      storage = StorageHost(
        mediaHome: mediaHome,
        restart: queueStorageRestart,
        log: stderr.writeln,
        manager: () => TempoStorageManager(
          fs: fs,
          devicePaths: TempoProfilePaths.device(
            fs,
            home: profileHome,
            configHome: configHome,
          ),
          selectorPath: TempoStorageManager.defaultSelectorPath(
            fs,
            profileHome,
          ),
          // An empty mountpoint directory is not an attached SD card.
          cardRoot: monitor.snapshot.cardPath == sdRoot ? sdRoot : null,
          datastoreMover: CadenceDatastoreMover(
            volume: () async {
              final owner = cadence;
              if (owner == null) throw StateError('Cadence is unavailable');
              return owner.client.volume();
            },
            device: () => monitor.snapshot,
            user:
                args.option('profile-user') ??
                Platform.environment['TEMPOD_PROFILE_USER'] ??
                'tempo',
            executable:
                Platform.environment['CADENCED_EXECUTABLE'] ??
                '/usr/local/lib/cadenced/bin/cadenced',
            event: (event) => stderr.writeln(jsonEncode(event)),
            log: stderr.writeln,
          ),
          checkpoint: (_) async {
            // Flush the filesystem containing the selector and its directory
            // entries before crossing the datastore ownership boundary.
            final selector = TempoStorageManager.defaultSelectorPath(
              fs,
              profileHome,
            );
            final result = await Process.run('/bin/sync', [
              '-f',
              fs.path.dirname(selector),
            ]);
            if (result.exitCode != 0) {
              throw StateError(
                'Could not persist the library storage selection',
              );
            }
          },
        ),
      );
      await storage.initialize();
      storage.observeCard(devices.cardIdentity);
      final storageOwner = storage;
      devices.changes.listen(
        (_) => storageOwner.observeCard(monitor.cardIdentity),
      );
      final profile = storage.status;
      if (profile.available) {
        try {
          final user =
              args.option('profile-user') ??
              Platform.environment['TEMPOD_PROFILE_USER'];
          if (user != null) {
            await ensureProfileAccess(
              TempoProfilePaths(
                data: profile.dataPath!,
                config: profile.configPath!,
              ),
              user,
            );
          }
          storePath = profile.dataPath!;
          storeKind = profile.location == 'sd' ? 'mount' : 'directory';
          settingsPath = fs.path.join(profile.configPath!, 'settings.json');
        } catch (error) {
          storage.unavailable(error);
        }
      }
    } else {
      settingsPath =
          args.option('settings-file') ??
          Platform.environment['TEMPOD_SETTINGS_FILE'];
    }
    if (settingsPath != null) settings = SettingsHost(settingsPath);
    try {
      if (storePath != null) {
        final user =
            args.option('profile-user') ??
            Platform.environment['TEMPOD_PROFILE_USER'] ??
            'tempo';
        final uid = int.parse(
          (await Process.run('id', ['-u', user])).stdout.toString().trim(),
        );
        final gid = int.parse(
          (await Process.run('id', ['-g', user])).stdout.toString().trim(),
        );
        final fresh = !await File('$storePath/library.sqlite').exists();
        final card = devices.snapshot.cardPath;
        cadence = await CadenceProcess.start(
          socketPath:
              Platform.environment['CADENCE_SOCKET'] ??
              '/run/cadenced/media.sock',
          executable:
              Platform.environment['CADENCED_EXECUTABLE'] ??
              '/usr/local/lib/cadenced/bin/cadenced',
          user: user,
          uid: uid,
          gid: gid,
          arguments: [
            '--store',
            storePath,
            '--store-kind',
            storeKind,
            '--native',
            'true',
            if (fresh) ...[
              '--initialize',
              'true',
              '--media-root',
              card == null
                  ? '.'
                  : storeKind == 'mount'
                  ? '.'
                  : card,
              if (card != null) ...['--media-mount', card],
            ],
          ],
          log: stderr.writeln,
          onUnexpectedExit: (code) {
            stderr.writeln(
              'cadenced exited unexpectedly ($code); restarting services.',
            );
            exitCode = 1;
            if (!stopped.isCompleted) stopped.complete();
          },
        );
        final bridge = CadenceRoots(
          client: cadence.client,
          device: () => devices!.snapshot,
        );
        coordinator = CadenceCoordinator(
          cadence.client,
          roots: bridge,
          log: stderr.writeln,
        );
        await coordinator.start(await settings?.read() ?? {});
        cardHost = CardHost(
          client: cadence.client,
          roots: bridge,
          device: () => devices!.snapshot,
          refreshDevice: () => devices!.refresh(),
        );
        final policy = coordinator;
        String? observedMount = devices.snapshot.cardMountId;
        devices.changes.listen((reading) {
          if (reading.cardMountId == observedMount) return;
          observedMount = reading.cardMountId;
          unawaited(policy.observeCard());
        });
        settings?.changes.listen((value) => unawaited(policy.configure(value)));
      }
    } catch (error) {
      if (storage == null) rethrow;
      failedProfileOwner = true;
      // A missing/retired Cadence datastore is a library failure, not a loss
      // of the internal settings profile. The UI can remain fully usable.
      stderr.writeln('Media library unavailable: $error');
      await shutdownServices({
        if (coordinator != null) 'unavailable policy': coordinator.close,
        if (cadence != null) 'unavailable Cadence': cadence.close,
      }, log: stderr.writeln);
      cadence = null;
      coordinator = null;
      cardHost = null;
    }
    remote = RemotePlayer();
    if (args.flag('bluetooth-player')) {
      bluetoothPlayer = BluetoothPlayer(
        remote,
        onPlaybackReady: remote.notifyBluetoothPlaybackReady,
      );
      await bluetoothPlayer.start();
    }
    server = PlayerServer(
      radios: args.flag('radios') ? RadioHost() : null,
      player: demo ?? remote,
      ownerToken: ownerToken.isEmpty ? null : ownerToken,
      deviceMonitor: devices,
      settingsHost: settings,
      storageHost: storage,
      cardHost: cardHost,
      token: token,
      allowedOrigins: origins,
      onError: (_, _) =>
          stderr.writeln('API operation failed; returning internal_error.'),
    );
    await server.start(address: address, port: port, securityContext: tls);
    final url = Uri(
      scheme: tls == null ? 'http' : 'https',
      host: address.address,
      port: server.port,
    );
    stdout.writeln('tempod listening at $url');
    profileStartup?.close();
    notifySystemdReady();
    await stopped.future;
  } on FormatException catch (error) {
    stderr.writeln('tempod: ${error.message}\nUse --help for options.');
    exitCode = 64;
  } catch (error) {
    stderr.writeln(
      'tempod: startup or runtime failure (${error.runtimeType}).',
    );
    exitCode = 1;
  } finally {
    profileStartup?.close();
    final clean = await shutdownServices({
      // Stop accepting work before disposing the services it depends on.
      if (server != null) 'http': server.close,
      if (storage != null) 'storage': storage.close,
      if (bluetoothPlayer != null) 'bluetooth': bluetoothPlayer.dispose,
      if (demo != null) 'demo': demo.close,
      if (remote != null) 'player': remote.close,
      if (devices != null) 'devices': devices.close,
      if (coordinator != null) 'cadence policy': coordinator.close,
      if (cadence != null) 'cadenced': cadence.close,
      if (settings != null) 'settings': settings.close,
      if (native != null) 'native': native.close,
    }, log: stderr.writeln);
    for (final signal in signals) {
      await signal.cancel();
    }
    stderr.writeln('shutdown: cleanup ${clean ? "complete" : "incomplete"}');
    if (!clean || failedProfileOwner) {
      // Timed-out futures can retain sockets or receive ports indefinitely.
      // All owners had a cleanup attempt; report failure instead of waiting
      // for systemd's 90-second SIGKILL with no indication of the blocker.
      await stderr.flush();
      exit(clean ? exitCode : 1);
    }
  }
}
