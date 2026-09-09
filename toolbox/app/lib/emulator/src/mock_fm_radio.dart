import 'dart:async';

import 'package:tempo_core/tempo_core.dart';

/// Fictional stations for exercising the tuner UI without producing audio.
class MockFmRadio extends FmRadioSwitch {
  MockFmRadio({this.textInterval = const Duration(seconds: 8)})
    : super(stationsKhz: stations.keys.toList());

  final Duration textInterval;
  Timer? _textTimer;
  int _textIndex = 0;

  static const stations =
      <int, ({String name, bool stereo, List<String> text})>{
        88100: (
          name: 'YAWN FM',
          stereo: false,
          text: [
            'All the news you slept through.',
            'Traffic update: five more minutes.',
          ],
        ),
        92700: (
          name: 'LOST AUX',
          stereo: true,
          text: [
            'Someone else has the aux cable.',
            'Now playing: the song you just missed.',
          ],
        ),
        95500: (
          name: 'GRAVY FM',
          stereo: true,
          text: ['All hits. Extra biscuits.', 'Weather report: still outside.'],
        ),
        98300: (
          name: 'GOOSE FM',
          stereo: true,
          text: [
            'More honks. Fewer commercials.',
            'Your request has been hissed at.',
          ],
        ),
        100100: (
          name: 'DAD ROCK',
          stereo: true,
          text: [
            'This one sounds better on vinyl.',
            'Turn it up. I know this part.',
          ],
        ),
        104300: (
          name: 'STATICFM',
          stereo: true,
          text: [
            'The quiet part, slightly louder.',
            'You are listening to a very convincing simulation.',
          ],
        ),
      };

  @override
  Future<void> setOn(bool on, {int? frequencyKhz}) async {
    _textTimer?.cancel();
    _textIndex = 0;
    final frequency =
        ((frequencyKhz ?? value.frequencyKhz).clamp(
              FmRadioService.minFrequencyKhz,
              FmRadioService.maxFrequencyKhz,
            ) ~/
            100) *
        100;
    value = FmRadioReading(available: true, on: on, frequencyKhz: frequency);
    _publish();
    if (on) {
      _textTimer = Timer.periodic(textInterval, (_) {
        _textIndex++;
        _publish();
      });
    }
  }

  void _publish() {
    final station = value.on ? stations[value.frequencyKhz] : null;
    value = FmRadioReading(
      available: true,
      on: value.on,
      frequencyKhz: value.frequencyKhz,
      rssi: !value.on
          ? null
          : station == null
          ? -105
          : -52,
      stereo: value.on ? station?.stereo ?? false : null,
      programName: station?.name,
      radioText: station == null
          ? null
          : station.text[_textIndex % station.text.length],
      pi: station == null
          ? null
          : 0xA000 + stations.keys.toList().indexOf(value.frequencyKhz),
      pty: station == null ? null : 10,
    );
  }

  @override
  Future<void> tune(int frequencyKhz) =>
      setOn(true, frequencyKhz: frequencyKhz);

  @override
  Future<void> refresh() async => _publish();

  @override
  void dispose() {
    _textTimer?.cancel();
    super.dispose();
  }
}
