import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:daemon_client/daemon_client.dart';

export 'package:daemon_client/src/radio_backend.dart';

enum RadioMode { mocked, host }

/// One stable source for menus and status icons, including across mode changes.
/// Merely selecting Host reads state; saved UI settings never power host radios.
class RadioService extends ChangeNotifier {
  RadioService({this._mode = RadioMode.mocked, this._host});

  final _mock = MockRadios();
  RadioBackend? _host;
  RadioMode _mode;
  RadioMode get mode => _mode;
  WifiReading get mockedWifi => _mock.wifi;
  BluetoothReading get mockedBluetooth => _mock.bluetooth;
  RadioBackend get _backend => _mode == RadioMode.mocked
      ? _mock
      : (_host ??= RadioClient.fromEnvironment());
  final wifi = ValueNotifier(WifiReading.off);
  final bluetooth = ValueNotifier(BluetoothReading.off);
  List<WifiNetwork> get networks => List.unmodifiable(_backend.networks);
  List<BluetoothDevice> get devices => List.unmodifiable(_backend.devices);
  String? get wifiError => error ?? _backend.wifiError;
  String? get bluetoothError => error ?? _backend.bluetoothError;
  String? error;
  bool busy = false;
  bool _disposed = false;
  Timer? _poll;

  void start() {
    unawaited(refresh());
    _poll ??= Timer.periodic(
      const Duration(seconds: 10),
      (_) => unawaited(refresh()),
    );
  }

  Future<void> setMode(RadioMode mode) async {
    if (busy || mode == _mode) return;
    _mode = mode;
    error = null;
    _publish();
    await refresh();
  }

  void mockReadings({WifiReading? wifi, BluetoothReading? bluetooth}) {
    if (_mode != RadioMode.mocked) return;
    if (wifi != null) _mock.wifi = wifi;
    if (bluetooth != null) {
      _mock.bluetooth = bluetooth;
      _mock.devices = [
        for (final d in _mock.devices)
          BluetoothDevice(
            d.address,
            d.name,
            paired: d.paired,
            connected:
                bluetooth.status == BluetoothStatus.connected &&
                bluetooth.device == d.name,
          ),
      ];
    }
    _mock._updateNetworks();
    _publish();
  }

  void _publish() {
    if (_disposed) return;
    wifi.value = _backend.wifi;
    bluetooth.value = _backend.bluetooth;
    notifyListeners();
  }

  Future<void> _run(Future<void> Function(RadioBackend) action) async {
    if (busy || _disposed) return;
    busy = true;
    error = null;
    _publish();
    try {
      await action(_backend);
    } on Object catch (e) {
      error = e is RadioFailure
          ? e.message
          : 'Radio service unavailable. Check host services and permissions.';
    } finally {
      busy = false;
      _publish();
    }
  }

  Future<void> refresh({bool scan = false}) =>
      _run((b) => b.refresh(scan: scan));
  Future<void> _change(Future<void> Function(RadioBackend) action) =>
      _run((b) async {
        try {
          await action(b);
        } finally {
          await b.refresh();
        }
      });
  Future<void> enableWifi(bool on) => _change((b) => b.enableWifi(on));
  Future<void> join(WifiNetwork n, {String password = ''}) =>
      _change((b) => b.join(n, password));
  Future<void> disconnectWifi() => _change((b) => b.disconnectWifi());
  Future<void> forgetWifi(WifiNetwork n) => _change((b) => b.forgetWifi(n));
  Future<void> enableBluetooth(bool on) =>
      _change((b) => b.enableBluetooth(on));
  Future<void> connectBluetooth(BluetoothDevice d) =>
      _change((b) => b.connectBluetooth(d));
  Future<void> disconnectBluetooth(BluetoothDevice d) =>
      _change((b) => b.disconnectBluetooth(d));
  Future<void> forgetBluetooth(BluetoothDevice d) =>
      _change((b) => b.forgetBluetooth(d));

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    wifi.dispose();
    bluetooth.dispose();
    super.dispose();
  }
}

class MockRadios extends RadioBackend {
  MockRadios() {
    wifi = const WifiReading(
      status: WifiStatus.connected,
      network: 'Neon Bramble',
      bars: 3,
    );
    bluetooth = const BluetoothReading(
      status: BluetoothStatus.connected,
      device: 'Sundial Buds',
    );
    devices = const [
      BluetoothDevice(
        '00:11:22:33:44:55',
        'Sundial Buds',
        paired: true,
        connected: true,
      ),
      BluetoothDevice('00:11:22:33:44:66', 'Kitchen Speaker', paired: true),
      BluetoothDevice('00:11:22:33:44:77', 'Pocket Headphones'),
    ];
    _updateNetworks();
  }
  final _known = <String>{'Neon Bramble', 'Studio'};
  void _updateNetworks() {
    networks = [
      for (final (name, bars, security) in const [
        ('Neon Bramble', 3, '[WPA2-PSK-CCMP]'),
        ('Studio', 2, '[WPA2-PSK-CCMP]'),
        ('Cafe Guest', 1, ''),
        ('Moonbase', 2, '[WPA2-PSK-CCMP]'),
      ])
        WifiNetwork(
          name,
          id: _known.contains(name) ? name : null,
          bars: bars,
          security: security,
          connected:
              wifi.status == WifiStatus.connected && wifi.network == name,
        ),
    ];
  }

  @override
  Future<void> refresh({bool scan = false}) async {
    _updateNetworks();
  }

  @override
  Future<void> enableWifi(bool enabled) async {
    wifi = enabled
        ? const WifiReading(status: WifiStatus.disconnected)
        : WifiReading.off;
  }

  @override
  Future<void> join(WifiNetwork n, String password) async {
    if (wifi.status == WifiStatus.off) {
      throw const RadioFailure('Turn on Wi-Fi first.');
    }
    if (n.secured && n.id == null && password.length < 8) {
      throw const RadioFailure('Password must have at least 8 characters.');
    }
    _known.add(n.ssid);
    wifi = WifiReading(
      status: WifiStatus.connected,
      network: n.ssid,
      bars: n.bars,
    );
  }

  @override
  Future<void> disconnectWifi() async {
    wifi = const WifiReading(status: WifiStatus.disconnected);
  }

  @override
  Future<void> forgetWifi(WifiNetwork n) async {
    _known.remove(n.ssid);
    if (wifi.network == n.ssid) await disconnectWifi();
  }

  @override
  Future<void> enableBluetooth(bool enabled) async {
    bluetooth = enabled
        ? const BluetoothReading(status: BluetoothStatus.on)
        : BluetoothReading.off;
    if (!enabled) {
      devices = [
        for (final d in devices)
          BluetoothDevice(d.address, d.name, paired: d.paired),
      ];
    }
  }

  void _device(
    BluetoothDevice d, {
    required bool paired,
    required bool connected,
  }) {
    devices = [
      for (final old in devices)
        old.address == d.address
            ? BluetoothDevice(
                d.address,
                d.name,
                paired: paired,
                connected: connected,
              )
            : old,
    ];
    final active = devices.where((d) => d.connected);
    bluetooth = BluetoothReading(
      status: active.isEmpty ? BluetoothStatus.on : BluetoothStatus.connected,
      device: active.isEmpty ? null : active.first.name,
    );
  }

  @override
  Future<void> connectBluetooth(BluetoothDevice d) async {
    if (bluetooth.status == BluetoothStatus.off) {
      throw const RadioFailure('Turn on Bluetooth first.');
    }
    _device(d, paired: true, connected: true);
  }

  @override
  Future<void> disconnectBluetooth(BluetoothDevice d) async {
    _device(d, paired: d.paired, connected: false);
  }

  @override
  Future<void> forgetBluetooth(BluetoothDevice d) async {
    _device(d, paired: false, connected: false);
  }
}
