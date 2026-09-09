import 'dart:io';
import 'package:test/test.dart';
import 'package:daemon_client/daemon_client.dart';
import 'package:tempod/tempod.dart';
import 'package:tempod/src/services/settings_host.dart';

void main() {
  test(
    'authenticated HTTP writes survive client reconnect and reject invalid credentials',
    () async {
      final directory = await Directory.systemTemp.createTemp('settings-http-');
      final host = SettingsHost('${directory.path}/settings.json');
      final player = DemoPlayer();
      final server = PlayerServer(
        player: player,
        token: 'settings-test',
        settingsHost: host,
      );
      await server.start();
      try {
        final uri = Uri.parse('http://127.0.0.1:${server.port}');
        final client = SettingsClient(baseUri: uri, token: 'settings-test');
        await client.write({'audio.volume': 35});
        expect(
          await SettingsClient(baseUri: uri, token: 'settings-test').read(),
          {'audio.volume': 35},
        );
        await expectLater(
          SettingsClient(baseUri: uri, token: 'wrong').write({}),
          throwsA(isA<HttpException>()),
        );
        expect(await client.read(), {'audio.volume': 35});
      } finally {
        await server.close();
        await host.close();
        await player.close();
        await directory.delete(recursive: true);
      }
    },
  );
  test(
    'queued writes persist independently of a client and retain latest snapshot',
    () async {
      final directory = await Directory.systemTemp.createTemp('settings-host-');
      addTearDown(() => directory.delete(recursive: true));
      final host = SettingsHost('${directory.path}/config/settings.json');
      expect(await host.read(), isEmpty);
      final observed = <Map<String, Object?>>[];
      host.changes.listen(observed.add);
      final first = host.write({'volume': 10});
      final second = host.write({'volume': 20, 'theme': 'dark'});
      await Future.wait([first, second]);
      await host.close();
      expect(observed, [
        {'volume': 10},
        {'theme': 'dark', 'volume': 20},
      ]);
      expect(await SettingsHost(host.file.path).read(), {
        'volume': 20,
        'theme': 'dark',
      });
      expect(() => host.write({}), throwsStateError);
    },
  );
  test(
    'invalid stored data is preserved and an oversized write cannot replace it',
    () async {
      final directory = await Directory.systemTemp.createTemp('settings-host-');
      addTearDown(() => directory.delete(recursive: true));
      final host = SettingsHost('${directory.path}/settings.json');
      await host.file.writeAsString('damaged');
      await expectLater(host.read(), throwsFormatException);
      expect(
        () => host.write({'huge': 'x' * (64 * 1024)}),
        throwsFormatException,
      );
      expect(await host.file.readAsString(), 'damaged');
      await host.close();
    },
  );
}
