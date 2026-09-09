/// How far along the radio is.
enum WifiStatus {
  /// The radio is switched off.
  off,

  /// On, and looking.
  disconnected,

  /// On a network.
  connected,
}

class WifiReading {
  const WifiReading({
    this.status = WifiStatus.off,
    this.network,
    this.bars = 0,
  });

  static const off = WifiReading();

  final WifiStatus status;

  /// What it is on, when it is on one.
  final String? network;

  /// Signal, 0-3.
  final int bars;

  @override
  bool operator ==(Object other) =>
      other is WifiReading &&
      other.status == status &&
      other.network == network &&
      other.bars == bars;

  @override
  int get hashCode => Object.hash(status, network, bars);
}

/// How far along the other radio is.
enum BluetoothStatus {
  /// Switched off.
  off,

  /// On, with nothing paired at hand.
  on,

  /// On, with a device connected.
  connected,
}

class BluetoothReading {
  const BluetoothReading({this.status = BluetoothStatus.off, this.device});

  static const off = BluetoothReading();

  final BluetoothStatus status;

  /// What it is talking to, when it is.
  final String? device;

  @override
  bool operator ==(Object other) =>
      other is BluetoothReading &&
      other.status == status &&
      other.device == device;

  @override
  int get hashCode => Object.hash(status, device);
}

/// The card in the slot, if there is one.
class WifiNetwork {
  const WifiNetwork(
    this.ssid, {
    this.id,
    this.bars = 0,
    this.security = '',
    this.connected = false,
  });
  final String ssid;
  final String? id;
  final int bars;
  final String security;
  final bool connected;
  bool get secured => security.contains('WPA') || security.contains('WEP');
  bool get supported =>
      !security.contains('EAP') &&
      !security.contains('WEP') &&
      (!security.contains('SAE') || security.contains('PSK'));
}

class BluetoothDevice {
  const BluetoothDevice(
    this.address,
    this.name, {
    this.paired = false,
    this.connected = false,
  });
  final String address;
  final String name;
  final bool paired;
  final bool connected;
}

abstract class RadioBackend {
  WifiReading wifi = WifiReading.off;
  BluetoothReading bluetooth = BluetoothReading.off;
  List<WifiNetwork> networks = [];
  List<BluetoothDevice> devices = [];
  String? wifiError;
  String? bluetoothError;
  Future<void> refresh({bool scan = false});
  Future<void> enableWifi(bool enabled);
  Future<void> join(WifiNetwork network, String password);
  Future<void> disconnectWifi();
  Future<void> forgetWifi(WifiNetwork network);
  Future<void> enableBluetooth(bool enabled);
  Future<void> connectBluetooth(BluetoothDevice device);
  Future<void> disconnectBluetooth(BluetoothDevice device);
  Future<void> forgetBluetooth(BluetoothDevice device);
}

class RadioFailure implements Exception {
  const RadioFailure(this.message);
  final String message;
}
