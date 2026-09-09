import 'dart:async';
import 'dart:io';

import 'package:daemon_client/daemon_client.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tempo_core/tempo_core.dart';

import 'daemon_device_readings.dart';
import 'daemon_data_storage.dart';
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
        data: profile.dataPath!,
        config: profile.configPath!,
        sdCard: original.sdCard,
      );
      _devices = DaemonDeviceReadings(
        DeviceClient(baseUri: base, token: apiToken),
      );
      final settings = SettingsClient(baseUri: base, token: apiToken);
      final media = MediaTransport(baseUri: base, token: apiToken);
      final services = PlayerServices.device(
        initialPlaces: places,
        dataStorage: controller,
        readSettings: settings.read,
        writeSettings: settings.write,
        mediaTransport: media.send,
        closeMediaTransport: media.close,
        battery: _devices!.battery,
        storage: _devices!.storage,
      );
      _services = services;
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
    await _owner?.close();
    await _player?.close();
    final services = _services;
    if (services == null) {
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
    await _devices?.close();
    _dataStorage?.dispose();
  }

  @override
  void dispose() {
    unawaited(_close());
    super.dispose();
  }
}
