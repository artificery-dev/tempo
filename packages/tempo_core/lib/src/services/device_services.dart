import 'dart:async';
import 'dart:io';

import 'package:file/local.dart';
import 'package:tomeui/tomeui.dart';

import '../storage/places.dart';
import 'readings.dart';
import 'tempod.dart';

/// The battery, as tempod reports it.
///
/// tempod reads the PMIC's gauge (mt6323-battery) when asked - a few sysfs
/// reads - so the charger's plug shows within a poll, not a sampling
/// interval late. Asked every five seconds while anything shows it. When
/// the daemon cannot be reached, the reading becomes unknown. The app uses
/// daemon observations; this adapter preserves the native control fallback.
class DeviceBattery extends ValueNotifier<BatteryReading> with _Polls {
  DeviceBattery({Tempod? tempod})
    : _tempod = tempod ?? Tempod(),
      super(BatteryReading.unknown);

  final Tempod _tempod;

  @override
  Duration get period => const Duration(seconds: 5);

  @override
  Future<void> read() async {
    BatteryReading reading;
    try {
      final sample = await _tempod.request({'op': 'battery'});
      reading = BatteryReading(
        percent: switch (sample['capacity']) {
          final int capacity => capacity,
          final num capacity => capacity.round(),
          _ => null,
        },
        charging: sample['charging'] == true,
      );
    } on Object {
      reading = BatteryReading.unknown;
    }
    publish(reading);
  }
}

/// The radio, as the kernel reports it.
///
/// Off, until there is a radio: the Y2's wifi part has no mainline driver
/// yet, so the honest reading is that it is not on. When one lands this is
/// where it is read - the UI above it needs no change.
class DeviceWifi extends ValueNotifier<WifiReading> {
  DeviceWifi() : super(WifiReading.off);
}

/// The other radio, as the kernel reports it: off, like the wifi, until
/// the MediaTek combo part has a driver. Then bluetoothctl through tempod.
class DeviceBluetooth extends ValueNotifier<BluetoothReading> {
  DeviceBluetooth() : super(BluetoothReading.off);
}

/// Unknown storage until the app supplies daemon observations. The emulator
/// supplies its own mounted-folder reading.
class DeviceStorage extends ValueNotifier<StorageReading> {
  DeviceStorage() : super(StorageReading.empty);
}

/// A reading taken again every so often, but only while somebody is
/// listening: a service nobody is watching has no business waking the
/// machine up, and a test that pumps a screen and throws it away should not
/// be left holding a timer.
mixin _Polls<T> on ValueNotifier<T> {
  Duration get period;

  Future<void> read();

  Timer? _timer;
  bool _disposed = false;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    if (_timer != null || _disposed) return;
    unawaited(read());
    _timer = Timer.periodic(period, (_) => read());
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (hasListeners) return;
    _timer?.cancel();
    _timer = null;
  }

  /// Publish a reading, unless the answer arrived after everyone stopped
  /// caring - an await outlives the widget that started it.
  void publish(T reading) {
    if (_disposed || reading == value) return;
    value = reading;
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

/// The machine, as the device has it: the real filesystem, the card where
/// the system mounts it, and the player's own storage under the user it
/// runs as.
class DevicePlaces extends ValueNotifier<Places> {
  DevicePlaces([Places? initial]) : super(initial ?? _local);

  static final _local = Places(
    fileSystem: const LocalFileSystem(),
    home: Platform.environment['HOME'] ?? '/root',
    config: _xdgConfig,
    data: _xdgData,
  );

  /// `$XDG_CONFIG_HOME/tempo` when the session sets it; null lets [Places]
  /// fall back to `.config/tempo` under the home, which is what
  /// XDG_CONFIG_HOME defaults to anyway.
  static String get _xdgData {
    final home = Platform.environment['HOME'] ?? '/root';
    final base = Platform.environment['XDG_DATA_HOME'];
    return '${base == null || base.isEmpty ? '$home/.local/share' : base}/tempo';
  }

  static String? get _xdgConfig {
    final base = Platform.environment['XDG_CONFIG_HOME'];
    return base == null || base.isEmpty ? null : '$base/tempo';
  }
}
