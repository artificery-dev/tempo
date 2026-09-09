import 'dart:async';
import 'package:daemon_client/daemon_client.dart';
import 'package:tempod/src/services/radio_host.dart';
import 'package:test/test.dart';
import 'package:tempod/tempod.dart';

class Backend extends RadioBackend {
  int reads = 0;
  final calls = <String>[];
  Completer<void>? pending;
  @override
  Future<void> refresh({bool scan = false}) async {
    reads++;
    await pending?.future;
    networks = [const WifiNetwork('Known', id: '7', security: 'WPA2-PSK')];
    devices = [const BluetoothDevice('AA:BB:CC:DD:EE:FF', 'Known')];
  }

  @override
  Future<void> join(WifiNetwork n, String password) async =>
      calls.add('join:${n.id}');
  @override
  Future<void> connectBluetooth(BluetoothDevice d) async =>
      calls.add('connect:${d.name}');
  @override
  Future<void> disconnectBluetooth(BluetoothDevice d) async {}
  @override
  Future<void> forgetBluetooth(BluetoothDevice d) async {}
  @override
  Future<void> disconnectWifi() async {}
  @override
  Future<void> enableWifi(bool enabled) async {}
  @override
  Future<void> enableBluetooth(bool enabled) async {}
  @override
  Future<void> forgetWifi(WifiNetwork n) async {}
}

void main() {
  test('authenticated transport roundtrip and rejected caller', () async {
    final backend = Backend();
    final player = DemoPlayer();
    final server = PlayerServer(
      player: player,
      token: 'test-radio-token',
      radios: RadioHost(backend: backend),
    );
    await server.start();
    addTearDown(() async {
      await server.close();
      await player.close();
    });
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    final denied = RadioClient(baseUri: base, token: 'wrong');
    await expectLater(denied.refresh(), throwsA(isA<RadioFailure>()));
    expect(backend.reads, 0);
    final client = RadioClient(baseUri: base, token: 'test-radio-token');
    await client.refresh();
    expect(client.networks.single.ssid, 'Known');
    expect(client.devices.single.address, 'AA:BB:CC:DD:EE:FF');
    await client.join(client.networks.single, '12345678');
    expect(backend.calls, ['join:7']);
  });
  test('only typed operations and fields reach the backend', () async {
    final backend = Backend();
    final host = RadioHost(backend: backend);
    for (final command in [
      {'operation': 'exec', 'executable': 'sh'},
      {'operation': 'refresh', 'scan': 'yes'},
      {'operation': 'bluetooth.connect', 'address': r'$(touch bad)'},
      {'operation': 'wifi.enable', 'enabled': true, 'extra': true},
    ]) {
      await expectLater(host.execute(command), throwsFormatException);
    }
    expect(backend.reads, 0);
  });
  test(
    'mutations resolve current identities rather than trusting caller IDs',
    () async {
      final backend = Backend();
      final host = RadioHost(backend: backend);
      await host.execute({
        'operation': 'wifi.join',
        'ssid': 'Known',
        'password': '12345678',
      });
      await host.execute({
        'operation': 'bluetooth.connect',
        'address': 'aa:bb:cc:dd:ee:ff',
      });
      expect(backend.calls, ['join:7', 'connect:Known']);
      await expectLater(
        host.execute({'operation': 'wifi.forget', 'ssid': 'Absent'}),
        throwsA(isA<RadioFailure>()),
      );
    },
  );
  test('concurrent hardware operations cannot interleave', () async {
    final backend = Backend()..pending = Completer<void>();
    final host = RadioHost(backend: backend);
    final first = host.execute({'operation': 'refresh'});
    await expectLater(
      host.execute({'operation': 'wifi.enable', 'enabled': false}),
      throwsA(isA<RadioFailure>()),
    );
    backend.pending!.complete();
    expect((await first)['networks'], hasLength(1));
    expect(backend.reads, 1);
  });
}
