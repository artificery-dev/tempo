import 'dart:async';

import 'package:flutter/foundation.dart';

import 'tempod.dart';

/// Where the mixer sits: a level from 0 to 100 as the sound server shows
/// it, and whether it is muted.
@immutable
class VolumeReading {
  const VolumeReading({
    required this.level,
    this.muted = false,
    this.device,
    this.hardware = false,
  });

  /// 0..100.
  final int level;
  final bool muted;
  final String? device;
  final bool hardware;

  /// What the UI starts from before anyone has asked: a middle level, so a
  /// first key press moves something sensible rather than from silence.
  static const VolumeReading unknown = VolumeReading(level: 50);

  VolumeReading copyWith({int? level, bool? muted}) => VolumeReading(
    level: (level ?? this.level).clamp(0, 100),
    muted: muted ?? this.muted,
    device: device,
    hardware: hardware,
  );

  @override
  bool operator ==(Object other) =>
      other is VolumeReading &&
      other.level == level &&
      other.muted == muted &&
      other.device == device &&
      other.hardware == hardware;

  @override
  int get hashCode => Object.hash(level, muted, device, hardware);

  @override
  String toString() => 'VolumeReading($level%${muted ? ', muted' : ''})';
}

/// The mixer as the UI sees it: the level, and the two ways to move it.
///
/// The value moves at once on a request - the on-screen display follows
/// it, and a rocker must feel instant - and the machine catches up behind
/// it. A request never throws.
abstract class VolumeService implements ValueListenable<VolumeReading> {
  /// One notent of the rocker, or one detent of the wheel, in percent.
  static const int step = 5;

  /// Set the level outright (clamped to 0..100).
  Future<void> setLevel(int level);

  /// Move the level by [direction] steps of [step] percent: +1 louder,
  /// -1 quieter.
  Future<void> nudge(int direction) => setLevel(value.level + direction * step);
}

/// A mixer that is only a value: for the emulator's rig and for tests,
/// where there is no sound server behind it.
class VolumeSwitch extends ValueNotifier<VolumeReading>
    implements VolumeService {
  VolumeSwitch({int level = 50}) : super(VolumeReading(level: level));

  @override
  Future<void> setLevel(int level) {
    value = value.copyWith(level: level);
    return Future.value();
  }

  @override
  Future<void> nudge(int direction) =>
      setLevel(value.level + direction * VolumeService.step);
}

/// The device's mixer: the sound server's default sink, through tempod's
/// `volume` op.
///
/// Requests are sent as absolute levels, computed here from the value the
/// UI already shows, so a run of quick steps lands as one coherent climb
/// rather than a race of relative nudges; and only one request is in
/// flight at a time - a step that arrives while one is out waits, and the
/// latest level asked for is what goes next, so the mixer ends where the
/// finger left off without walking through every intermediate. Without a
/// daemon the value still moves and the failure is a log line.
class DeviceVolume extends ValueNotifier<VolumeReading>
    implements VolumeService {
  DeviceVolume({
    Tempod? tempod,
    this.period = const Duration(milliseconds: 500),
  }) : _tempod = tempod ?? Tempod(),
       super(VolumeReading.unknown) {
    if (_tempod.available) {
      unawaited(_read());
      _poll = Timer.periodic(period, (_) => unawaited(_read()));
    }
  }

  final Tempod _tempod;
  final Duration period;
  Timer? _poll;
  bool _reading = false;
  bool _disposed = false;
  int _revision = 0;
  bool _playbackActive = true;
  String? _deferredDevice;

  /// Apply a queued Bluetooth adjustment only after AVRCP says Playing.
  void setPlaybackActive(bool active) {
    _playbackActive = active;
    if (active && !_disposed && _wanted != null && _inflight == null) {
      _inflight = _resumeDeferred();
    }
  }

  Future<void> _resumeDeferred() async {
    final revision = _revision;
    try {
      final reply = await _tempod.request({'op': 'volume'});
      if (_disposed) return;
      // Never apply a speaker adjustment to the internal DAC after disconnect.
      if (revision == _revision && reply['device'] != _deferredDevice) {
        _wanted = null;
        _adopt(reply);
        return;
      }
      await _drain();
    } on Object catch (error) {
      debugPrint('volume resume: $error');
    } finally {
      _inflight = null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    super.dispose();
  }

  Future<void>? _inflight;
  int? _wanted;
  Object? _lastError;

  /// Checked completion for API commands; UI calls retain optimistic behavior.
  Future<void> setLevelConfirmed(int level) async {
    if (!_playbackActive && value.device != null && value.hardware) {
      throw const TempodError(
        'Bluetooth volume cannot be confirmed until playback resumes.',
      );
    }
    await setLevel(level);
    if (_wanted != null) {
      throw const TempodError(
        'Volume adjustment is deferred; outcome is not confirmed.',
      );
    }
    final error = _lastError;
    if (error != null) throw error;
  }

  /// Follow remote volume buttons and output changes without overwriting
  /// newer user requests with an older asynchronous read.
  Future<void> _read() async {
    if (_disposed || _reading || _inflight != null || _wanted != null) return;
    _reading = true;
    final revision = _revision;
    try {
      final reply = await _tempod.request({'op': 'volume'});
      if (!_disposed && revision == _revision) _adopt(reply);
    } on Object {
      // No daemon here; the value stays where it is.
    } finally {
      _reading = false;
    }
  }

  void _adopt(Map<String, Object?> reply) {
    final level = reply['level'];
    final muted = reply['muted'];
    if (level is int) {
      value = VolumeReading(
        level: level,
        muted: muted == true,
        device: reply['device'] as String?,
        hardware: reply['hardware'] == true,
      );
    }
  }

  @override
  Future<void> setLevel(int level) {
    _revision++;
    level = level.clamp(0, 100);
    value = value.copyWith(level: level);
    _wanted = level;
    _lastError = null;
    if (!_playbackActive && value.device != null && value.hardware) {
      _deferredDevice = value.device;
      return Future.value();
    }
    return _inflight ??= _drain();
  }

  @override
  Future<void> nudge(int direction) =>
      setLevel(value.level + direction * VolumeService.step);

  /// Send the latest level asked for, again if a newer one arrived while
  /// the last was out, until the machine has heard the last word.
  Future<void> _drain() async {
    try {
      while (_wanted != null) {
        if (!_playbackActive && value.device != null && value.hardware) break;
        final level = _wanted!;
        _wanted = null;
        try {
          final reply = await _tempod.request({'op': 'volume', 'level': level});
          // The mixer's word wins - but not over a newer request already
          // waiting its turn.
          if (!_disposed && _wanted == null) _adopt(reply);
        } on Object catch (error) {
          _lastError = error;
          debugPrint('volume: $level not applied: $error');
        }
      }
    } finally {
      _inflight = null;
    }
  }
}
