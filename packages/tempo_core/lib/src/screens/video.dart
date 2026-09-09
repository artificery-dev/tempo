import 'dart:async';

import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';
import 'package:video_player/video_player.dart';

import '../content_surface.dart';
import '../status.dart';
import '../dock.dart';
import '../menu/menu_tree.dart';
import '../osd.dart';
import '../screens.dart';
import '../services/services.dart';
import '../services/video_playback.dart';

/// Videos and songs enter the same Now Playing page, leaving the library's
/// selection in place for the next visit.
void playVideo(BuildContext context, TrackSummary track) {
  final services = PlayerServicesScope.of(context);
  VideoPlayback.active?.dispose();
  final video = VideoPlayback()..attach(volume: services.volume);
  VideoPlayback.active = video;
  MenuDock.select(systemMenu.at('/home')!);
  unawaited(
    FmRadioSession.stopActive().then((_) => services.playback.stop()).then((
      _,
    ) async {
      if (identical(VideoPlayback.active, video)) await video.play([track]);
    }),
  );
}

/// The video fills Now Playing; its controls are an overlay, not a separate
/// route or a layout that changes the size of the picture.
class VideoNowPlaying extends StatefulWidget {
  const VideoNowPlaying({required this.video, super.key});
  final VideoPlayback video;
  static const controlsKey = Key('VideoNowPlaying.controls');
  static const pictureKey = Key('VideoNowPlaying.picture');

  @override
  State<VideoNowPlaying> createState() => _VideoNowPlayingState();
}

class _VideoNowPlayingState extends State<VideoNowPlaying> {
  bool _scrubbing = false;

  @override
  Widget build(BuildContext context) => Actions(
    actions: {
      ActivateIntent: CallbackAction<ActivateIntent>(
        onInvoke: (_) {
          Osd.hide();
          setState(() => _scrubbing = !_scrubbing);
          return null;
        },
      ),
      JogIntent: CallbackAction<JogIntent>(
        onInvoke: (intent) {
          if (_scrubbing) {
            unawaited(
              widget.video.seekBy(
                Duration(seconds: intent.amount * (intent.page ? 30 : 5)),
              ),
            );
          } else {
            final volume = PlayerServicesScope.of(context).volume;
            unawaited(volume.nudge(intent.amount * (intent.page ? 2 : 1)));
            VolumeOsd.show(volume);
          }
          return null;
        },
      ),
      WheelBackIntent: CallbackAction<WheelBackIntent>(
        onInvoke: (_) {
          MenuDock.shown.value = true;
          return null;
        },
      ),
    },
    child: Focus(
      autofocus: true,
      debugLabel: 'VideoNowPlaying',
      child: AnimatedBuilder(
        animation: widget.video,
        builder: (context, _) {
          final video = widget.video;
          final controller = video.controller;
          return PublishChrome(
            chrome: BarChrome(
              title: video.value.track?.title ?? 'Now Playing',
              visible: true,
            ),
            child: ColoredBox(
              color: const Color(0xff000000),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (video.error != null)
                    ContentMessage(
                      child: BodyText(
                        video.error!,
                        textAlign: TextAlign.center,
                      ),
                    )
                  else if (controller == null ||
                      !controller.value.isInitialized)
                    const Center(child: Spinner(size: 18))
                  else
                    Center(
                      child: AspectRatio(
                        key: VideoNowPlaying.pictureKey,
                        aspectRatio: controller.value.aspectRatio,
                        child: VideoPlayer(controller),
                      ),
                    ),
                  if (video.value.hasTrack)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: PlayerDockTransition(
                        visible: true,
                        child: NowPlayingCard(
                          key: VideoNowPlaying.controlsKey,
                          now: video.value,
                          scrubbing: _scrubbing,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    ),
  );
}
