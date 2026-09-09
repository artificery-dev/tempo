import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tempo_core/tempo_core.dart';

import 'mock_fm_radio.dart';

/// Stable receiver identity: an active Now Playing session follows provider
/// changes without retaining the previous tuner or overlapping audio streams.
class EmulatorFmRadio extends ValueNotifier<FmRadioReading>
    implements FmRadioService {
  EmulatorFmRadio({
    required this.live,
    Future<bool> Function()? checkAttached,
    bool watch = true,
    MockFmRadio? mock,
  }) : mock = mock ?? MockFmRadio(),
       _checkAttached = checkAttached ?? (() async => false),
       super(
         const FmRadioReading(available: true, on: false, frequencyKhz: 95500),
       ) {
    this.mock.addListener(_readingChanged);
    if (watch) {
      unawaited(checkHardware());
      _poll = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(checkHardware()),
      );
    }
  }

  final FmRadioService live;
  final MockFmRadio mock;
  final Future<bool> Function() _checkAttached;
  // Settings persistence watches configuration only, not every RDS message.
  final configuration = ValueNotifier<int>(0);
  Timer? _poll;
  bool _attached = false;
  bool _preferMock = false;
  bool _usingMock = true;
  bool _disposed = false;
  bool _checking = false;
  Future<void>? _transition;

  bool get attached => _attached;
  bool get mocked => _usingMock;
  bool get preferMock => _preferMock;
  bool get busy => _transition != null;
  bool get canToggle => attached && !busy;
  FmRadioService get _receiver => _usingMock ? mock : live;
  void _configurationChanged() {
    if (!_disposed) configuration.value++;
  }

  void _readingChanged() {
    if (!_disposed) value = _receiver.value;
  }

  Future<void> checkHardware() async {
    if (_checking || _disposed) return;
    _checking = true;
    try {
      final found = await _checkAttached();
      if (_disposed) return;
      if (found != _attached) {
        _attached = found;
        _configurationChanged();
      }
      await _reconcile();
    } on FileSystemException {
      if (!_disposed) {
        _attached = false;
        _configurationChanged();
        await _reconcile();
      }
    } finally {
      _checking = false;
    }
  }

  Future<void> setMocked(bool mocked) async {
    if (!canToggle) return;
    await restorePreference(mocked);
  }

  /// Restoring a preference never bypasses the physical-device requirement.
  Future<void> restorePreference(bool mocked) async {
    _preferMock = mocked;
    _configurationChanged();
    await _reconcile();
  }

  Future<void> _reconcile() {
    if (_disposed) return Future.value();
    if (_transition case final pending?) return pending;
    if (_usingMock == (_preferMock || !_attached)) return Future.value();
    final switching = _switch();
    _transition = switching;
    _configurationChanged();
    return switching.whenComplete(() {
      _transition = null;
      _configurationChanged();
    });
  }

  Future<void> _switch() async {
    while (!_disposed && _usingMock != (_preferMock || !_attached)) {
      final previous = _receiver;
      final reading = value;
      previous.removeListener(_readingChanged);
      // RtlFmRadio cancels pending tunes/scans when asked to stop.
      await previous.setOn(false);
      if (_disposed) return;
      _usingMock = _preferMock || !_attached;
      await _receiver.setOn(reading.on, frequencyKhz: reading.frequencyKhz);
      if (_disposed) return;
      _receiver.addListener(_readingChanged);
      _readingChanged();
    }
  }

  Future<void> _withReceiver(
    Future<void> Function(FmRadioService) operation,
  ) async {
    while (_transition != null) {
      await _transition;
    }
    if (!_disposed) await operation(_receiver);
  }

  @override
  Future<void> setOn(bool on, {int? frequencyKhz}) =>
      _withReceiver((radio) => radio.setOn(on, frequencyKhz: frequencyKhz));
  @override
  Future<void> tune(int frequencyKhz) =>
      _withReceiver((radio) => radio.tune(frequencyKhz));
  @override
  Future<void> seek(FmSeekDirection direction) =>
      _withReceiver((radio) => radio.seek(direction));
  @override
  Future<void> refresh() async {
    await checkHardware();
    await _withReceiver((radio) => radio.refresh());
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _poll?.cancel();
    _receiver.removeListener(_readingChanged);
    mock.dispose();
    if (live is FmRadioSwitch) (live as FmRadioSwitch).dispose();
    configuration.dispose();
    super.dispose();
  }
}
