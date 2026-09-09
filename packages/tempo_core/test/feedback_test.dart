import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

class RecordingTempod extends Tempod {
  final requests = <Map<String, Object?>>[];
  @override
  bool get available => true;
  @override
  Future<Map<String, Object?>> request(Map<String, Object?> request) async {
    requests.add(request);
    return {'ok': true};
  }
}

void main() {
  test('sound choices reach the daemon without changing haptic patterns', () {
    final daemon = RecordingTempod();
    final feedback = DeviceFeedback(tempod: daemon);
    for (final choice in ['classic', 'tick', 'click', 'thump']) {
      feedback.soundType.value = choice;
      for (final (word, pattern) in [
        (WheelWord.detent, 'tick'),
        (WheelWord.press, 'click'),
        (WheelWord.hold, 'thump'),
      ]) {
        daemon.requests.clear();
        feedback.word(word);
        expect(daemon.requests, [
          {
            'op': 'sound',
            'name': choice == 'classic' ? pattern : choice,
            'speaker_only': true,
          },
          {'op': 'haptic', 'pattern': pattern},
        ]);
      }
    }
    feedback.sounds.value = false;
    daemon.requests.clear();
    feedback.word(WheelWord.detent);
    expect(daemon.requests, [
      {'op': 'haptic', 'pattern': 'tick'},
    ]);
    feedback.haptics.value = false;
    feedback.sounds.value = true;
    daemon.requests.clear();
    feedback.word(WheelWord.detent);
    expect(daemon.requests, [
      {'op': 'sound', 'name': 'thump', 'speaker_only': true},
    ]);
  });

  test('speaker routing is included on every sound request', () {
    final daemon = RecordingTempod();
    final feedback = DeviceFeedback(tempod: daemon)..haptics.value = false;
    for (final enabled in [false, true, false]) {
      feedback.speakerOnly.value = enabled;
      feedback.word(WheelWord.press);
      expect(daemon.requests.last, {
        'op': 'sound',
        'name': 'click',
        'speaker_only': enabled,
      });
    }
  });

  test(
    'haptic feel changes pulse duration independently of sound and the toggle',
    () {
      final daemon = RecordingTempod();
      final feedback = DeviceFeedback(tempod: daemon)..sounds.value = false;
      for (final (feel, durations) in [
        ('soft', [20, 30, 65]),
        ('strong', [40, 65, 130]),
      ]) {
        feedback.hapticFeel.value = feel;
        daemon.requests.clear();
        for (final word in [
          WheelWord.detent,
          WheelWord.press,
          WheelWord.hold,
        ]) {
          feedback.word(word);
        }
        expect(daemon.requests, [
          for (final ms in durations)
            {'op': 'haptic', 'ms': ms, 'strength': 100},
        ]);
      }
      feedback.hapticFeel.value = 'standard';
      daemon.requests.clear();
      feedback.word(WheelWord.detent);
      expect(daemon.requests, [
        {'op': 'haptic', 'pattern': 'tick'},
      ]);
      feedback.haptics.value = false;
      daemon.requests.clear();
      feedback.word(WheelWord.detent);
      expect(daemon.requests, isEmpty);
    },
  );

  test('feedback settings apply the sound toggle and choice independently', () {
    final services = PlayerServices.fallback;
    final settings = Settings(tree: playerSettingsTree);
    SettingBindings.registerAll(PlayerSettings.sinks(services));
    final bridge = SettingsBridge(settings: settings)..attach();
    addTearDown(() {
      bridge.detach();
      settings.dispose();
      SettingBindings.clear();
      services.feedback.sounds.value = true;
      services.feedback.soundType.value = 'classic';
      services.feedback.speakerOnly.value = true;
      services.feedback.hapticFeel.value = 'standard';
    });
    settings.set('/settings/controls/feedback/speaker-only', false);
    expect(services.feedback.speakerOnly.value, false);
    settings.set('/settings/controls/feedback/haptic-feel', 'strong');
    expect(services.feedback.hapticFeel.value, 'strong');
    settings.set('/settings/controls/feedback/sound-type', 'tick');
    expect(services.feedback.soundType.value, 'tick');
    settings.set('/settings/controls/feedback/sounds', false);
    expect(services.feedback.sounds.value, false);
    expect(services.feedback.soundType.value, 'tick');
  });
}
