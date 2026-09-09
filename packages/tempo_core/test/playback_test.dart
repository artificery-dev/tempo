import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

const _a = TrackSummary(
  id: 1,
  fileId: 1,
  path: '/m/a',
  title: 'A',
  artist: 'X',
  duration: Duration(minutes: 3),
);
const _b = TrackSummary(
  id: 2,
  fileId: 2,
  path: '/m/b',
  title: 'B',
  artist: 'X',
  duration: Duration(minutes: 2),
);

void main() {
  setUp(() {
    MenuDock.reset();
    Playback.state.value = PlaybackState.stopped;
  });

  group('SilentPlayback', () {
    test('plays a queue, pauses, skips, and stops at the end', () async {
      final playback = SilentPlayback();
      expect(playback.value, NowPlaying.nothing);

      await playback.play(const [_a, _b], index: 0);
      expect(playback.value.track, _a);
      expect(playback.value.playing, isTrue);
      expect(playback.value.duration, const Duration(minutes: 3));
      expect(Playback.state.value, PlaybackState.playing);

      await playback.toggle();
      expect(playback.value.state, PlaybackState.paused);
      expect(Playback.state.value, PlaybackState.paused);
      await playback.toggle();
      expect(playback.value.playing, isTrue);

      await playback.next();
      expect(playback.value.track, _b);
      expect(playback.value.index, 1);
      await playback.next();
      expect(playback.value, NowPlaying.nothing);
      expect(Playback.state.value, PlaybackState.stopped);
    });

    test('previous restarts the track, or steps back within the first '
        'seconds', () async {
      final playback = SilentPlayback();
      await playback.play(const [_a, _b], index: 1);
      await playback.seekBy(const Duration(seconds: 30));
      expect(playback.value.position, const Duration(seconds: 30));

      await playback.previous();
      expect(playback.value.track, _b, reason: 'restarted, not skipped');
      expect(playback.value.position, Duration.zero);

      await playback.previous();
      expect(playback.value.track, _a);
    });

    test('seeking is held at the ends', () async {
      final playback = SilentPlayback();
      await playback.play(const [_a]);
      await playback.seekBy(const Duration(minutes: 10));
      expect(playback.value.position, const Duration(minutes: 3));
      expect(playback.value.progress, 1);
      await playback.seekBy(const Duration(minutes: -10));
      expect(playback.value.position, Duration.zero);
    });

    test('the words mean nothing with nothing loaded', () async {
      final playback = SilentPlayback();
      await playback.toggle();
      await playback.next();
      await playback.previous();
      await playback.seekBy(const Duration(seconds: 1));
      expect(playback.value, NowPlaying.nothing);
    });
  });

  group('the media keys', () {
    late SilentPlayback playback;

    Future<ClickWheelController> pumpApp(WidgetTester tester) async {
      final wheel = ClickWheelController();
      playback = SilentPlayback();
      final services = PlayerServices(
        battery: ValueNotifier(const BatteryReading(percent: 50)),
        wifi: ValueNotifier(WifiReading.off),
        bluetooth: ValueNotifier(BluetoothReading.off),
        storage: ValueNotifier(StorageReading.empty),
        places: PlayerServices.fallback.places,
        screen: ScreenSwitch(),
        volume: VolumeSwitch(),
        output: OutputSwitch(),
        feedback: FeedbackSwitch(),
        playback: playback,
      );
      await tester.pumpWidget(
        PanelSurface(
          child: TempoApp(wheel: wheel, services: services),
        ),
      );
      await tester.pumpAndSettle();
      return wheel;
    }

    testWidgets('play pauses and resumes, next and previous move the queue', (
      tester,
    ) async {
      final wheel = await pumpApp(tester);
      await playback.play(const [_a, _b]);
      await tester.pumpAndSettle();
      expect(find.byKey(NowPlayingCard.cardKey), findsOneWidget);
      expect(find.text('A'), findsOneWidget);

      wheel.press(WheelButton.playPause);
      await tester.pumpAndSettle();
      expect(playback.value.state, PlaybackState.paused);
      wheel.press(WheelButton.playPause);
      await tester.pumpAndSettle();
      expect(playback.value.playing, isTrue);

      wheel.press(WheelButton.next);
      await tester.pumpAndSettle();
      expect(playback.value.track, _b);
      expect(find.text('B'), findsOneWidget);

      wheel.press(WheelButton.previous);
      await tester.pumpAndSettle();
      expect(playback.value.track, _a);

      wheel.press(WheelButton.next);
      wheel.press(WheelButton.next);
      await tester.pumpAndSettle();
      expect(playback.value, NowPlaying.nothing);
      expect(find.byKey(NowPlayingCard.cardKey), findsNothing);
    });

    testWidgets('holding next or previous seeks within the track', (
      tester,
    ) async {
      final wheel = await pumpApp(tester);
      await playback.play(const [_a]);
      await tester.pumpAndSettle();

      wheel.hold(WheelButton.next);
      await tester.pumpAndSettle();
      expect(playback.value.position, TempoApp.seekStride);
      expect(playback.value.track, _a, reason: 'a hold is not a skip');

      wheel.hold(WheelButton.previous);
      await tester.pumpAndSettle();
      expect(playback.value.position, Duration.zero);
    });
  });
}
