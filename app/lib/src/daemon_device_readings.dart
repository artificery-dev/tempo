import 'dart:async';

import 'package:daemon_client/daemon_client.dart';
import 'package:flutter/foundation.dart';
import 'package:tempo_core/tempo_core.dart';

/// UI listenables over daemon observations. No sysfs or mount access in the UI.
final class DaemonDeviceReadings {
  DaemonDeviceReadings(this.client) {
    _subscription = client.changes.listen(_adopt);
    _adopt(client.snapshot);
    client.start();
  }
  final DeviceClient client;
  final battery = ValueNotifier<BatteryReading>(BatteryReading.unknown);
  final storage = ValueNotifier<StorageReading>(StorageReading.empty);
  late final StreamSubscription<DeviceSnapshot> _subscription;
  bool _mediaBusy = true;
  void setMediaBusy(bool value) {
    _mediaBusy = value;
    _adopt(client.snapshot);
  }

  void _adopt(DeviceSnapshot state) {
    battery.value = BatteryReading(
      percent: state.batteryPercent,
      charging: state.charging,
    );
    storage.value = state.cardPath == null
        ? StorageReading.empty
        : StorageReading(
            present: true,
            label: 'SD card',
            path: state.cardPath,
            busy: _mediaBusy || state.cardIoBusy == true
                ? true
                : state.cardIoBusy,
          );
  }

  Future<void> close() async {
    await _subscription.cancel();
    await client.close();
    battery.dispose();
    storage.dispose();
  }
}
