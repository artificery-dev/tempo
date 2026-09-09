import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'radio_backend.dart';

/// Typed radio transport. Hardware commands only run in the daemon process.
class RadioClient extends RadioBackend {
  RadioClient({required this.baseUri, required this.token});
  factory RadioClient.fromEnvironment() {
    final file = Platform.environment['TEMPOD_API_TOKEN_FILE'];
    String token = Platform.environment['TEMPOD_API_TOKEN'] ?? '';
    if (file != null) {
      try {
        token = File(file).readAsStringSync();
      } on FileSystemException {
        token = '';
      }
    }
    return RadioClient(
      baseUri: Uri.parse(
        Platform.environment['TEMPOD_API_URL'] ?? 'http://127.0.0.1:8765',
      ),
      token: token.trim(),
    );
  }
  final Uri baseUri;
  final String token;

  Future<void> _call(
    String operation, [
    Map<String, Object?> fields = const {},
  ]) async {
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      await (() async {
        final request = await http.postUrl(baseUri.resolve('/api/v1/radios'));
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode({'operation': operation, ...fields}));
        final response = await request.close();
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 1024 * 1024) {
            throw const RadioFailure('Radio response too large.');
          }
          bytes.addAll(chunk);
        }
        final data = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        if (response.statusCode != 200) {
          final error = data['error'];
          if (error is Map &&
              error['code'] == 'radio_failed' &&
              error['message'] is String) {
            throw RadioFailure(error['message'] as String);
          }
          throw const RadioFailure('Radio service unavailable.');
        }
        wifi = WifiReading(
          status: WifiStatus.values.byName(data['wifi']['status'] as String),
          network: data['wifi']['network'] as String?,
          bars: data['wifi']['bars'] as int,
        );
        bluetooth = BluetoothReading(
          status: BluetoothStatus.values.byName(
            data['bluetooth']['status'] as String,
          ),
          device: data['bluetooth']['device'] as String?,
        );
        networks = [
          for (final n in data['networks'] as List)
            WifiNetwork(
              n['ssid'] as String,
              id: n['id'] as String?,
              bars: n['bars'] as int,
              security: n['security'] as String,
              connected: n['connected'] as bool,
            ),
        ];
        devices = [
          for (final d in data['devices'] as List)
            BluetoothDevice(
              d['address'] as String,
              d['name'] as String,
              paired: d['paired'] as bool,
              connected: d['connected'] as bool,
            ),
        ];
        wifiError = data['wifiError'] as String?;
        bluetoothError = data['bluetoothError'] as String?;
      })().timeout(const Duration(seconds: 55));
    } on RadioFailure {
      rethrow;
    } on Object {
      throw const RadioFailure('Radio service unavailable.');
    } finally {
      http.close(force: true);
    }
  }

  @override
  Future<void> refresh({bool scan = false}) => _call('refresh', {'scan': scan});
  @override
  Future<void> enableWifi(bool enabled) =>
      _call('wifi.enable', {'enabled': enabled});
  @override
  Future<void> join(WifiNetwork network, String password) =>
      _call('wifi.join', {'ssid': network.ssid, 'password': password});
  @override
  Future<void> disconnectWifi() => _call('wifi.disconnect');
  @override
  Future<void> forgetWifi(WifiNetwork network) =>
      _call('wifi.forget', {'ssid': network.ssid});
  @override
  Future<void> enableBluetooth(bool enabled) =>
      _call('bluetooth.enable', {'enabled': enabled});
  @override
  Future<void> connectBluetooth(BluetoothDevice device) =>
      _call('bluetooth.connect', {'address': device.address});
  @override
  Future<void> disconnectBluetooth(BluetoothDevice device) =>
      _call('bluetooth.disconnect', {'address': device.address});
  @override
  Future<void> forgetBluetooth(BluetoothDevice device) =>
      _call('bluetooth.forget', {'address': device.address});
}
