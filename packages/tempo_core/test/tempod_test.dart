import 'dart:convert';
import 'dart:io';

import 'package:tempo_core/tempo_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// The wire to tempod is one line each way over a unix socket, and the
/// daemon hangs up after its line. A stand-in daemon here checks the
/// client speaks that and nothing else, and that a refusal comes back as
/// an error with the daemon's words in it.
void main() {
  late Directory dir;
  late ServerSocket server;
  final seen = <Map<String, Object?>>[];
  var fmOn = false;
  var fmFrequencyKhz = 95500;

  /// Waits for a condition rather than a duration: every service in this
  /// suite speaks to the stand-in daemon over a real socket, and a machine
  /// with other work to do is slow over one.
  Future<void> until(bool Function() ready) async {
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (!ready()) {
      if (DateTime.now().isAfter(deadline)) fail('the daemon never answered');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tempod-test');
    server = await ServerSocket.bind(
      InternetAddress(
        '${dir.path}/tempod.sock',
        type: InternetAddressType.unix,
      ),
      0,
    );
    server.listen((connection) async {
      final line = await utf8.decoder
          .bind(connection)
          .transform(const LineSplitter())
          .first;
      final request = jsonDecode(line) as Map<String, Object?>;
      seen.add(request);
      if (request case {'op': 'fm', 'on': final bool on}) {
        fmOn = on;
      }
      if (request case {'op': 'fm', 'frequency_khz': final int frequency}) {
        fmFrequencyKhz = frequency;
      }
      if (request case {'op': 'fm', 'seek': final int direction}) {
        fmFrequencyKhz = direction > 0 ? 100100 : 95500;
      }
      final reply = switch (request['op']) {
        'ping' => {'ok': true, 'version': '0.0.0'},
        'battery' => {
          'ok': true,
          'ts': 1,
          'capacity': 63,
          'voltage_uv': 3900000,
          'charging': true,
          'status': 'Charging',
          'backlight': 124,
          'backlight_pct': 100,
        },
        'screen' => {
          'ok': true,
          'on': request['on'] ?? true,
          'brightness': 124,
          'max': 124,
        },
        'output' => {'ok': true, 'output': 'headphones', 'jack': true},
        'volume' => {
          'ok': true,
          'level': request['level'] ?? 40,
          'muted': false,
        },
        'fm' => {
          'ok': true,
          'available': true,
          'on': fmOn,
          'frequency_khz': fmFrequencyKhz,
          if (fmOn) ...{
            'rssi': -71,
            'stereo': true,
            'program_name': 'WXYZ',
            'radio_text': 'Around the world',
            'pi': 0x1234,
            'pty': 10,
          },
        },
        _ => {'ok': false, 'error': 'unknown op'},
      };
      connection.write('${jsonEncode(reply)}\n');
      await connection.flush();
      await connection.close();
    });
  });

  tearDown(() async {
    await server.close();
    await dir.delete(recursive: true);
    seen.clear();
    fmOn = false;
    fmFrequencyKhz = 95500;
  });

  test('one line out, one line back', () async {
    final tempod = Tempod(socket: '${dir.path}/tempod.sock');
    final reply = await tempod.request({'op': 'ping'});
    expect(reply['ok'], isTrue);
    expect(reply['version'], '0.0.0');
    expect(seen, [
      {'op': 'ping'},
    ]);
  });

  test('a refusal is an error in the daemon\'s words', () async {
    final tempod = Tempod(socket: '${dir.path}/tempod.sock');
    await expectLater(
      tempod.request({'op': 'reboot'}),
      throwsA(
        isA<TempodError>().having((e) => e.message, 'message', 'unknown op'),
      ),
    );
  });

  test('no daemon is a socket error, not a hang', () async {
    final tempod = Tempod(socket: '${dir.path}/nobody.sock');
    await expectLater(
      tempod.request({'op': 'ping'}),
      throwsA(isA<SocketException>()),
    );
  });

  test('the device screen goes dark before asking, and lights after', () async {
    final tempod = Tempod(socket: '${dir.path}/tempod.sock');
    final screen = DeviceScreen(tempod: tempod);
    // Give the start-up query its turn.
    await until(() => seen.any((request) => request['op'] == 'screen'));
    final off = screen.setOn(false, fade: const Duration(milliseconds: 250));
    expect(screen.value, isFalse, reason: 'the frame fades before the light');
    await off;
    expect(seen.last, {'op': 'screen', 'on': false, 'fade_ms': 250});

    final on = screen.setOn(true);
    expect(
      screen.value,
      isFalse,
      reason: 'the light comes on before the frame',
    );
    await on;
    expect(seen.last, {'op': 'screen', 'on': true, 'fade_ms': 400});
    expect(screen.value, isTrue);
  });

  test('a dim is a level; a sleep from the dim sends no lift, and the '
      'wake brings the level back', () async {
    final tempod = Tempod(socket: '${dir.path}/tempod.sock');
    final screen = DeviceScreen(tempod: tempod);
    await until(() => seen.any((request) => request['op'] == 'screen'));
    seen.clear();

    await screen.setDimmed(true);
    expect(screen.dimmed.value, isTrue);
    expect(screen.value, isTrue, reason: 'dim is awake');
    expect(seen.last, {'op': 'screen', 'brightness': 62});

    await screen.setDimmed(false);
    expect(seen.last, {'op': 'screen', 'brightness': 124});

    // Dim again, then sleep: the off goes out alone - a lift on its
    // heels would supersede it in tempod - and the wake carries the
    // level the dim took.
    await screen.setDimmed(true);
    seen.clear();
    await screen.setOn(false);
    expect(screen.dimmed.value, isFalse);
    expect(seen, [
      {'op': 'screen', 'on': false, 'fade_ms': 400},
    ]);
    await screen.setOn(true);
    expect(seen.last, {
      'op': 'screen',
      'on': true,
      'brightness': 124,
      'fade_ms': 400,
    });
    expect(screen.dimmed.value, isFalse);
    expect(screen.value, isTrue);
  });

  test('the device battery reads tempod\'s sample', () async {
    final battery = DeviceBattery(
      tempod: Tempod(socket: '${dir.path}/tempod.sock'),
    );
    expect(battery.value, BatteryReading.unknown);
    // Polling starts with the first listener, and reads at once.
    battery.addListener(() {});
    await until(() => battery.value != BatteryReading.unknown);
    expect(battery.value, const BatteryReading(percent: 63, charging: true));
    expect(seen.last, {'op': 'battery'});
    battery.dispose();
  });

  test('without a daemon the battery reports unknown', () async {
    final battery = DeviceBattery(
      tempod: Tempod(socket: '${dir.path}/nobody.sock'),
    );
    await battery.read();
    // The UI does not read sysfs when the daemon is unavailable.
    expect(battery.value, BatteryReading.unknown);
    battery.dispose();
  });

  test('the device volume asks where the mixer is, then sets it', () async {
    final tempod = Tempod(socket: '${dir.path}/tempod.sock');
    // A poll long enough not to interleave with what this test sends: the
    // start-up read is the only one it wants to see arrive on its own.
    final volume = DeviceVolume(
      tempod: tempod,
      period: const Duration(minutes: 5),
    );
    addTearDown(volume.dispose);
    expect(volume.value, VolumeReading.unknown);
    await until(() => volume.value != VolumeReading.unknown);
    expect(volume.value.level, 40, reason: 'the mixer\'s word at start-up');
    expect(seen.last, {'op': 'volume'});

    final up = volume.nudge(1);
    expect(volume.value.level, 45, reason: 'the value moves at once');
    await up;
    expect(seen.last, {'op': 'volume', 'level': 45});

    // Two quick steps: one request in flight, the last level asked for
    // goes next, and nothing in between.
    final before = seen.length;
    final a = volume.nudge(1);
    final b = volume.nudge(1);
    await Future.wait([a, b]);
    expect(volume.value.level, 55);
    final sent = seen.sublist(before);
    expect(sent.last, {'op': 'volume', 'level': 55});
    expect(sent.length, lessThanOrEqualTo(2));
  });

  test('the device output follows the jack, while anyone listens', () async {
    final output = DeviceOutput(
      tempod: Tempod(socket: '${dir.path}/tempod.sock'),
      period: const Duration(milliseconds: 40),
    );
    expect(output.value, AudioOutput.speaker);
    output.addListener(() {});
    await until(() => seen.where((r) => r['op'] == 'output').length > 1);
    expect(output.value, AudioOutput.headphones);
    expect(seen.last, {'op': 'output'});
    output.dispose();
  });

  test('without a daemon the volume still moves', () async {
    final volume = DeviceVolume(
      tempod: Tempod(socket: '${dir.path}/nobody.sock'),
    );
    addTearDown(volume.dispose);
    await volume.setLevel(30);
    expect(volume.value.level, 30);
    await volume.nudge(-1);
    expect(volume.value.level, 25);
  });

  test('without a daemon the value still moves', () async {
    final screen = DeviceScreen(
      tempod: Tempod(socket: '${dir.path}/nobody.sock'),
    );
    await screen.setOn(false);
    expect(screen.value, isFalse);
    await screen.setOn(true);
    expect(screen.value, isTrue);
  });

  test('the FM receiver powers, tunes, and adopts signal and RDS', () async {
    final radio = DeviceFmRadio(
      tempod: Tempod(socket: '${dir.path}/tempod.sock'),
      period: const Duration(milliseconds: 40),
    );
    addTearDown(radio.dispose);

    await radio.refresh();
    expect(radio.value.available, isTrue);
    expect(radio.value.on, isFalse);

    await radio.setOn(true, frequencyKhz: 95500);
    expect(seen.last, {'op': 'fm', 'on': true, 'frequency_khz': 95500});
    expect(
      radio.value,
      const FmRadioReading(
        available: true,
        on: true,
        frequencyKhz: 95500,
        rssi: -71,
        stereo: true,
        programName: 'WXYZ',
        radioText: 'Around the world',
        pi: 0x1234,
        pty: 10,
      ),
    );

    await radio.tune(95600);
    expect(seen.last, {'op': 'fm', 'frequency_khz': 95600});
    expect(radio.value.frequencyKhz, 95600);

    await radio.seek(FmSeekDirection.up);
    expect(seen.last, {'op': 'fm', 'seek': 1});
    expect(radio.value.frequencyKhz, 100100);

    await radio.seek(FmSeekDirection.down);
    expect(seen.last, {'op': 'fm', 'seek': -1});
    expect(radio.value.frequencyKhz, 95500);

    await radio.setOn(false);
    expect(seen.last, {'op': 'fm', 'on': false});
    expect(radio.value.on, isFalse);
    expect(radio.value.rssi, isNull);
  });
}
