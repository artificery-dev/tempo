import 'dart:async';
import 'dart:io';

import 'package:daemon_client/daemon_client.dart';
import 'package:cadence_client/cadence_client.dart'
    show CadenceClient, VolumeStatus;
import 'package:cadence_client/unix.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tempo_core/tempo_core.dart';

import 'daemon_device_readings.dart';
import 'daemon_data_storage.dart';
import 'daemon_card_maintenance.dart';
import 'flutter_player_service.dart';

/// Composes the device UI with daemon observations and the existing player.
final class DaemonApp extends StatefulWidget {
  const DaemonApp({super.key});
  @override
  State<DaemonApp> createState() => _DaemonAppState();
}

final class _DaemonAppState extends State<DaemonApp> {
  PlayerServices? _services;
  DaemonDataStorage? _dataStorage;
  String? _startupError;
  DaemonDeviceReadings? _devices;
  FlutterPlayerService? _player;
  PlaybackOwnerConnection? _owner;
  CadenceLibrary? _cadence;
  DaemonCardMaintenance? _cardMaintenance;
  StreamSubscription<VolumeStatus?>? _libraryAttachment;
  final List<Listenable> _activitySources = [];

  void _refreshCardActivity() {
    final services = _services;
    final phase = _cardMaintenance?.value.phase;
    _devices?.setMediaBusy(
      (_cadence?.cadenceBusy ?? true) ||
          (services?.playback.value.hasTrack ?? false) ||
          VideoPlayback.active != null ||
          (_cardMaintenance?.value.busy ?? false) ||
          phase == CardMaintenancePhase.failed,
    );
  }

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      final base = Uri.parse(
        Platform.environment['TEMPOD_API_URL'] ?? 'http://127.0.0.1:8765',
      );
      final apiToken = _credential('TEMPOD_API_TOKEN');
      final ownerToken = _credential('TEMPOD_OWNER_TOKEN');
      final storageClient = StorageClient(baseUri: base, token: apiToken);
      final profile = await storageClient.status();
      if (!mounted) return;
      final controller = DaemonDataStorage(storageClient, profile);
      _dataStorage = controller;
      if (!profile.available) {
        setState(() {});
        return;
      }
      final original = DevicePlaces().value;
      final places = Places(
        fileSystem: original.fileSystem,
        home: profile.mediaHome,
        data: original.data,
        config: profile.configPath!,
        sdCard: original.sdCard,
      );
      _devices = DaemonDeviceReadings(
        DeviceClient(
          baseUri: base,
          token: apiToken,
          period: const Duration(seconds: 1),
        ),
      );
      final settings = SettingsClient(baseUri: base, token: apiToken);
      final cadence = CadenceLibrary(
        CadenceClient(
          UnixMediaTransport(
            Platform.environment['CADENCE_SOCKET'] ??
                '/run/cadenced/media.sock',
          ),
        ),
      );
      _cadence = cadence;
      try {
        await cadence.connect();
      } catch (error) {
        // Collection status and polling handle unavailable media. Settings and
        // wallpaper still come from internal XDG storage and must open normally.
        debugPrint('Cadence is not available yet: $error');
      }
      if (!mounted) return;
      final media = CadenceMediaLibrary(cadence);
      late final PlayerServices services;
      final maintenance = DaemonCardMaintenance(
        client: storageClient,
        cadence: cadence,
        device: _devices!.client,
        stopPlayback: () async {
          await services.playback.stop();
          await VideoPlayback.active?.stop();
        },
      );
      _cardMaintenance = maintenance;
      services = PlayerServices.device(
        initialPlaces: places,
        dataStorage: controller,
        cardMaintenance: maintenance,
        readSettings: settings.read,
        writeSettings: settings.write,
        library: media,
        resolveLibraryPath: media.resolvePath,
        battery: _devices!.battery,
        storage: _devices!.storage,
      );
      _services = services;
      _activitySources.addAll([
        services.playback,
        VideoPlayback.session,
        maintenance,
      ]);
      for (final source in _activitySources) {
        source.addListener(_refreshCardActivity);
      }
      _refreshCardActivity();
      String? attachmentIdentity;
      _libraryAttachment = cadence.changes.listen((volume) {
        final identity = volume == null
            ? null
            : '${volume.id}/${volume.generation}';
        if (volume?.state != 'attached' ||
            (attachmentIdentity != null && identity != attachmentIdentity)) {
          unawaited(services.playback.stop());
          unawaited(VideoPlayback.active?.stop());
        }
        attachmentIdentity = identity;
        _refreshCardActivity();
      });
      _player = FlutterPlayerService(
        playback: services.playback,
        volume: services.volume,
        fmRadio: services.fmRadio,
      );
      final volume = services.volume;
      if (volume is DeviceVolume) volume.setPlaybackActive(false);
      if (ownerToken.isNotEmpty) {
        _owner = PlaybackOwnerConnection(
          uri: base
              .resolve('/api/v1/owner')
              .replace(scheme: base.scheme == 'https' ? 'wss' : 'ws'),
          token: ownerToken,
          player: _player!,
          onBluetoothPlaybackReady: (active) {
            final volume = services.volume;
            if (volume is DeviceVolume) volume.setPlaybackActive(active);
          },
        )..start();
      } else {
        debugPrint(
          'tempod: owner credential missing; remote playback is unavailable.',
        );
      }
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) setState(() => _startupError = '$error');
    }
  }

  String _credential(String name) {
    final file = Platform.environment['${name}_FILE'];
    try {
      return (file == null
              ? Platform.environment[name] ?? ''
              : File(file).readAsStringSync())
          .trim();
    } catch (_) {
      debugPrint('tempod: could not read $name credential file.');
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_services case final services?) return TempoApp(services: services);
    if (_dataStorage case final controller?) {
      return DataStorageRecoveryApp(controller: controller);
    }
    return TomeApp(
      theme: Appearance.theme.value,
      home: Center(child: Text(_startupError ?? 'Opening Tempo…')),
    );
  }

  Future<void> _close() async {
    for (final source in _activitySources) {
      source.removeListener(_refreshCardActivity);
    }
    _activitySources.clear();
    _cardMaintenance?.dispose();
    await _libraryAttachment?.cancel();
    await _owner?.close();
    await _player?.close();
    final services = _services;
    if (services == null) {
      await _cadence?.close();
      await _cadence?.client.close();
      await _devices?.close();
      _dataStorage?.dispose();
      return;
    }
    await services.library.dispose();
    await services.playback.stop();
    final playback = services.playback;
    if (playback case ChangeNotifier notifier) notifier.dispose();
    services.radios?.dispose();
    final volume = services.volume;
    if (volume case ChangeNotifier notifier) notifier.dispose();
    final output = services.output;
    if (output case ChangeNotifier notifier) notifier.dispose();
    final fm = services.fmRadio;
    if (fm case ChangeNotifier notifier) notifier.dispose();
    await _cadence?.close();
    await _cadence?.client.close();
    await _devices?.close();
    _dataStorage?.dispose();
  }

  @override
  void dispose() {
    unawaited(_close());
    super.dispose();
  }
}
