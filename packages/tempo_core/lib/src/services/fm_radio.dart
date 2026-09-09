import 'dart:async';

import 'package:flutter/foundation.dart';

import '../applet.dart';
import '../status.dart';
import 'tempod.dart';

enum FmSeekDirection {
  down(-1),
  up(1);

  const FmSeekDirection(this.wireValue);

  final int wireValue;
}

/// What the FM receiver is doing and what the station is saying.
@immutable
class FmRadioReading {
  const FmRadioReading({
    required this.available,
    required this.on,
    required this.frequencyKhz,
    this.rssi,
    this.stereo,
    this.programName,
    this.radioText,
    this.pi,
    this.pty,
    this.error,
  });

  static const unavailable = FmRadioReading(
    available: false,
    on: false,
    frequencyKhz: 95500,
  );

  final bool available;
  final bool on;
  final int frequencyKhz;
  final int? rssi;
  final bool? stereo;
  final String? programName;
  final String? radioText;
  final int? pi;
  final int? pty;
  final String? error;

  FmRadioReading copyWith({
    bool? available,
    bool? on,
    int? frequencyKhz,
    int? rssi,
    bool? stereo,
    String? programName,
    String? radioText,
    int? pi,
    int? pty,
    String? error,
    bool clearStation = false,
    bool clearError = false,
  }) => FmRadioReading(
    available: available ?? this.available,
    on: on ?? this.on,
    frequencyKhz: frequencyKhz ?? this.frequencyKhz,
    rssi: clearStation ? null : (rssi ?? this.rssi),
    stereo: clearStation ? null : (stereo ?? this.stereo),
    programName: clearStation ? null : (programName ?? this.programName),
    radioText: clearStation ? null : (radioText ?? this.radioText),
    pi: clearStation ? null : (pi ?? this.pi),
    pty: clearStation ? null : (pty ?? this.pty),
    error: clearError ? null : (error ?? this.error),
  );

  @override
  bool operator ==(Object other) =>
      other is FmRadioReading &&
      other.available == available &&
      other.on == on &&
      other.frequencyKhz == frequencyKhz &&
      other.rssi == rssi &&
      other.stereo == stereo &&
      other.programName == programName &&
      other.radioText == radioText &&
      other.pi == pi &&
      other.pty == pty &&
      other.error == error;

  @override
  int get hashCode => Object.hash(
    available,
    on,
    frequencyKhz,
    rssi,
    stereo,
    programName,
    radioText,
    pi,
    pty,
    error,
  );
}

/// The tuner as the UI sees it.
abstract class FmRadioService implements ValueListenable<FmRadioReading> {
  static const minFrequencyKhz = 87500;
  static const maxFrequencyKhz = 108000;
  static const stepKhz = 100;

  Future<void> setOn(bool on, {int? frequencyKhz});

  Future<void> tune(int frequencyKhz);

  /// Ask the receiver to find the next usable station in [direction].
  Future<void> seek(FmSeekDirection direction);

  Future<void> refresh();
}

/// The radio session shown by Home's Now Playing page.
///
/// It owns the dial state rather than a route: the Apps entry can hand the
/// receiver to Home without turning it off when that route goes offstage.
/// Music and video explicitly end this session before taking the audio path.
class FmRadioSession extends ChangeNotifier {
  FmRadioSession({required this.radio, AppletState? memory})
    : _memory = memory {
    _favorites = _storedFavorites(memory?.get<List<Object?>>('favorites'));
    _frequencyKhz = _validFrequency(
      memory?.get<int>('frequency_khz') ?? radio.value.frequencyKhz,
    );
    radio.addListener(_radioChanged);
  }

  static final session = ValueNotifier<FmRadioSession?>(null);

  static FmRadioSession? get active => session.value;

  static void activate(FmRadioSession value) {
    session.value = value;
    value._publishPlaybackState();
  }

  /// Remove the current radio page immediately, then shut its hardware down.
  static Future<void> stopActive() async {
    final value = active;
    if (value == null) return;
    if (identical(active, value)) {
      session.value = null;
      Playback.state.value = PlaybackState.stopped;
    }
    await value.close();
  }

  static const tuneSettle = Duration(milliseconds: 120);

  final FmRadioService radio;
  final AppletState? _memory;
  Timer? _tuneTimer;
  late List<int> _favorites;
  late int _frequencyKhz;
  bool _seeking = false;
  bool _closed = false;

  int get frequencyKhz => _frequencyKhz;
  List<int> get favorites => List.unmodifiable(_favorites);
  bool get favorite => _favorites.contains(_frequencyKhz);
  bool get seeking => _seeking;
  FmRadioReading get reading => radio.value;

  static List<int> _storedFavorites(List<Object?>? stored) {
    final favorites = {
      for (final value in stored ?? const <Object?>[])
        if (value is int &&
            value >= FmRadioService.minFrequencyKhz &&
            value <= FmRadioService.maxFrequencyKhz &&
            value % FmRadioService.stepKhz == 0)
          value,
    }.toList()..sort();
    return favorites;
  }

  static int _validFrequency(int frequency) {
    final clamped = frequency.clamp(
      FmRadioService.minFrequencyKhz,
      FmRadioService.maxFrequencyKhz,
    );
    return clamped - clamped % FmRadioService.stepKhz;
  }

  Future<void> start() async {
    if (_closed) return;
    await radio.setOn(true, frequencyKhz: _frequencyKhz);
    _publishPlaybackState();
  }

  void jog(int amount, {bool page = false}) {
    if (_seeking || _closed) return;
    final multiplier = page ? 5 : 1;
    selectFrequency(
      _frequencyKhz + amount * multiplier * FmRadioService.stepKhz,
    );
  }

  void selectFrequency(int frequency) {
    if (_closed) return;
    const min = FmRadioService.minFrequencyKhz;
    const max = FmRadioService.maxFrequencyKhz;
    const step = FmRadioService.stepKhz;
    const channels = (max - min) ~/ step + 1;
    final index = ((frequency - min) ~/ step) % channels;
    final wrapped = min + (index < 0 ? index + channels : index) * step;
    _frequencyKhz = wrapped;
    _memory?.set('frequency_khz', wrapped);
    notifyListeners();
    _tuneTimer?.cancel();
    _tuneTimer = Timer(tuneSettle, () {
      if (_closed) return;
      unawaited(
        radio.value.on
            ? radio.tune(_frequencyKhz)
            : radio.setOn(true, frequencyKhz: _frequencyKhz),
      );
    });
  }

  void toggleFavorite() {
    if (_seeking || _closed) return;
    if (!_favorites.remove(_frequencyKhz)) {
      _favorites.add(_frequencyKhz);
      _favorites.sort();
    }
    _memory?.set('favorites', List<int>.of(_favorites));
    notifyListeners();
  }

  void jumpFavorite(int direction) {
    if (_favorites.isEmpty || _seeking || _closed) return;
    final current = _favorites.indexOf(_frequencyKhz);
    final index = current < 0
        ? (direction > 0
              ? _favorites.indexWhere((value) => value > _frequencyKhz)
              : _favorites.lastIndexWhere((value) => value < _frequencyKhz))
        : (current + direction) % _favorites.length;
    final wrapped = index < 0
        ? (direction > 0 ? 0 : _favorites.length - 1)
        : index;
    selectFrequency(_favorites[wrapped]);
  }

  Future<void> togglePower() async {
    if (_seeking || _closed) return;
    if (radio.value.on) {
      await radio.setOn(false);
    } else {
      await radio.setOn(true, frequencyKhz: _frequencyKhz);
    }
    _publishPlaybackState();
  }

  Future<void> seek(FmSeekDirection direction) async {
    if (_seeking || _closed) return;
    _tuneTimer?.cancel();
    _seeking = true;
    notifyListeners();
    try {
      if (!radio.value.on) {
        await radio.setOn(true, frequencyKhz: _frequencyKhz);
      }
      if (_closed) return;
      await radio.seek(direction);
      if (_closed) return;
      _frequencyKhz = _validFrequency(radio.value.frequencyKhz);
      _memory?.set('frequency_khz', _frequencyKhz);
    } finally {
      if (!_closed) {
        _seeking = false;
        _publishPlaybackState();
        notifyListeners();
      }
    }
  }

  void media(FmSeekDirection direction, {required bool held}) {
    if (held) {
      unawaited(seek(direction));
    } else {
      jumpFavorite(direction == FmSeekDirection.up ? 1 : -1);
    }
  }

  void _radioChanged() {
    if (_closed) return;
    _publishPlaybackState();
    notifyListeners();
  }

  void _publishPlaybackState() {
    if (!identical(active, this)) return;
    Playback.state.value = radio.value.on
        ? PlaybackState.playing
        : PlaybackState.paused;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _tuneTimer?.cancel();
    radio.removeListener(_radioChanged);
    if (identical(active, this)) {
      session.value = null;
      Playback.state.value = PlaybackState.stopped;
    }
    await radio.setOn(false);
    _memory?.flush();
    dispose();
  }
}

/// A tuner that is only state: the receiver for tests and simulated rigs.
class FmRadioSwitch extends ValueNotifier<FmRadioReading>
    implements FmRadioService {
  FmRadioSwitch({
    int frequencyKhz = 95500,
    bool available = true,
    bool on = false,
    List<int> stationsKhz = const [88100, 95500, 100100, 104300],
  }) : _stationsKhz = List.unmodifiable(stationsKhz.toSet().toList()..sort()),
       super(
         FmRadioReading(
           available: available,
           on: on,
           frequencyKhz: frequencyKhz,
           rssi: on ? -70 : null,
           stereo: on ? true : null,
         ),
       );

  final List<int> _stationsKhz;

  @override
  Future<void> setOn(bool on, {int? frequencyKhz}) async {
    value = value.copyWith(
      on: on,
      frequencyKhz: frequencyKhz,
      clearStation: !on || frequencyKhz != null,
      clearError: true,
    );
  }

  @override
  Future<void> tune(int frequencyKhz) async {
    value = value.copyWith(
      on: true,
      frequencyKhz: frequencyKhz,
      clearStation: true,
      clearError: true,
    );
  }

  @override
  Future<void> seek(FmSeekDirection direction) async {
    final stations = _stationsKhz
        .where(
          (frequency) =>
              frequency >= FmRadioService.minFrequencyKhz &&
              frequency <= FmRadioService.maxFrequencyKhz,
        )
        .toList();
    if (stations.isEmpty) return;
    final frequency = switch (direction) {
      FmSeekDirection.up => stations.firstWhere(
        (station) => station > value.frequencyKhz,
        orElse: () => stations.first,
      ),
      FmSeekDirection.down => stations.lastWhere(
        (station) => station < value.frequencyKhz,
        orElse: () => stations.last,
      ),
    };
    await tune(frequency);
  }

  @override
  Future<void> refresh() async {}
}

/// No receiver behind this UI, used wherever no service was installed.
class UnavailableFmRadio extends FmRadioSwitch {
  UnavailableFmRadio() : super(available: false);

  static final shared = UnavailableFmRadio();
}

/// The device receiver through tempod's `fm` operation.
///
/// It is polled while a screen is listening so newly decoded RDS appears,
/// but tuning and power changes are immediate requests. Failures stay in
/// the reading for the applet to show instead of escaping into the UI.
class DeviceFmRadio extends ValueNotifier<FmRadioReading>
    implements FmRadioService {
  DeviceFmRadio({Tempod? tempod, this.period = const Duration(seconds: 1)})
    : _tempod = tempod ?? Tempod(),
      super(FmRadioReading.unavailable);

  final Tempod _tempod;
  final Duration period;
  Timer? _timer;
  bool _busy = false;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    if (_timer == null && _tempod.available) {
      unawaited(refresh());
      _timer = Timer.periodic(period, (_) => refresh());
    }
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  Future<void> setOn(bool on, {int? frequencyKhz}) async {
    value = value.copyWith(
      on: on,
      frequencyKhz: frequencyKhz,
      clearStation: !on || frequencyKhz != null,
      clearError: true,
    );
    await _change({'op': 'fm', 'on': on, 'frequency_khz': ?frequencyKhz});
  }

  @override
  Future<void> tune(int frequencyKhz) async {
    value = value.copyWith(
      on: true,
      frequencyKhz: frequencyKhz,
      clearStation: true,
      clearError: true,
    );
    await _change({'op': 'fm', 'frequency_khz': frequencyKhz});
  }

  @override
  Future<void> seek(FmSeekDirection direction) async {
    value = value.copyWith(clearStation: true, clearError: true);
    await _change({'op': 'fm', 'seek': direction.wireValue});
  }

  Future<void> _change(Map<String, Object?> request) async {
    try {
      _adopt(await _tempod.request(request));
    } on Object catch (error) {
      value = value.copyWith(error: error.toString());
    }
  }

  @override
  Future<void> refresh() async {
    if (_busy) return;
    _busy = true;
    try {
      _adopt(await _tempod.request({'op': 'fm'}));
    } on Object catch (error) {
      // A transient poll failure should not switch the radio off under the
      // listener, but it should be visible if it persists.
      value = value.copyWith(error: error.toString());
    } finally {
      _busy = false;
    }
  }

  void _adopt(Map<String, Object?> reply) {
    final frequency = reply['frequency_khz'];
    value = FmRadioReading(
      available: reply['available'] == true,
      on: reply['on'] == true,
      frequencyKhz: frequency is int ? frequency : value.frequencyKhz,
      rssi: reply['rssi'] as int?,
      stereo: reply['stereo'] as bool?,
      programName: reply['program_name'] as String?,
      radioText: reply['radio_text'] as String?,
      pi: reply['pi'] as int?,
      pty: reply['pty'] as int?,
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
