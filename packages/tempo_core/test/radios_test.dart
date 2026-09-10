import 'package:tempod/src/services/host_radios.dart';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/src/services/radios.dart';

void main() {
  test('mock connect, forget and power update status and lists', () async {
    final radios = RadioService();
    addTearDown(radios.dispose);
    await radios.refresh();
    expect(radios.wifi.value.network, 'Neon Bramble');
    final n = radios.networks.last;
    await radios.join(n, password: 'short');
    expect(radios.error, contains('8 characters'));
    await radios.join(n, password: 'password123');
    expect(radios.wifi.value.network, n.ssid);
    await radios.forgetWifi(radios.networks.last);
    expect(radios.wifi.value.status, WifiStatus.disconnected);
    expect(radios.networks.last.id, isNull);
    await radios.enableWifi(false);
    await radios.join(n, password: 'password123');
    expect(radios.error, contains('Turn on'));
    await radios.enableBluetooth(false);
    expect(radios.devices.any((d) => d.connected), isFalse);
    await radios.enableBluetooth(true);
    await radios.connectBluetooth(radios.devices.last);
    expect(radios.bluetooth.value.device, 'Pocket Headphones');
    await radios.forgetBluetooth(radios.devices.last);
    expect(radios.devices.last.paired, isFalse);
  });

  test('Host selection reads only and preserves mock state', () async {
    final calls = <String>[];
    final radios = RadioService(
      host: HostRadios(
        interface: 'wlan0',
        command: (exe, args, {input}) async {
          calls.add('$exe ${args.join(' ')}');
          if (args.last == 'status') return 'wpa_state=DISCONNECTED';
          if (args.last == 'show') {
            return 'Controller AA:BB:CC:DD:EE:FF Host\nPowered: no';
          }
          return '';
        },
      ),
    );
    addTearDown(radios.dispose);
    await radios.refresh();
    await radios.setMode(RadioMode.host);
    expect(radios.wifi.value.status, WifiStatus.disconnected);
    expect(
      calls.any(
        (c) =>
            c.contains('power') ||
            c.contains('networkctl') ||
            c.contains('scan on'),
      ),
      isFalse,
    );
    expect(
      calls.any((c) => c.contains('--timeout')),
      isFalse,
      reason:
          'BlueZ status reads should exit immediately, not wait for a scan timeout',
    );
    await radios.setMode(RadioMode.mocked);
    expect(radios.wifi.value.network, 'Neon Bramble');
  });

  test('Wi-Fi failure does not suppress Bluetooth or leak fake data', () async {
    final host = HostRadios(
      interface: 'wlan0',
      command: (exe, args, {input}) async {
        if (exe == 'wpa_cli') throw const RadioFailure('Missing supplicant');
        if (args.last == 'show') {
          return 'Controller AA:BB:CC:DD:EE:FF Host\nPowered: yes';
        }
        if (args.last == 'devices') return 'Device AA:BB:CC:DD:EE:00 Real Buds';
        return 'Paired: yes\nConnected: yes\n'
            'UUID: Audio Sink (0000110b-0000-1000-8000-00805f9b34fb)';
      },
    );
    await host.refresh();
    expect(host.wifiError, 'Missing supplicant');
    expect(host.networks, isEmpty);
    expect(host.bluetoothError, isNull);
    expect(host.bluetooth.device, 'Real Buds');
  });

  test('Bluetooth scan and results are limited to A2DP sinks', () async {
    final calls = <(String, List<String>)>[];
    List<String>? scanFilters;
    Duration? scanDuration;
    final host = HostRadios(
      interface: 'wlan0',
      bluetoothScan: (filters, duration) async {
        scanFilters = filters;
        scanDuration = duration;
      },
      command: (exe, args, {input}) async {
        calls.add((exe, args));
        if (exe == 'wpa_cli') throw const RadioFailure('No Wi-Fi');
        if (args.last == 'show') {
          return 'Controller AA:BB:CC:DD:EE:FF Host\nPowered: yes';
        }
        if (args.last == 'devices') {
          return 'Device 88:D0:39:43:2A:8A Speaker\n'
              'Device AA:BB:CC:DD:EE:00 Keyboard';
        }
        if (args.last == '88:D0:39:43:2A:8A') {
          return 'Paired: yes\nConnected: no\n'
              'UUID: Audio Sink (0000110b-0000-1000-8000-00805f9b34fb)';
        }
        if (args.last == 'AA:BB:CC:DD:EE:00') {
          return 'Paired: yes\nConnected: no\n'
              'UUID: Human Interface Device '
              '(00001124-0000-1000-8000-00805f9b34fb)';
        }
        return '';
      },
    );

    await host.refresh(scan: true);

    expect(host.devices.map((device) => device.name), ['Speaker']);
    expect(scanFilters, [
      'transport bredr',
      'uuids 0000110b-0000-1000-8000-00805f9b34fb',
    ]);
    expect(scanDuration, const Duration(seconds: 5));
    expect(calls.any((call) => call.$2.contains('scan')), isFalse);
  });

  test('Bluetooth connects only the A2DP sink profile', () async {
    final calls = <(String, List<String>)>[];
    final host = HostRadios(
      command: (exe, args, {input}) async {
        calls.add((exe, args));
        return '';
      },
    );

    await host.connectBluetooth(
      const BluetoothDevice('88:d0:39:43:2a:8a', 'Speaker', paired: true),
    );

    expect(calls, hasLength(1));
    expect(calls.single.$1, 'busctl');
    expect(calls.single.$2, [
      'call',
      'org.bluez',
      '/org/bluez/hci0/dev_88_D0_39_43_2A_8A',
      'org.bluez.Device1',
      'ConnectProfile',
      's',
      '0000110b-0000-1000-8000-00805f9b34fb',
    ]);
  });

  test('scan parser deduplicates and preserves saved offline networks', () {
    final networks = HostRadios.parseNetworks(
      '00:11:22:33:44:55\t2412\t-80\t[WPA2-PSK-CCMP]\tHome\n'
          '00:11:22:33:44:66\t5180\t-40\t[WPA2-PSK-CCMP]\tHome\n'
          '00:11:22:33:44:77\t2412\t-65\t[ESS]\tCafe Guest',
      '0\tHome\tany\t[CURRENT]\n1\tOffline\tany\t',
      'Home',
    );
    expect(networks.map((n) => n.ssid), ['Home', 'Cafe Guest', 'Offline']);
    expect(networks.first.bars, 3);
    expect(networks.first.connected, isTrue);
    expect(networks.last.id, '1');
    expect(networks[1].secured, isFalse);
  });

  test(
    'join uses stdin credentials, association status, networkd and save',
    () async {
      final calls = <(String, List<String>, String?)>[];
      final host = HostRadios(
        interface: 'wlan0',
        command: (exe, args, {input}) async {
          calls.add((exe, args, input));
          if (exe == 'networkctl' && args.contains('list')) {
            return '2 wlan0 wlan routable configured';
          }
          if (args.last == 'add_network') return '4';
          if (args.last == 'status') {
            return 'wpa_state=COMPLETED\nid=4\nssid=Home';
          }
          return 'OK';
        },
      );
      const password = 'secret"\\password';
      await host.join(
        const WifiNetwork('Home', security: '[WPA2-PSK-CCMP]'),
        password,
      );
      expect(calls.any((c) => c.$2.join(' ').contains(password)), isFalse);
      expect(
        calls.singleWhere((c) => c.$3 != null).$3,
        contains('set_network 4 psk'),
      );
      expect(
        calls.any((c) => c.$1 == 'networkctl' && c.$2.first == 'renew'),
        isTrue,
      );
      expect(calls.last.$2.last, 'save_config');
    },
  );

  test(
    'failed new profile is removed; unmanaged host is never modified',
    () async {
      final calls = <List<String>>[];
      final host = HostRadios(
        interface: 'wlan0',
        command: (exe, args, {input}) async {
          calls.add(args);
          if (exe == 'networkctl') return '2 wlan0 wlan routable configured';
          if (args.last == 'add_network') return '7';
          if (args.contains('set_network')) throw const RadioFailure('Failed');
          return 'OK';
        },
      );
      await expectLater(
        host.join(const WifiNetwork('Cafe'), ''),
        throwsA(isA<RadioFailure>()),
      );
      expect(calls.last, ['-i', 'wlan0', 'remove_network', '7']);
      final unmanaged = HostRadios(
        interface: 'wlan0',
        command: (exe, args, {input}) async {
          expect(exe, 'networkctl');
          expect(args, contains('list'));
          return '2 wlan0 wlan routable unmanaged';
        },
      );
      await expectLater(
        unmanaged.enableWifi(false),
        throwsA(isA<RadioFailure>()),
      );
    },
  );

  test(
    'busy service ignores duplicate actions and tolerates disposal',
    () async {
      final pending = Completer<String>();
      var reads = 0;
      final radios = RadioService(
        mode: RadioMode.host,
        host: HostRadios(
          interface: 'wlan0',
          command: (exe, args, {input}) async {
            reads++;
            if (exe == 'wpa_cli') return pending.future;
            return '';
          },
        ),
      );
      final refresh = radios.refresh();
      await radios.setMode(RadioMode.mocked);
      await radios.enableBluetooth(true);
      expect(radios.mode, RadioMode.host);
      radios.dispose();
      pending.complete('wpa_state=DISCONNECTED');
      await refresh;
      expect(reads, 4);
    },
  );
}
