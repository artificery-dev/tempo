import 'dart:async';

import 'package:flutter/foundation.dart';

import 'tempod.dart';

/// The panel's backlight, as the UI sees it: on, or off with the UI dark
/// behind it.
///
/// The value is whether the screen is awake, and it is what the UI's shade
/// follows. Changing it is asynchronous because on the device the light
/// itself takes time: going to sleep, the value moves at once so the frame
/// fades to black first and the backlight goes out under it; waking, the
/// backlight comes on first and the value moves when it has, so the frame
/// fades in on a lit panel rather than in the dark.
/// When the screen puts itself to sleep: after this long without a word
/// from the wheel or a button, having dimmed at [dimAfter] as the
/// warning. Null never sleeps by itself. A setting in the making, like
/// `Appearance`.
abstract final class ScreenSleep {
  static final after = ValueNotifier<Duration?>(const Duration(seconds: 30));

  /// How long the player waits before dimming the screen - counted from
  /// the last thing anyone did, the same as [after] is, so the two read
  /// off one clock and are set from one list of lengths.
  ///
  /// Null never dims: the light goes from full to dark. So does a value
  /// at or past [after] - the screen sleeps before the dim would land,
  /// which is a legal way to say the same thing.
  static final dimAfter = ValueNotifier<Duration?>(const Duration(seconds: 15));

  /// A hand on the clock: while true the screen never sleeps by itself,
  /// whatever [after] says. The device has no reason to hold it - a desk
  /// does, where the player is being looked at and not touched.
  static final inhibited = ValueNotifier<bool>(false);
}

abstract class ScreenService implements ValueListenable<bool> {
  /// How long the screen takes to go dark, or to come back. The UI's shade
  /// and the backlight ramp both run over this, together.
  static const fade = Duration(milliseconds: 400);

  /// Wake the screen or put it to sleep. Resolves when the backlight has
  /// finished moving; never throws.
  Future<void> setOn(bool on, {Duration fade = fade});

  /// Whether the screen is dimmed: awake, but at a fraction of its light,
  /// the warning before a sleep. Waking lifts it.
  ValueListenable<bool> get dimmed;

  /// Dim the screen, or bring it back to full. Never throws.
  Future<void> setDimmed(bool dimmed);

  /// How much light the panel gives, 0..100. The backlight is a PWM and
  /// the daemon takes raw levels; a percent is what a user sets and what
  /// the settings tree stores.
  ValueListenable<int> get brightness;

  /// Set the light. Clamped to a floor rather than to zero: a screen a
  /// user cannot see is a screen they cannot fix. Never throws.
  Future<void> setBrightness(int percent);

  /// The lowest a user may set it to.
  static const int minBrightness = 10;
}

/// How much of its light a dimmed screen keeps. Half: the panel's
/// backlight is a PWM, and lower than this it flickers to the eye.
const double dimLevel = 0.5;

/// A screen that is only a value: for the emulator's rig and for tests,
/// where there is no backlight to drive and the UI's shade is the whole of
/// the sleep.
class ScreenSwitch extends ValueNotifier<bool> implements ScreenService {
  ScreenSwitch({bool on = true, int brightness = 80})
    : brightness = ValueNotifier(brightness),
      super(on);

  @override
  final ValueNotifier<bool> dimmed = ValueNotifier(false);

  @override
  final ValueNotifier<int> brightness;

  @override
  Future<void> setBrightness(int percent) async {
    brightness.value = percent.clamp(ScreenService.minBrightness, 100);
  }

  @override
  Future<void> setOn(bool on, {Duration fade = ScreenService.fade}) {
    // Either way the dim is over: asleep is not dimmed, and a wake is
    // at full.
    dimmed.value = false;
    value = on;
    return Future.value();
  }

  @override
  Future<void> setDimmed(bool dim) {
    dimmed.value = dim;
    return Future.value();
  }
}

/// The device's screen: the backlight, through tempod.
///
/// The frontend cannot touch `/sys/class/backlight` itself (it runs
/// unprivileged), so the `screen` op does it: off ramps the level down and
/// blanks, on unblanks and ramps back to the level it left. Without a
/// daemon to reach - a desktop, or a device whose tempod is down - the
/// value still moves and the failure is a log line: the UI going dark is
/// most of what a sleep looks like, and it must not depend on the socket.
class DeviceScreen extends ValueNotifier<bool> implements ScreenService {
  DeviceScreen({Tempod? tempod}) : _tempod = tempod ?? Tempod(), super(true) {
    // A frontend that comes up behind a dark backlight - restarted while
    // the player slept - would be awake and invisible. Ask, and light it.
    unawaited(_light());
  }

  final Tempod _tempod;

  @override
  final ValueNotifier<bool> dimmed = ValueNotifier(false);

  @override
  final ValueNotifier<int> brightness = ValueNotifier(100);

  /// The level the backlight had before it dimmed, to give back.
  int? _bright;

  /// The panel's own ceiling, as the daemon reports it. The raw levels are
  /// `1..max`; a percent is scaled onto that.
  int? _max;

  @override
  Future<void> setBrightness(int percent) async {
    final wanted = percent.clamp(ScreenService.minBrightness, 100);
    try {
      final max = _max ?? await _ceiling();
      if (max == null) return;
      final level = (max * wanted / 100).round().clamp(1, max);
      await _tempod.request({'op': 'screen', 'brightness': level});
      brightness.value = wanted;
      // Dimmed, the level under the dim is what comes back on the wake.
      if (dimmed.value) _bright = level;
    } on Object catch (error) {
      debugPrint('screen: brightness not applied: $error');
    }
  }

  /// The panel's `max`, asked once and remembered: it does not move.
  Future<int?> _ceiling() async {
    final status = await _tempod.request({'op': 'screen'});
    final max = status['max'];
    if (max is! int || max <= 0) return null;
    return _max = max;
  }

  Future<void> _light() async {
    try {
      final status = await _tempod.request({'op': 'screen'});
      if (status['on'] == false) await setOn(true);
    } on Object {
      // No daemon here; nothing to light.
    }
  }

  @override
  Future<void> setOn(bool on, {Duration fade = ScreenService.fade}) async {
    // Dark first, then the light goes; the light first, then the frame.
    // Going dark from a dim, the dim is simply over - no request to lift
    // it: one now would supersede the sleep in tempod, which waits out
    // the fade and lets go of the cut when a newer request lands. The
    // level comes back with the wake.
    if (!on) {
      dimmed.value = false;
      value = false;
    }
    try {
      await _tempod.request({
        'op': 'screen',
        'on': on,
        // Waking from a dim comes back at full, not at the dim.
        if (on && _bright != null) 'brightness': _bright,
        'fade_ms': fade.inMilliseconds,
      });
    } on Object catch (error) {
      debugPrint('screen: ${on ? 'on' : 'off'} not applied: $error');
    }
    if (on) {
      _bright = null;
      dimmed.value = false;
      value = true;
    }
  }

  /// Dim through the backlight: the level drops to [dimLevel] of what it
  /// was, and comes back to that when lifted.
  @override
  Future<void> setDimmed(bool dim) async {
    if (dim == dimmed.value) return;
    dimmed.value = dim;
    try {
      if (dim) {
        final status = await _tempod.request({'op': 'screen'});
        final level = status['brightness'];
        if (level is! int || level <= 0) return;
        _bright = level;
        await _tempod.request({
          'op': 'screen',
          'brightness': (level * dimLevel).round().clamp(1, level),
        });
      } else {
        final bright = _bright;
        _bright = null;
        if (bright == null) return;
        await _tempod.request({'op': 'screen', 'brightness': bright});
      }
    } on Object catch (error) {
      debugPrint('screen: dim ${dim ? 'on' : 'off'} not applied: $error');
    }
  }
}
