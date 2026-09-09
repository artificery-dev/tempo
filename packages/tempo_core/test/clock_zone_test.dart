import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tomeui/tomeui.dart';

class FakeTempod extends Tempod {
  final requests = <Map<String, Object?>>[];
  final pending = <Completer<Map<String, Object?>>>[];

  @override
  Future<Map<String, Object?>> request(Map<String, Object?> request) {
    requests.add(request);
    final completion = Completer<Map<String, Object?>>();
    pending.add(completion);
    return completion.future;
  }
}

PlayerServices services({DeviceTimeZone? timeZone}) {
  final base = PlayerServices.fallback;
  return PlayerServices(
    battery: base.battery,
    wifi: base.wifi,
    bluetooth: base.bluetooth,
    storage: base.storage,
    places: base.places,
    screen: ScreenSwitch(),
    volume: VolumeSwitch(),
    output: OutputSwitch(),
    feedback: FeedbackSwitch(),
    timeZone: timeZone,
  );
}

void main() {
  tearDown(() {
    ClockZone.selected.value = 'UTC';
    ClockFormat.hour24.value = true;
    Appearance.place.value = null;
    SettingBindings.clear();
    Osd.hide();
  });

  test('conversion follows DST boundaries and fractional offsets', () {
    ClockZone.selected.value = 'America/New_York';
    expect(
      ClockFormat.format(ClockZone.at(DateTime.utc(2026, 3, 8, 6, 59))),
      '01:59',
    );
    expect(
      ClockFormat.format(ClockZone.at(DateTime.utc(2026, 3, 8, 7))),
      '03:00',
    );
    expect(
      ClockFormat.format(ClockZone.at(DateTime.utc(2026, 11, 1, 5, 59))),
      '01:59',
    );
    expect(
      ClockFormat.format(ClockZone.at(DateTime.utc(2026, 11, 1, 6))),
      '01:00',
    );
    ClockZone.selected.value = 'Asia/Kathmandu';
    final local = ClockZone.at(DateTime.utc(2026, 1, 1, 20));
    expect((local.day, local.hour, local.minute), (2, 1, 45));
    ClockZone.selected.value = 'UTC';
    expect(ClockZone.at(DateTime.utc(2026, 1, 1, 20)).hour, 20);
  });

  testWidgets('already mounted clocks update immediately in both formats', (
    tester,
  ) async {
    await tester.pumpWidget(
      const TomeApp(home: Column(children: [ClockText(), ClockText()])),
    );
    ClockZone.selected.value = 'Asia/Kathmandu';
    await tester.pump();
    expect(
      find.text(ClockFormat.parts(ClockZone.at(DateTime.now())).$1),
      findsNWidgets(2),
    );
    ClockFormat.hour24.value = false;
    ClockZone.selected.value = 'America/New_York';
    await tester.pump();
    final parts = ClockFormat.parts(ClockZone.at(DateTime.now()));
    expect(find.text(parts.$1), findsNWidgets(2));
    expect(find.text(parts.$2!), findsNWidgets(2));
  });

  test(
    'emulator selection updates the clock and saved startup values reapply',
    () {
      final settings = Settings(tree: playerSettingsTree);
      final bridge = PlayerSettings.install(settings, services: services());
      addTearDown(() {
        bridge.detach();
        settings.dispose();
      });
      settings.set('/settings/system/time/zone', 'America/New_York');
      expect(ClockZone.selected.value, 'America/New_York');
      expect(Appearance.place.value, TimeZones.placeOf('America/New_York'));
      ClockZone.selected.value = 'UTC';
      bridge.applyAll();
      expect(ClockZone.selected.value, 'America/New_York');
    },
  );

  test(
    'device changes wait for confirmation and recover after failure',
    () async {
      final daemon = FakeTempod();
      final settings = Settings(tree: playerSettingsTree);
      final bridge = PlayerSettings.install(
        settings,
        services: services(timeZone: DeviceTimeZone(tempod: daemon)),
      );
      addTearDown(() {
        bridge.detach();
        settings.dispose();
      });
      settings.set('/settings/system/time/zone', 'America/New_York');
      await Future<void>.delayed(Duration.zero);
      expect(daemon.requests.single, {
        'op': 'timezone',
        'zone': 'America/New_York',
      });
      expect(ClockZone.selected.value, 'UTC');
      daemon.pending[0].complete({'ok': true, 'zone': 'America/New_York'});
      await Future<void>.delayed(Duration.zero);
      expect(ClockZone.selected.value, 'America/New_York');
      settings.set('/settings/system/time/zone', 'Europe/London');
      await Future<void>.delayed(Duration.zero);
      daemon.pending[1].completeError(const TempodError('permission denied'));
      await Future<void>.delayed(Duration.zero);
      expect(ClockZone.selected.value, 'America/New_York');
      expect(settings.value('/settings/system/time/zone'), 'America/New_York');
      settings.set('/settings/system/time/zone', 'Europe/London');
      await Future<void>.delayed(Duration.zero);
      daemon.pending[2].complete({'ok': true, 'zone': 'Europe/London'});
      await Future<void>.delayed(Duration.zero);
      expect(ClockZone.selected.value, 'Europe/London');
    },
  );

  test(
    'rapid selections are serialized and mismatched readback fails',
    () async {
      final daemon = FakeTempod();
      final device = DeviceTimeZone(tempod: daemon);
      final first = device.setZone('Europe/London');
      final second = device.setZone('Asia/Kathmandu');
      await Future<void>.delayed(Duration.zero);
      expect(daemon.requests, hasLength(1));
      daemon.pending[0].complete({'zone': 'Europe/London'});
      await first;
      await Future<void>.delayed(Duration.zero);
      expect(daemon.requests, hasLength(2));
      final failure = expectLater(second, throwsA(isA<TempodError>()));
      daemon.pending[1].complete({'zone': 'UTC'});
      await failure;
    },
  );
}
