import 'dart:async';
import 'dart:io';

import 'package:daemon_client/daemon_client.dart';

/// Owns periodic battery and mount observations for all UI clients.
final class DeviceMonitor {
  DeviceMonitor({
    Tempod? native,
    this.mountsPath = '/proc/mounts',
    this.period = const Duration(seconds: 5),
  }) : _native = native ?? Tempod();
  final Tempod _native;
  final String mountsPath;
  final Duration period;
  DeviceSnapshot snapshot = const DeviceSnapshot();
  final _changes = StreamController<DeviceSnapshot>.broadcast(sync: true);
  Stream<DeviceSnapshot> get changes => _changes.stream;
  Timer? _timer;
  Future<void>? _reading;
  bool _closed = false;

  void start() {
    if (_closed || _timer != null) return;
    unawaited(refresh());
    _timer = Timer.periodic(period, (_) => unawaited(refresh()));
  }

  Future<void> refresh() =>
      _reading ??= _refresh().whenComplete(() => _reading = null);
  Future<void> _refresh() async {
    // Battery I/O remains in the native control service; Dart owns scheduling.
    int? percent;
    var charging = false;
    String? path;
    try {
      final sample = await _native.request({'op': 'battery'});
      final capacity = sample['capacity'];
      if (capacity is num) percent = capacity.round().clamp(0, 100);
      charging = sample['charging'] == true;
    } catch (_) {
      /* No native service: publish unknown battery. */
    }
    try {
      for (final line in await File(mountsPath).readAsLines()) {
        final fields = line.split(' ');
        if (fields.length >= 2 &&
            RegExp(r'^/dev/mmcblk1(?:p\d+)?$').hasMatch(fields[0])) {
          path = fields[1].replaceAllMapped(
            RegExp(r'\\([0-7]{3})'),
            (m) => String.fromCharCode(int.parse(m[1]!, radix: 8)),
          );
          break;
        }
      }
    } catch (_) {
      /* Mount information unavailable. */
    }
    if (!_closed) {
      snapshot = DeviceSnapshot(
        batteryPercent: percent,
        charging: charging,
        cardPath: path,
      );
      _changes.add(snapshot);
    }
  }

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    await _reading;
    await _changes.close();
  }
}
