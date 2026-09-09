import 'dart:async';
import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';
import 'package:tempo_core/src/screens/video.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _VideoPlatform extends VideoPlayerPlatform {
  final events = StreamController<VideoEvent>();
  Duration position = Duration.zero;
  bool playing = false;
  double volume = 1;
  bool released = false;
  bool fail = false;
  @override
  Widget buildView(int id) => const SizedBox.expand();

  @override
  Future<void> init() async {}
  @override
  Future<int?> create(DataSource source) async {
    if (fail) throw StateError('Unsupported video');
    events.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(seconds: 20),
        size: const Size(320, 240),
      ),
    );
    return 1;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int id) => events.stream;
  @override
  Future<void> setLooping(int id, bool looping) async {}
  @override
  Future<void> setVolume(int id, double volume) async {
    this.volume = volume;
  }

  @override
  Future<void> setPlaybackSpeed(int id, double speed) async {}
  @override
  Future<void> play(int id) async {
    playing = true;
  }

  @override
  Future<void> pause(int id) async {
    playing = false;
  }

  @override
  Future<Duration> getPosition(int id) async => position;
  @override
  Future<void> seekTo(int id, Duration at) async {
    position = at;
  }

  @override
  Future<void> dispose(int id) async {
    released = true;
    await events.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const track = TrackSummary(
    id: 1,
    fileId: 1,
    path: '/tmp/movie.mp4',
    title: 'Movie',
  );
  late _VideoPlatform platform;
  late VideoPlayback video;
  setUp(() {
    platform = _VideoPlatform();
    VideoPlayerPlatform.instance = platform;
    video = VideoPlayback();
    VideoPlayback.active = video;
  });
  tearDown(() {
    Osd.hide();
    if (identical(VideoPlayback.active, video)) video.dispose();
  });

  testWidgets(
    'video defaults to volume and center toggles scrub mode without hiding UI',
    (tester) async {
      MenuDock.reset();
      final base = PlayerServices.fallback;
      final volume = VolumeSwitch();
      final audio = SilentPlayback();
      final screen = ScreenSwitch();
      video.attach(volume: volume);
      final wheel = ClickWheelController();
      final services = PlayerServices(
        battery: base.battery,
        wifi: base.wifi,
        bluetooth: base.bluetooth,
        storage: base.storage,
        places: base.places,
        screen: screen,
        volume: volume,
        output: base.output,
        feedback: base.feedback,
        playback: audio,
      );
      await tester.runAsync(() => video.play([track]));
      await tester.pumpWidget(
        PanelSurface(
          child: TempoApp(wheel: wheel, services: services),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(VideoNowPlaying), findsOneWidget);
      expect(find.byType(NowPlayingArt), findsNothing);
      expect(find.byKey(VideoNowPlaying.controlsKey), findsOneWidget);
      final picture = tester.getRect(find.byKey(VideoNowPlaying.pictureKey));
      wheel.jog(1);
      await tester.pumpAndSettle();
      expect(platform.position, Duration.zero);
      expect(volume.value.level, 55);
      await screen.setOn(false);
      await tester.pumpAndSettle();
      expect(
        platform.playing,
        isTrue,
        reason: 'screen sleep keeps video audio playing',
      );
      expect(video.value.playing, isTrue);
      await screen.setOn(true);
      await tester.pumpAndSettle();
      expect(platform.playing, isTrue);
      wheel.press(WheelButton.select);
      await tester.pumpAndSettle();
      expect(find.byKey(PlaybackProgress.thumbKey), findsOneWidget);
      expect(find.byKey(VideoNowPlaying.controlsKey), findsOneWidget);
      expect(DockChrome.of('/home').value.visible, isTrue);
      expect(tester.getRect(find.byKey(VideoNowPlaying.pictureKey)), picture);
      wheel.jog(1);
      await tester.pumpAndSettle();
      expect(platform.position, const Duration(seconds: 5));
      expect(volume.value.level, 55);
      wheel.press(WheelButton.select);
      await tester.pumpAndSettle();
      expect(find.byKey(PlaybackProgress.thumbKey), findsNothing);
      wheel.jog(-1);
      await tester.pumpAndSettle();
      expect(platform.position, const Duration(seconds: 5));
      expect(volume.value.level, 50);
      expect(find.byKey(VideoNowPlaying.controlsKey), findsOneWidget);
      wheel.press(WheelButton.playPause);
      await tester.pumpAndSettle();
      expect(platform.playing, isFalse);
      MenuDock.select(systemMenu.at('/library')!);
      await tester.pumpAndSettle();
      expect(VideoPlayback.active, same(video));
      MenuDock.select(systemMenu.at('/home')!);
      await tester.pumpAndSettle();
      expect(find.byType(VideoNowPlaying), findsOneWidget);
      playFrom(tester.element(find.byType(HomeScreen)), [track], 0);
      await tester.pumpAndSettle();
      expect(VideoPlayback.active, isNull);
      expect(find.byType(VideoNowPlaying), findsNothing);
      expect(audio.value.track, track);
      expect(audio.value.playing, isTrue);
      Osd.hide();
      await tester.pumpWidget(const SizedBox.shrink());
      MenuDock.reset();
    },
  );

  test(
    'video transport plays, pauses, clamps seeking and releases ownership',
    () async {
      await video.play([track]);
      expect(platform.playing, isTrue);
      expect(video.value.track, track);
      await video.toggle();
      expect(platform.playing, isFalse);
      await video.seekBy(const Duration(minutes: 1));
      expect(platform.position, const Duration(seconds: 20));
      await video.seekBy(const Duration(minutes: -1));
      expect(platform.position, Duration.zero);
      await video.stop();
      expect(platform.playing, isFalse);
    },
  );

  test(
    'initialization failure is visible instead of a loading spinner',
    () async {
      platform.fail = true;
      await video.play([track]);
      expect(video.error, contains('Unsupported video'));
      expect(platform.playing, isFalse);
    },
  );
}
