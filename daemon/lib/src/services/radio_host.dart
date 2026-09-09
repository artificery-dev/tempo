import 'package:daemon_client/daemon_client.dart';
import 'host_radios.dart';

/// Serializes typed radio operations and resolves identities against host state.
class RadioHost {
  RadioHost({RadioBackend? backend}) : backend = backend ?? HostRadios();
  final RadioBackend backend;
  bool _busy = false;

  Future<Map<String, Object?>> execute(Object? value) async {
    if (_busy) throw const RadioFailure('A radio operation is in progress.');
    if (value is! Map<String, dynamic> || value['operation'] is! String) {
      throw const FormatException('Invalid radio command.');
    }
    final operation = value['operation'] as String;
    final allowed = switch (operation) {
      'refresh' => {'operation', 'scan'},
      'wifi.enable' || 'bluetooth.enable' => {'operation', 'enabled'},
      'wifi.join' => {'operation', 'ssid', 'password'},
      'wifi.forget' => {'operation', 'ssid'},
      'bluetooth.connect' ||
      'bluetooth.disconnect' ||
      'bluetooth.forget' => {'operation', 'address'},
      'wifi.disconnect' => {'operation'},
      _ => throw const FormatException('Unknown radio operation.'),
    };
    if (value.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException('Unexpected radio field.');
    }
    bool flag(String key, {bool? fallback}) {
      final field = value[key] ?? fallback;
      if (field is! bool) throw const FormatException('Invalid radio flag.');
      return field;
    }

    String text(String key, int max) {
      final field = value[key];
      if (field is! String || field.length > max || field.contains('\u0000')) {
        throw const FormatException('Invalid radio text.');
      }
      return field;
    }

    // Validate before running even a read command on malformed requests.
    final enabled = operation.endsWith('.enable') ? flag('enabled') : false;
    final scan = operation == 'refresh' ? flag('scan', fallback: false) : false;
    final ssid = operation == 'wifi.join' || operation == 'wifi.forget'
        ? text('ssid', 32)
        : null;
    final password = operation == 'wifi.join' ? text('password', 63) : '';
    final address = allowed.contains('address') ? text('address', 17) : null;
    if (address != null &&
        !RegExp(r'^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$').hasMatch(address)) {
      throw const FormatException('Invalid Bluetooth address.');
    }
    _busy = true;
    try {
      if (operation == 'refresh') {
        await backend.refresh(scan: scan);
      } else {
        await backend.refresh();
        WifiNetwork network() => backend.networks.firstWhere(
          (n) => n.ssid == ssid,
          orElse: () =>
              throw const RadioFailure('Network is no longer available.'),
        );
        BluetoothDevice device() => backend.devices.firstWhere(
          (d) => d.address.toUpperCase() == address!.toUpperCase(),
          orElse: () =>
              throw const RadioFailure('Device is no longer available.'),
        );
        switch (operation) {
          case 'wifi.enable':
            await backend.enableWifi(enabled);
          case 'wifi.join':
            await backend.join(network(), password);
          case 'wifi.disconnect':
            await backend.disconnectWifi();
          case 'wifi.forget':
            await backend.forgetWifi(network());
          case 'bluetooth.enable':
            await backend.enableBluetooth(enabled);
          case 'bluetooth.connect':
            await backend.connectBluetooth(device());
          case 'bluetooth.disconnect':
            await backend.disconnectBluetooth(device());
          case 'bluetooth.forget':
            await backend.forgetBluetooth(device());
        }
        await backend.refresh();
      }
      return {
        'wifi': {
          'status': backend.wifi.status.name,
          'network': backend.wifi.network,
          'bars': backend.wifi.bars,
        },
        'bluetooth': {
          'status': backend.bluetooth.status.name,
          'device': backend.bluetooth.device,
        },
        'networks': [
          for (final n in backend.networks)
            {
              'ssid': n.ssid,
              'id': n.id,
              'bars': n.bars,
              'security': n.security,
              'connected': n.connected,
            },
        ],
        'devices': [
          for (final d in backend.devices)
            {
              'address': d.address,
              'name': d.name,
              'paired': d.paired,
              'connected': d.connected,
            },
        ],
        'wifiError': backend.wifiError,
        'bluetoothError': backend.bluetoothError,
      };
    } finally {
      _busy = false;
    }
  }
}
