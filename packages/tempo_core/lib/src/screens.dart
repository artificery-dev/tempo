import 'dart:async';

import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

import 'appearance.dart';
import 'content_surface.dart';
import 'dock.dart';
import 'osd.dart';
import 'panel_bar.dart';
import 'routes.dart';
import 'scale.dart';
import 'services/services.dart';
import 'services/video_playback.dart';
import 'screens/fm_radio.dart';
import 'screens/video.dart';
import 'status.dart';
import 'wallpaper.dart';

/// What home is set to show. Settings > Home & Menus moves these; home
/// reads them and leaves out what is turned off.
///
/// The clock and artwork can be customized; the playback card and library
/// scan banner are standard parts of Home.
abstract final class HomeOptions {
  /// The time, large, in the middle.
  static final clock = ValueNotifier<bool>(true);

  /// And in the bar while something plays, where the page's name would be.
  static final barClock = ValueNotifier<bool>(true);

  /// The cover of what is playing, and how it is fitted.
  static final artwork = ValueNotifier<HomeArtwork>(HomeArtwork.fit);

  /// Home listens to the remaining appearance options together.
  static final changes = Listenable.merge([clock, barClock, artwork]);
}

/// How the cover of what is playing is drawn on home.
enum HomeArtwork {
  /// Filling the room it is given, cropped to it.
  fill,

  /// Whole, with the wallpaper around it.
  fit,

  /// Not at all.
  off;

  /// The one a stored name means, or null for a name this build has not
  /// heard of.
  static HomeArtwork? named(Object? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }
}

/// The boot-continuity screen: the wallpaper - the same image the LOGO
/// partition and plymouth show - seen whole, with the status bar's
/// readings sitting on it, unbacked, in the margin the logo keeps empty.
/// The center button and menu both bring up the dock.
///
/// The root of the Home app's stack, and now playing: the clock, what is
/// playing on a card along the bottom, and - while the library takes in
/// new music - a line under that, which the rest steps up to make room
/// for. It keeps a layout of its own rather than being one more list.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _scrubbing = false;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: VideoPlayback.session,
    builder: (context, video, _) => video != null
        ? VideoNowPlaying(key: ObjectKey(video), video: video)
        : ValueListenableBuilder(
            valueListenable: FmRadioSession.session,
            builder: (context, radio, _) => radio == null
                ? _audioHome(context)
                : FmRadioNowPlaying(key: ObjectKey(radio), session: radio),
          ),
  );

  Widget _audioHome(BuildContext context) {
    return Actions(
      actions: {
        // While playing, center switches the wheel between volume and seeking.
        // An idle home has no playback controls, so center opens the dock.
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            if (PlayerServicesScope.of(context).playback.value.hasTrack) {
              Osd.hide();
              setState(() => _scrubbing = !_scrubbing);
            } else {
              MenuDock.shown.value = true;
            }
            return null;
          },
        ),
        // The wheel controls volume until seeking is explicitly selected.
        JogIntent: CallbackAction<JogIntent>(
          onInvoke: (intent) {
            final services = PlayerServicesScope.of(context);
            if (services.playback.value.hasTrack && _scrubbing) {
              unawaited(
                services.playback.seekBy(
                  Duration(seconds: intent.amount * (intent.page ? 30 : 5)),
                ),
              );
            } else {
              final volume = services.volume;
              unawaited(volume.nudge(intent.amount * (intent.page ? 2 : 1)));
              VolumeOsd.show(volume);
            }
            return null;
          },
        ),
        // Menu too. Everywhere else it backs out of a screen, but home is
        // where backing out ends - so here the key goes the only way it
        // can, which is in.
        WheelBackIntent: CallbackAction<WheelBackIntent>(
          onInvoke: (_) {
            MenuDock.shown.value = true;
            return null;
          },
        ),
      },
      child: Focus(
        autofocus: true,
        debugLabel: 'HomeScreen',
        // Almost nothing of its own: the shell's wallpaper seen through
        // it, the bar over it paints no ground, and the clock on it.
        // Playing, the cover fills the top and the words take a card
        // along the bottom; the clock moves up into the bar's title slot,
        // where "Home" would be - the cover says what this is.
        child: ListenableBuilder(
          listenable: HomeOptions.changes,
          builder: (context, _) => ValueListenableBuilder(
            valueListenable: PlayerServicesScope.of(context).playback,
            builder: (context, now, _) {
              final track = now.track;
              return PublishChrome(
                chrome: BarChrome(
                  ground: false,
                  visible: true,
                  backdrop: Backdrop.clear,
                  clock: track != null && HomeOptions.barClock.value,
                ),
                child: Backdropped(
                  backdrop: Backdrop.clear,
                  child: Column(
                    children: [
                      Expanded(
                        child: Stack(
                          children: [
                            if (track != null &&
                                HomeOptions.artwork.value != HomeArtwork.off)
                              NowPlayingArt(
                                track: track,
                                cover:
                                    HomeOptions.artwork.value ==
                                    HomeArtwork.fill,
                              ),
                            // Chrome: the time of day is the one thing on
                            // home that is not a list, and it keeps its size.
                            if (HomeOptions.clock.value)
                              const FixedScale(
                                scale: chromeScale,
                                child: HomeClock(),
                              ),
                          ],
                        ),
                      ),
                      if (track != null)
                        PlayerDockTransition(
                          visible: true,
                          child: NowPlayingCard(
                            now: now,
                            scrubbing: _scrubbing,
                          ),
                        ),
                      const LibraryFooter(),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Where a menu leaf leads until its real screen exists: the leaf's label,
/// its place in the tree, and the way out.
class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({required this.title, this.path, super.key});

  final String title;

  /// The leaf's path in the menu - `/library/music/songs` - so a screen
  /// that is only a promise at least says which promise.
  final String? path;

  static Route<void> route(String title, {String? path}) => PanelRoute(
    settings: RouteSettings(name: path),
    builder: (_) => PlaceholderScreen(title: title, path: path),
  );

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);

    // The title is on the bar; the body is only where the promise sits.
    return PanelScreen(
      title: title,
      child: ContentMessage(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (path != null) ...[
              CaptionText(
                path!,
                style: theme.typography.code,
                emphasis: TextEmphasis.secondary,
              ),
              SizedBox(height: theme.space.x2),
            ],
            const CaptionText('nothing here yet - menu goes back'),
          ],
        ),
      ),
    );
  }
}

/// The cover of what is playing, filling the top of home: fitted whole
/// into the room between the bar and the card, with a shadow under it so
/// it stands off the wallpaper. Asked for by file, which puts it at the
/// front of the artwork queue, and drawn once it comes; until then - and
/// for a track that has none - a quiet square with a note on it.
class NowPlayingArt extends StatelessWidget {
  const NowPlayingArt({required this.track, this.cover = false, super.key});

  final TrackSummary track;

  /// Whether the cover fills the room it is given, cropped to it, or is
  /// fitted whole inside it with the wallpaper showing around.
  final bool cover;

  static const artKey = Key('NowPlayingArt.image');
  static const placeholderKey = Key('NowPlayingArt.placeholder');

  @override
  Widget build(BuildContext context) {
    final library = PlayerServicesScope.of(context).library;
    final theme = ThemeProvider.of(context);
    final radius = BorderRadius.circular(theme.space.x1);
    final shadow = BoxDecoration(
      borderRadius: radius,
      boxShadow: const [
        BoxShadow(
          color: Color(0x99000000),
          blurRadius: 10,
          offset: Offset(0, 3),
        ),
      ],
    );
    return Padding(
      // Under the bar, off the edges, a breath above the card.
      padding: EdgeInsets.fromLTRB(
        theme.space.x4,
        chromeScale.barHeight + theme.space.x2,
        theme.space.x4,
        theme.space.x2,
      ),
      child: Center(
        child: FutureBuilder(
          key: ValueKey(track.fileId),
          future: library.artwork(track.fileId),
          builder: (context, snapshot) {
            final bytes = snapshot.data;
            if (bytes == null) {
              return AspectRatio(
                aspectRatio: 1,
                child: DecoratedBox(
                  decoration: shadow.copyWith(color: const Color(0x66000000)),
                  child: Icon(
                    LucideIcons.music,
                    key: placeholderKey,
                    size: theme.sizes.iconLarge,
                    color: const Color(0xB3FFFFFF),
                  ),
                ),
              );
            }
            // The image sizes itself to fit the room and keep its shape,
            // so the shadow's box is exactly the picture's.
            return DecoratedBox(
              decoration: shadow,
              child: ClipRRect(
                borderRadius: radius,
                child: Image.memory(
                  bytes,
                  key: artKey,
                  fit: cover ? BoxFit.cover : BoxFit.contain,
                  gaplessPlayback: true,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// What is playing, along the bottom of home: the title, who it is by,
/// how far through it is, and the clocks, on a card in the theme's
/// neutral swatch. The cover is [NowPlayingArt], above.
class NowPlayingCard extends StatelessWidget {
  const NowPlayingCard({required this.now, this.scrubbing = false, super.key});

  final NowPlaying now;
  final bool scrubbing;

  static const cardKey = Key('NowPlayingCard');
  static const barKey = Key('NowPlayingCard.bar');

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final track = now.track;
    if (track == null) return const SizedBox.shrink();
    // The neutral's wash, like a notice: the card is a strip of fact along
    // the foot of home - what is playing - and it is the controls on it,
    // the bar and its thumb, that wear the brand's color, so the eye goes
    // to what the wheel can move.
    final dress = theme.widgets.surface.resolve(
      SemanticSwatch.neutral,
      SurfaceVariant.subtle,
    );
    final ink = dress.foreground;
    final inkQuiet = ink.withValues(alpha: 0.7);
    final title = theme.typography.body.copyWith(color: ink);
    final caption = theme.typography.caption.copyWith(color: inkQuiet);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        theme.space.x4,
        0,
        theme.space.x4,
        theme.space.x2,
      ),
      child: DecoratedBox(
        key: cardKey,
        decoration: BoxDecoration(
          color: dress.fill,
          border: dress.border == null
              ? null
              : Border.all(color: dress.border!, width: theme.strokes.hairline),
          // Squarer than the surface's own: the card is a strip along the
          // foot of home rather than a floating chip.
          borderRadius: theme.radii.small,
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: theme.space.x3,
            vertical: theme.space.x2,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                track.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: title,
              ),
              Text(
                [?track.artist, ?track.album].join(' - '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: caption,
              ),
              SizedBox(height: theme.space.x1),
              PlaybackProgress(value: now.progress, scrubbing: scrubbing),
              SizedBox(height: theme.space.x1),
              Row(
                children: [
                  Text(_clock(now.position), style: caption),
                  const Spacer(),
                  Text(_clock(now.duration), style: caption),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _clock(Duration d) {
    final minutes = d.inMinutes;
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

/// A stable-height timeline with an explicit wheel-seeking focus state.
class PlaybackProgress extends StatelessWidget {
  const PlaybackProgress({
    required this.value,
    required this.scrubbing,
    super.key,
  });
  final double value;
  final bool scrubbing;
  static const thumbKey = Key('PlaybackProgress.thumb');
  static const focusKey = Key('PlaybackProgress.focus');

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final ink = theme.widgets.surface
        .resolve(SemanticSwatch.primary, SurfaceVariant.soft)
        .foreground;
    return Semantics(
      label: scrubbing ? 'Scrub mode' : 'Volume mode',
      value: '${(value.clamp(0.0, 1.0) * 100).round()}%',
      child: AnimatedContainer(
        key: focusKey,
        duration: theme.motion.standard,
        height: 16,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: scrubbing ? ink : ink.withValues(alpha: 0)),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            OsdBar(value: value, height: 4, litKey: NowPlayingCard.barKey),
            if (scrubbing)
              Align(
                alignment: Alignment(value.clamp(0.0, 1.0) * 2 - 1, 0),
                child: DecoratedBox(
                  key: thumbKey,
                  decoration: BoxDecoration(color: ink, shape: BoxShape.circle),
                  child: const SizedBox.square(dimension: 10),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The player dock folds toward the bottom edge as it fades away.
/// Keeping the transition mounted allows a second toggle to reverse it.
class PlayerDockTransition extends StatelessWidget {
  const PlayerDockTransition({
    required this.visible,
    required this.child,
    super.key,
  });
  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final motion = ThemeProvider.of(context).motion;
    return TweenAnimationBuilder<double>(
      tween: Tween(end: visible ? 1.0 : 0.0),
      duration: motion.standard,
      curve: motion.move,
      child: child,
      builder: (context, value, child) {
        if (value == 0) return const SizedBox.shrink();
        return IgnorePointer(
          ignoring: !visible,
          child: ClipRect(
            child: Align(
              alignment: Alignment.topCenter,
              heightFactor: value,
              child: Opacity(
                opacity: value.clamp(0.0, 1.0),
                child: FractionalTranslation(
                  translation: Offset(0, (1 - value) * 0.15),
                  child: child,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
