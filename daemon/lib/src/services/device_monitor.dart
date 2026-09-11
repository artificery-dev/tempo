import 'dart:async';
import 'dart:io';

import 'package:daemon_client/daemon_client.dart';

/// Owns periodic battery and mount observations for all UI clients.
final class DeviceMonitor {
  DeviceMonitor({
    Tempod? native,
    this.mountsPath = '/proc/mounts',
    this.mountInfoPath = '/proc/self/mountinfo',
    this.cardIdentityPath = '/sys/class/block/mmcblk1/device/cid',
    this.cardStatsPath = '/sys/class/block/mmcblk1/stat',
    this.period = const Duration(seconds: 1),
  }) : _native = native ?? Tempod();
  final Tempod _native;
  final String mountsPath, mountInfoPath, cardIdentityPath, cardStatsPath;
  String? _previousStats, _previousMount;
  String? cardIdentity;
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
    String? mountId;
    if (path != null) {
      try {
        for (final line in await File(mountInfoPath).readAsLines()) {
          final fields = line.split(' ');
          final separator = fields.indexOf('-');
          if (fields.length < 7 ||
              separator < 6 ||
              separator + 2 >= fields.length) {
            continue;
          }
          final mountedAt = fields[4].replaceAllMapped(
            RegExp(r'\\([0-7]{3})'),
            (m) => String.fromCharCode(int.parse(m[1]!, radix: 8)),
          );
          if (mountedAt == path &&
              RegExp(
                r'^/dev/mmcblk1(?:p\d+)?$',
              ).hasMatch(fields[separator + 2]) &&
              int.tryParse(fields[0]) != null) {
            mountId = fields[0];
            break;
          }
        }
      } catch (_) {
        // Preserve unknown: a bare mount directory is not proof of a card.
      }
    }
    String? identity;
    if (path != null) {
      try {
        final cid = (await File(cardIdentityPath).readAsString()).trim();
        if (RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(cid)) {
          identity = cid.toLowerCase();
        }
      } catch (_) {
        // No physical identity: Cadence must revalidate this root's cache.
      }
    }
    bool? ioBusy;
    if (path != null && mountId != null) {
      try {
        final values = (await File(
          cardStatsPath,
        ).readAsString()).trim().split(RegExp(r'\s+')).map(int.parse).toList();
        if (values.length < 11 || values.any((v) => v < 0)) {
          throw const FormatException('Invalid block statistics');
        }
        final counters = values.join(',');
        ioBusy = values[8] > 0
            ? true
            : _previousMount == mountId && _previousStats != null
            ? counters != _previousStats
            : null;
        _previousStats = counters;
        _previousMount = mountId;
      } catch (_) {
        _previousStats = null;
        _previousMount = null;
      }
    } else {
      _previousStats = null;
      _previousMount = null;
    }
    if (!_closed) {
      cardIdentity = identity ?? (path == null ? null : mountId ?? path);
      snapshot = DeviceSnapshot(
        batteryPercent: percent,
        charging: charging,
        cardPath: path,
        cardMountId: mountId,
        cardSourceId: identity,
        cardIoBusy: ioBusy,
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
