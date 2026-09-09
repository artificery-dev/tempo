import 'dart:async';

import 'package:dbus/dbus.dart';
import 'dart:io';
import 'package:player_api/player_api.dart';

/// BlueZ needs a local AVRCP player as well as an A2DP audio stream. Without
/// one it reports Stopped; the Flare then acknowledges volume without applying
/// it. Publish actual transport state, and accept its playback buttons here.
class BluetoothPlayer extends DBusObject {
  BluetoothPlayer(
    this.playback, {
    DBusClient? bus,
    this.onPlaybackReady,
    this.readyDelay = const Duration(milliseconds: 1500),
  }) : _bus = bus ?? DBusClient.system(),
       super(DBusObjectPath('/org/tempo/player'));

  static const interface = 'org.mpris.MediaPlayer2.Player';
  final PlayerService playback;
  final void Function(bool)? onPlaybackReady;
  final Duration readyDelay;
  StreamSubscription<PlayerSnapshot>? _changes;
  final DBusClient _bus;
  StreamSubscription<DBusNameOwnerChangedEvent>? _owner;
  Timer? _retry;
  bool _registered = false;
  bool _registering = false;
  bool _disposed = false;
  int _playbackEpoch = 0;
  Map<String, DBusValue> _last = {};

  Map<String, DBusValue> get properties {
    final now = playback.snapshot;
    final hasTrack = now.available && now.trackId != null;
    return {
      'Identity': const DBusString('Tempo'),
      'PlaybackStatus': DBusString(switch (now.available
          ? now.status
          : PlaybackStatus.stopped) {
        PlaybackStatus.playing => 'Playing',
        PlaybackStatus.paused => 'Paused',
        PlaybackStatus.stopped => 'Stopped',
      }),
      'Metadata': DBusDict.stringVariant({
        if (now.title != null) 'xesam:title': DBusString(now.title!),
        if (now.artist case final artist?)
          'xesam:artist': DBusArray.string([artist]),
        if (now.album case final album?) 'xesam:album': DBusString(album),
        'mpris:length': DBusInt64(now.durationMs * 1000),
      }),
      'Position': DBusInt64(now.positionMs * 1000),
      'CanControl': DBusBoolean(now.available),
      'CanPlay': DBusBoolean(hasTrack),
      'CanPause': DBusBoolean(hasTrack),
      'CanGoNext': DBusBoolean(now.available && now.hasNext),
      'CanGoPrevious': DBusBoolean(hasTrack),
      'CanSeek': const DBusBoolean(false),
    };
  }

  Future<void> start() async {
    onPlaybackReady?.call(false);
    _changes = playback.changes.listen((_) => _changed());
    try {
      await _bus.registerObject(this);
      if (_disposed) return;
      _owner = _bus.nameOwnerChanged.listen((event) {
        if (event.name == 'org.bluez') {
          _registered = false;
          _playbackEpoch++;
          onPlaybackReady?.call(false);
          unawaited(_register());
        }
      });
      _retry = Timer.periodic(
        const Duration(seconds: 3),
        (_) => unawaited(_register()),
      );
      await _register();
    } on Object catch (error) {
      stderr.writeln('Bluetooth player: $error');
    }
  }

  Future<void> _register() async {
    if (_disposed || _registered || _registering) return;
    _registering = true;
    final sent = properties;
    try {
      await _bus.callMethod(
        destination: 'org.bluez',
        path: DBusObjectPath('/org/bluez/hci0'),
        interface: 'org.bluez.Media1',
        name: 'RegisterPlayer',
        values: [path, DBusDict.stringVariant(sent)],
        replySignature: DBusSignature(''),
      );
      _registered = true;
      _last = sent;
      _changed();
      if (sent['PlaybackStatus'] == const DBusString('Playing') &&
          playback.snapshot.available &&
          playback.snapshot.status == PlaybackStatus.playing) {
        _scheduleReady(_playbackEpoch);
      }
    } on Object {
      // The adapter or bluetoothd may still be starting. Retry without
      // interfering with local playback.
    } finally {
      _registering = false;
    }
  }

  void _changed() {
    if (!_registered || _disposed) return;
    final playing =
        playback.snapshot.available &&
        playback.snapshot.status == PlaybackStatus.playing;
    if (!playing) onPlaybackReady?.call(false);
    final next = properties;
    final changed = {
      for (final entry in next.entries)
        if (entry.key != 'Position' && _last[entry.key] != entry.value)
          entry.key: entry.value,
    };
    _last = next;
    if (changed.containsKey('PlaybackStatus')) _playbackEpoch++;
    final epoch = _playbackEpoch;
    if (changed.isNotEmpty) {
      unawaited(
        emitPropertiesChanged(interface, changedProperties: changed)
            .then((_) async {
              if (changed['PlaybackStatus'] != const DBusString('Playing')) {
                return;
              }
              _scheduleReady(epoch);
            })
            .catchError((Object error) {
              stderr.writeln('Bluetooth player update: $error');
            }),
      );
    }
  }

  void _scheduleReady(int epoch) {
    // The peer may restore its prior volume ~1.1s after AVRCP Playing.
    // Wait for that exchange before permitting the owner's deferred flush.
    unawaited(
      Future<void>.delayed(readyDelay, () {
        if (!_disposed &&
            _registered &&
            epoch == _playbackEpoch &&
            playback.snapshot.available &&
            playback.snapshot.status == PlaybackStatus.playing) {
          onPlaybackReady?.call(true);
        }
      }),
    );
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async =>
      interface == BluetoothPlayer.interface
      ? DBusGetAllPropertiesResponse(properties)
      : DBusMethodErrorResponse.unknownInterface();

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final value = properties[name];
    return interface == BluetoothPlayer.interface && value != null
        ? DBusGetPropertyResponse(value)
        : DBusMethodErrorResponse.unknownProperty();
  }

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface != interface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    if (methodCall.values.isNotEmpty) {
      return DBusMethodErrorResponse.invalidArgs();
    }
    try {
      switch (methodCall.name) {
        case 'Play':
          await playback.execute(PlayerCommand.fromJson({'type': 'play'}));
        case 'Pause':
          await playback.execute(PlayerCommand.fromJson({'type': 'pause'}));
        case 'PlayPause':
          await playback.execute(PlayerCommand.fromJson({'type': 'toggle'}));
        case 'Stop':
          await playback.execute(PlayerCommand.fromJson({'type': 'stop'}));
        case 'Next':
          await playback.execute(PlayerCommand.fromJson({'type': 'next'}));
        case 'Previous':
          await playback.execute(PlayerCommand.fromJson({'type': 'previous'}));
        default:
          return DBusMethodErrorResponse.unknownMethod();
      }
      return DBusMethodSuccessResponse();
    } on PlayerFailure catch (error) {
      return DBusMethodErrorResponse(
        'org.mpris.MediaPlayer2.Player.Error.Failed',
        [DBusString(error.message)],
      );
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _playbackEpoch++;
    onPlaybackReady?.call(false);
    await _changes?.cancel();
    _retry?.cancel();
    await _owner?.cancel();
    await _bus.close();
  }
}
