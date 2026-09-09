import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:cadence_media/cadence_media.dart';
import 'package:tempod/src/services/media_scheduler.dart';
import 'package:test/test.dart';

Future<void> until(bool Function() condition) async {
  final limit = DateTime.now().add(const Duration(seconds: 15));
  while (!condition()) {
    if (DateTime.now().isAfter(limit)) fail('scheduler did not settle');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late Directory home;
  late MediaClient client;
  late MediaScheduler scheduler;
  setUp(() async {
    home = Directory.systemTemp.createTempSync('daemon-scheduler');
    Directory('${home.path}/Music').createSync();
    final data = ByteData(44 + 16000);
    void ascii(int offset, String value) =>
        data.buffer.asUint8List().setAll(offset, value.codeUnits);
    ascii(0, 'RIFF');
    data.setUint32(4, 16036, Endian.little);
    ascii(8, 'WAVEfmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, 1, Endian.little);
    data.setUint32(24, 8000, Endian.little);
    data.setUint32(28, 16000, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    data.setUint32(40, 16000, Endian.little);
    File(
      '${home.path}/Music/fixture.wav',
    ).writeAsBytesSync(data.buffer.asUint8List());
    client = await MediaServer.spawn(
      databasePath: '${home.path}/library.db',
      policy: const ScanPolicy(artwork: ArtworkPolicy.none),
    );
    scheduler = MediaScheduler(
      client,
      home: home.path,
      firstScanAfter: const Duration(milliseconds: 30),
      recheckAfter: const Duration(milliseconds: 60),
      cardSettle: const Duration(milliseconds: 20),
      pollPeriod: const Duration(milliseconds: 10),
    );
  });
  tearDown(() async {
    await scheduler.close();
    await client.close();
    home.deleteSync(recursive: true);
  });
  test(
    'startup scan finishes without a UI; reconnect reads indexed music',
    () async {
      await scheduler.start();
      await until(() => scheduler.status['revision'] == 1);
      expect(scheduler.status['running'], false);
      expect(await client.tracks(scheduler.ids['music']!), hasLength(1));
      for (var i = 0; i < 50; i++) {
        expect(scheduler.status['revision'], 1);
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        scheduler.status['revision'],
        1,
        reason: 'status reads never schedule scans',
      );
    },
  );
  test(
    'existing libraries obey recheck independently of empty-library startup setting',
    () async {
      await scheduler.start();
      await scheduler.scan();
      await scheduler.close();
      scheduler = MediaScheduler(
        client,
        home: home.path,
        recheckAfter: const Duration(milliseconds: 30),
        pollPeriod: const Duration(milliseconds: 10),
      )..configure({'/settings/library/recheck': 'never'});
      await scheduler.start();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(scheduler.status['revision'], 0);
      await scheduler.close();
      scheduler =
          MediaScheduler(
            client,
            home: home.path,
            recheckAfter: const Duration(milliseconds: 30),
            pollPeriod: const Duration(milliseconds: 10),
          )..configure({
            '/settings/library/scan-on-boot': false,
            '/settings/library/recheck': 'startup',
          });
      await scheduler.start();
      await until(() => scheduler.status['revision'] == 1);
    },
  );
  test(
    'disabled startup and card settings still allow manual scan and root release',
    () async {
      scheduler.configure({
        '/settings/library/scan-on-boot': false,
        '/settings/library/scan-on-card': false,
      });
      await scheduler.start();
      scheduler.observeCard(null);
      scheduler.observeCard(home.path);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(scheduler.status['revision'], 0);
      await scheduler.scan();
      expect(await client.tracks(scheduler.ids['music']!), hasLength(1));
      scheduler.configure({
        '/settings/library/roots': {'music': <String>[]},
      });
      await scheduler.scan();
      expect(await client.listRoots(scheduler.ids['music']!), isEmpty);
      expect(
        await client.tracks(scheduler.ids['music']!),
        hasLength(1),
        reason: 'releasing folders does not erase files',
      );
    },
  );
  test(
    'initial mount is baseline; card arrival debounces and absent card retains roots',
    () async {
      scheduler.configure({'/settings/library/scan-on-boot': false});
      await scheduler.start();
      final card = Directory('${home.path}/card/Music')
        ..createSync(recursive: true);
      scheduler.observeCard(card.parent.path);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(scheduler.status['revision'], 0);
      scheduler.observeCard(null);
      scheduler.observeCard(card.parent.path);
      scheduler.observeCard(card.parent.path);
      await until(() => scheduler.status['revision'] == 1);
      scheduler.observeCard(null);
      expect(scheduler.roots('music'), contains(card.path));
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(scheduler.status['revision'], 1);
    },
  );
}
