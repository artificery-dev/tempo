import 'dart:async';
import 'dart:io';
import 'package:dbus/dbus.dart';
import 'package:test/test.dart';
import 'package:player_api/player_api.dart';
import 'package:tempod/src/services/bluetooth_player.dart';
import 'package:tempod/src/services/remote_player.dart';

class MediaAdapter extends DBusObject {
  MediaAdapter() : super(DBusObjectPath('/org/bluez/hci0'));
  final registered = StreamController<DBusMethodCall>.broadcast();
  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    registered.add(call);
    return DBusMethodSuccessResponse();
  }
}

void main() {
  test(
    'BlueZ uses shared player, metadata, explicit commands and readiness lifecycle',
    () async {
      final directory = await Directory.systemTemp.createTemp('tempo-avrcp');
      final server = DBusServer();
      final address = await server.listenAddress(
        DBusAddress.unix(dir: directory),
      );
      final bluez = DBusClient(address);
      final adapter = MediaAdapter();
      final playback = RemotePlayer();
      final ready = <bool>[];
      final commands = <PlayerAction>[];
      var revision = 0;
      PlayerSnapshot state(PlaybackStatus status) => PlayerSnapshot(
        revision: ++revision,
        available: true,
        status: status,
        trackId: 'tone',
        title: 'Middle C',
        artist: 'Tempo',
        album: 'Diagnostics',
        hasNext: true,
        durationMs: 300000,
      );
      void attach(PlaybackStatus status) => playback.attach(
        PlayerSnapshotEmitted(sessionId: 'owner', state: state(status)),
        (event) {
          if (event is PlayerCommandRequested) {
            commands.add(event.command.action);
            final next = switch (event.command.action) {
              PlayerAction.play => PlaybackStatus.playing,
              PlayerAction.pause => PlaybackStatus.paused,
              PlayerAction.stop => PlaybackStatus.stopped,
              _ => playback.snapshot.status,
            };
            playback.receive(
              PlayerCommandSucceeded(
                sessionId: 'owner',
                requestId: event.requestId,
                state: state(next),
              ),
            );
          }
        },
      );
      attach(PlaybackStatus.paused);
      // Readiness is deliberately delayed, and the test asserts both that it
      // waits and that it eventually arrives. Two seconds is long enough that
      // a slow round trip cannot be mistaken for the delay expiring, and the
      // waits below end as soon as readiness actually changes.
      const readyDelay = Duration(seconds: 2);
      final player = BluetoothPlayer(
        playback,
        bus: DBusClient(address),
        readyDelay: readyDelay,
        onPlaybackReady: ready.add,
      );
      addTearDown(() async {
        await player.dispose();
        await playback.close();
        await bluez.close();
        await server.close();
        await adapter.registered.close();
        await directory.delete(recursive: true);
      });
      await bluez.registerObject(adapter);
      await bluez.requestName('org.bluez');
      final registered = adapter.registered.stream.first;
      await player.start();
      final registration = await registered;
      final props = registration.values[1].asStringVariantDict();
      expect(props['CanGoNext'], const DBusBoolean(true));
      expect(
        props['Metadata']!.asStringVariantDict()['xesam:artist'],
        DBusArray.string(['Tempo']),
      );
      expect(
        props['Metadata']!.asStringVariantDict()['xesam:album'],
        const DBusString('Diagnostics'),
      );
      final remote = DBusRemoteObject(
        bluez,
        name: registration.sender!,
        path: player.path,
      );
      Future<void> command(String name) async {
        await remote.callMethod(BluetoothPlayer.interface, name, []);
      }

      Future<void> becomesReady() async {
        final deadline = DateTime.now().add(const Duration(seconds: 60));
        while (ready.isEmpty || !ready.last) {
          if (DateTime.now().isAfter(deadline)) fail('readiness never arrived');
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }

      await command('Play');
      await command('Play');
      expect(playback.snapshot.status, PlaybackStatus.playing);
      expect(ready.where((v) => v), isEmpty);
      await command('Pause');
      // Past the delay the cancelled timer would have fired at, so waiting
      // longer only makes this negative stronger.
      await Future<void>.delayed(readyDelay * 2);
      expect(
        ready.where((v) => v),
        isEmpty,
        reason: 'pause cancels stale delayed ready',
      );
      await command('Play');
      await becomesReady();
      expect(ready.last, isTrue);
      await command('Stop');
      expect(playback.snapshot.status, PlaybackStatus.stopped);
      await command('Next');
      await command('Previous');
      expect(
        commands,
        containsAll([
          PlayerAction.play,
          PlayerAction.pause,
          PlayerAction.stop,
          PlayerAction.next,
          PlayerAction.previous,
        ]),
      );
      playback.detach();
      expect(ready.last, isFalse);
      attach(PlaybackStatus.playing);
      await becomesReady();
      expect(ready.last, isTrue, reason: 'owner reconnect replays readiness');
      final again = adapter.registered.stream.first;
      await bluez.releaseName('org.bluez');
      await bluez.requestName('org.bluez');
      await again.timeout(const Duration(seconds: 60));
      await becomesReady();
      expect(ready.last, isTrue, reason: 'BlueZ reconnect republishes Playing');
    },
  );
}
