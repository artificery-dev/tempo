import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

import 'tempod.dart';

/// What the player does with its hands and its voice when the wheel is
/// used: a tick for a detent, a click for a press, a thump for a hold - a
/// sound through the speaker or the headphones, and a shake of the motor.
abstract class FeedbackService {
  /// Whether the sounds play.
  ValueNotifier<bool> get sounds;

  /// Classic follows the wheel action; other choices use one sound throughout.
  ValueNotifier<String> get soundType;

  /// Keep clicks on the device speaker; suppress them with headphones.
  ValueNotifier<bool> get speakerOnly;

  /// Whether the motor shakes.
  ValueNotifier<bool> get haptics;

  /// The motor pulse duration profile, independent of the click sound.
  ValueNotifier<String> get hapticFeel;

  /// Answer a word of the wheel's. Never throws; never waits.
  void word(WheelWord word);
}

/// Feedback that only counts: for the emulator's rig and for tests.
class FeedbackSwitch implements FeedbackService {
  @override
  final sounds = ValueNotifier(true);

  @override
  final soundType = ValueNotifier('classic');

  @override
  final speakerOnly = ValueNotifier(true);

  @override
  final haptics = ValueNotifier(true);

  @override
  final hapticFeel = ValueNotifier('standard');

  /// Every word answered, in order.
  final words = <WheelWord>[];

  @override
  void word(WheelWord word) => words.add(word);
}

/// The device's feedback: tempod's `sound` and `haptic` ops, one short
/// line each, sent and forgotten. A detent every fifty milliseconds is
/// twenty lines a second, which is nothing; a reply that never comes is
/// nothing either.
class DeviceFeedback implements FeedbackService {
  DeviceFeedback({Tempod? tempod}) : _tempod = tempod ?? Tempod();

  final Tempod _tempod;

  @override
  final sounds = ValueNotifier(true);

  @override
  final soundType = ValueNotifier('classic');

  @override
  final speakerOnly = ValueNotifier(true);

  @override
  final haptics = ValueNotifier(true);

  @override
  final hapticFeel = ValueNotifier('standard');

  static const _names = {
    WheelWord.detent: 'tick',
    WheelWord.press: 'click',
    WheelWord.hold: 'thump',
  };

  @override
  void word(WheelWord word) {
    if (!_tempod.available) return;
    final name = _names[word]!;
    if (sounds.value) {
      final chosen = switch (soundType.value) {
        'tick' || 'click' || 'thump' => soundType.value,
        _ => name,
      };
      unawaited(
        _send({
          'op': 'sound',
          'name': chosen,
          'speaker_only': speakerOnly.value,
        }),
      );
    }
    if (haptics.value) {
      // The Y2 motor needs at least ~20 ms to spin up. Its strength range
      // is narrow, so duration gives these profiles a perceptible difference.
      final durations = switch (hapticFeel.value) {
        'soft' => (20, 30, 65),
        'strong' => (40, 65, 130),
        _ => null,
      };
      if (durations == null) {
        unawaited(_send({'op': 'haptic', 'pattern': name}));
      } else {
        final ms = switch (word) {
          WheelWord.detent => durations.$1,
          WheelWord.press => durations.$2,
          WheelWord.hold => durations.$3,
        };
        unawaited(_send({'op': 'haptic', 'ms': ms, 'strength': 100}));
      }
    }
  }

  Future<void> _send(Map<String, Object?> request) async {
    try {
      await _tempod.request(request);
    } on Object {
      // No daemon, no motor, no sound server: the word was still said.
    }
  }
}
