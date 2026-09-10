export 'package:daemon_client/src/radio_backend.dart'
    show WifiStatus, WifiReading, BluetoothStatus, BluetoothReading;
import 'package:tomeui/tomeui.dart';

/// What the charger and the gauge say.
@immutable
class BatteryReading {
  const BatteryReading({this.percent, this.charging = false});

  /// Nothing to ask: a desktop run, or the driver isn't up. The bar shows
  /// dashes rather than a stale number.
  static const unknown = BatteryReading();

  /// 0-100, or null when there is no supply to read.
  final int? percent;

  final bool charging;

  @override
  bool operator ==(Object other) =>
      other is BatteryReading &&
      other.percent == percent &&
      other.charging == charging;

  @override
  int get hashCode => Object.hash(percent, charging);
}

@immutable
class StorageReading {
  const StorageReading({
    this.present = false,
    this.label,
    this.path,
    this.busy = false,
  });

  /// An empty slot.
  static const empty = StorageReading();

  final bool present;

  /// False is observed idle; null is unknown. Neither guarantees safe removal.
  final bool? busy;

  /// What the card calls itself.
  final String? label;

  /// Where the card's contents come from on the host, for anything that
  /// has to say so. Null for a card that is being stood in for rather than
  /// mounted from somewhere.
  ///
  /// The card itself is not reached through here: it is mounted into the
  /// machine at [Places.sdCard], like the device's is.
  final String? path;

  @override
  bool operator ==(Object other) =>
      other is StorageReading &&
      other.present == present &&
      other.label == label &&
      other.path == path &&
      other.busy == busy;

  @override
  int get hashCode => Object.hash(present, label, path, busy);
}
