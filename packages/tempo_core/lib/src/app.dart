import 'dart:async';
import 'dart:io' show Platform;

import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

import 'appearance.dart';
import 'applet.dart';
import 'services/services.dart';
import 'services/video_playback.dart';
import 'debug_menu.dart';
import 'audio_route_dialog.dart';
import 'dock.dart';
import 'osd.dart';
import 'power.dart';
import 'scale.dart';
import 'settings/setting_bindings.dart';
import 'settings/settings.dart';
import 'settings/settings_file.dart';
import 'settings/settings_tree.dart';
import 'settings/time_zone_screen.dart';
import 'shade.dart';
import 'status.dart';
import 'theme_fade.dart';
import 'wheel_settings.dart';
import 'wallpaper.dart';
import 'settings/data_storage_screen.dart';

class TempoApp extends StatefulWidget {
  const TempoApp({this.wheel, this.services, this.settings, super.key});

  /// A hand on the hardware, for a host that draws its own: the emulator's
  /// click wheel presses this. Null on the player, whose wheel is real.
  final ClickWheelController? wheel;

  /// What the player is told about the machine under it. Null takes the
  /// machine's own answer - which on the device is the only right one, and
  /// off it is a battery that reads as dashes.
  final PlayerServices? services;

  /// What the player is set to. Null opens the player's own - the shipped
  /// tree, the file it lives in, and the far end that answers it - which
  /// is what both binaries want. A test hands in one of its own.
  final Settings? settings;

  @override
  State<TempoApp> createState() => _TempoAppState();

  /// Make the player's settings, put them behind the file they live in,
  /// and hook the far end up to [services].
  ///
  /// The order is the whole of a boot: read the file, catch the machine up
  /// with what it says ([SettingsBridge.applyAll]), and only then start
  /// writing changes back - otherwise the read itself would schedule a
  /// write of what was just read.
  static Future<SettingsFile> open(
    Settings store, {
    required PlayerServices services,
  }) async {
    final bridge = PlayerSettings.install(store, services: services);
    final file = SettingsFile.at(
      services.places.value,
      settings: store,
      readRemote: services.readSettings,
      writeRemote: services.writeSettings,
    );
    await file.load();
    bridge.applyAll();
    file.watch();
    SettingCapabilities.followDeveloperMode();
    return file;
  }

  /// The navigator, reachable from above it: the power chord arrives at
  /// the app's root, outside the navigator's subtree.
  static final _navigator = GlobalKey<NavigatorState>();

  /// How far a held previous or next moves within the track.
  static const seekStride = Duration(seconds: 10);
}

/// Whether this is a test run rather than a player.
final bool _underTest = Platform.environment.containsKey('FLUTTER_TEST');

class _TempoAppState extends State<TempoApp> {
  /// What the player is set to. The one handed in, or the player's own -
  /// opened once, here, because this widget is the only thing both
  /// binaries build.
  late final Settings _settings =
      widget.settings ?? Settings(tree: playerSettingsTree);

  SettingsFile? _file;
  Future<SettingsFile>? _openingSettings;
  DataStorageController? _dataStorage;
  bool _storagePrompted = false;
  bool _storagePaused = false;

  void _storageChanged() {
    final controller = _dataStorage;
    if (controller == null || !mounted) return;
    final status = controller.value;
    if (status.busy || status.restarting) {
      _file?.pauseWrites();
      _storagePaused = true;
    } else if (_storagePaused) {
      _file?.watch();
      _storagePaused = false;
    }
    // The question is asked once per card: taking the card out clears the
    // way for the next one to ask again.
    if (!status.cardPresent) _storagePrompted = false;
    if (_storagePrompted ||
        status.busy ||
        status.restarting ||
        !status.available) {
      return;
    }
    final navigator = TempoApp._navigator.currentState;
    if (navigator == null) return;
    if (status.policy == DataStoragePolicy.no ||
        !status.promptAvailable ||
        !status.cardPresent) {
      return;
    }
    _storagePrompted = true;
    unawaited(
      navigator.push(
        DialogRoute<void>(
          barrierDismissible: false,
          theme: UiScale.regular.theme(Appearance.brightness.value),
          builder: (context) => DataStoragePrompt(
            controller: controller,
            onDone: () => Navigator.of(context).pop(),
          ),
        ),
      ),
    );
  }

  StreamSubscription<AudioOutput>? _audioArrivals;
  Route<bool>? _audioQuestion;
  Future<void> _routeChange = Future<void>.value();

  Future<void> _onAudioDevice(AudioOutput device) async {
    final services = widget.services ?? PlayerServices.fallback;
    // The local DAC/route policy owns speaker <-> headphone switching.
    // Only crossing between local audio and Bluetooth needs a decision.
    if ((services.output.value.kind == OutputKind.bluetooth) ==
        (device.kind == OutputKind.bluetooth)) {
      return;
    }
    final navigator = TempoApp._navigator.currentState;
    if (_audioQuestion case final old?) {
      _audioQuestion = null;
      navigator?.removeRoute(old);
    }
    final mode = services.output.onNewDevice.value;
    if (mode == 'ignore') return;
    if (mode == 'ask') {
      if (navigator == null) return;
      unawaited(services.screen.setOn(true));
      final route = DialogRoute<bool>(
        theme: UiScale.regular.theme(Appearance.brightness.value),
        builder: (_) => AudioRouteDialog(output: device),
      );
      _audioQuestion = route;
      final accepted = await navigator.push(route);
      if (!mounted || !identical(_audioQuestion, route)) return;
      _audioQuestion = null;
      if (accepted != true) return;
    }
    try {
      // Preserve arrival order even if two route requests take different
      // amounts of time. A failed earlier request must not block the next.
      _routeChange = _routeChange.then(
        (_) => services.output.select(device),
        onError: (Object _, StackTrace _) => services.output.select(device),
      );
      await _routeChange;
    } on Object {
      // The device may have disappeared while its question was open.
    }
  }

  @override
  void initState() {
    super.initState();
    PlayerSettingScreens.install();
    _dataStorage = (widget.services ?? PlayerServices.fallback).dataStorage;
    _dataStorage?.beforeChange = () async {
      final services = widget.services ?? PlayerServices.fallback;
      await services.playback.stop();
      await VideoPlayback.active?.stop();
      await _openingSettings;
      AppletState.flushForStorageChange();
      await _file?.flushForStorageChange();
      _storagePaused = true;
    };
    _dataStorage?.addListener(_storageChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _storageChanged());
    _audioArrivals = (widget.services ?? PlayerServices.fallback)
        .output
        .arrivals
        .listen((device) => unawaited(_onAudioDevice(device)));
    // A store the app made is the player's, and the player's is persisted
    // and answered. One handed in is a test's or an OOBE's: it says what
    // it wants and nothing here reaches around it.
    //
    // Not under the harness, whichever kind of store it is: opening the
    // player's would read the file of whoever is running the tests and
    // send its every setting to a daemon that is not there.
    if (widget.settings == null && !_underTest) {
      unawaited(
        (_openingSettings = TempoApp.open(
          _settings,
          services: widget.services ?? PlayerServices.fallback,
        )).then(
          (file) {
            if (mounted) {
              _file = file;
              _storageChanged();
            } else {
              file.dispose();
            }
          },
          onError: (Object error, StackTrace stack) {
            debugPrint('settings: could not load saved choices: $error');
          },
        ),
      );
    }
  }

  @override
  void dispose() {
    _dataStorage?.removeListener(_storageChanged);
    _dataStorage?.beforeChange = null;
    // Whatever is still waiting to be written is written now.
    _audioArrivals?.cancel();
    _file?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        Appearance.theme,
        WheelSettings.feel,
        WheelSettings.letterEntry,
        WheelSettings.letterIdle,
      ]),
      // The theme moves whenever the scale does, so the scale read here is
      // always the one the theme was made at.
      builder: (context, _) =>
          _app(Appearance.theme.value, Appearance.scale.value),
    );
  }

  Widget _app(Theme theme, UiScale scale) {
    final wheel = widget.wheel;
    final services = widget.services ?? PlayerServices.fallback;
    final screen = services.screen;

    final app = TomeApp(
      theme: theme,
      title: 'Tempo',
      debugShowCheckedModeBanner: false,
      navigatorKey: TempoApp._navigator,
      // Over the whole app and under the theme: the light changing is a
      // cut everywhere at once, and this is what softens it.
      builder: (context, child) => ThemeFade(
        brightness: theme.palette.brightness,
        duration: theme.motion.standard,
        curve: theme.motion.move,
        child: ValueListenableBuilder(
          valueListenable: screen,
          // Above the navigator, so every route is drawn at the one scale.
          child: UiScaleScope(scale: scale, child: child!),
          builder: (context, awake, child) => IdleSleep(
            screen: screen,
            builder: (context, touch) => ClickWheelInput(
              controller: wheel,
              feel: WheelSettings.feel.value,
              // Asleep, the wheel says nothing - a thumb on it in a pocket
              // must not walk the menus blind - and the center and menu only
              // wake; but the media buttons, the rocker and the power chord
              // speak as ever. Every word, awake, keeps the screen awake a
              // while longer.
              asleep: !awake,
              onWake: () => unawaited(screen.setOn(true)),
              // The short words: play, next, previous, to the player.
              onMedia: (command) => _media(services, command),
              // The long words. Holding play puts the player to sleep, as it
              // always has on a click wheel; holding previous or next seeks
              // a stretch (flutter-pi never repeats a held key, so it is one
              // jump per hold).
              onMediaHold: (command) => _mediaHold(services, command),
              // The rocker, from any screen, awake or asleep.
              onVolume: (direction) => _volume(services, direction),
              onPower: (press) => _power(screen, press),
              // Every word gets its sound and its shake, and resets the
              // sleep clock.
              onWord: (word) {
                touch();
                services.feedback.word(word);
              },
              child: WheelAcceleration(
                enabled: WheelSettings.feel.value.acceleration,
                letterEntry: WheelSettings.letterEntry.value,
                letterIdle: WheelSettings.letterIdle.value,
                surfaceBuilder: (context, child) => ListenableBuilder(
                  listenable: Backdropped.changes,
                  builder: (context, _) {
                    final theme = ThemeProvider.of(context);
                    return Surface.custom(
                      style: theme.widgets.surface
                          .resolve(
                            SemanticSwatch.neutral,
                            SurfaceVariant.subtle,
                          )
                          .copyWith(
                            fill: Backdropped.surfaceOf(
                              theme.palette,
                              focus: CoverFocus.of(context),
                            ),
                          ),
                      child: child,
                    );
                  },
                ),
                child: ScreenShade(
                  screen: screen,
                  // The shell - wallpaper, apps, bar and dock - is the root
                  // navigator's home, so the power dialog lands over all of it;
                  // and above that only the frame counter, which rides along
                  // while we chase performance, pinned to the bottom-right
                  // corner - the top corners belong to the bar's readings - and
                  // over the dock too, since the switcher is exactly what is
                  // being measured; pull it once the numbers are boring.
                  child: Stack(
                    textDirection: TextDirection.ltr,
                    children: [
                      child!,
                      // The notices - the volume while it moves, the output
                      // when it changes - over everything but the frame counter.
                      // (The library taking in music is a line on home, not a
                      // notice.)
                      VolumeToasts(volume: services.volume, awake: awake),
                      OutputToasts(output: services.output),
                      CardToasts(storage: services.storage),
                      const OsdLayer(),
                      Positioned(
                        bottom: 2,
                        right: 2,
                        child: IgnorePointer(
                          child: ValueListenableBuilder(
                            valueListenable: DebugSettings.frameCounter,
                            builder: (context, on, _) =>
                                on ? const FpsText() : const SizedBox.shrink(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      home: const DockShell(),
    );

    final scoped = SettingsScope(settings: _settings, child: app);
    return widget.services == null
        ? scoped
        : PlayerServicesScope(services: services, child: scoped);
  }

  /// The rocker: one step per press, the display up while it moves. Asleep
  /// the level still moves - a pocket press is meant - but the panel stays
  /// dark; the display is for eyes that are on it.
  static void _volume(PlayerServices services, int direction) {
    unawaited(services.volume.nudge(direction));
    if (services.screen.value) VolumeOsd.show(services.volume);
  }

  /// A media button pressed: the player's three words.
  static void _media(PlayerServices services, MediaCommand command) {
    final radio = FmRadioSession.active;
    if (radio != null) {
      switch (command) {
        case MediaCommand.toggle:
          unawaited(radio.togglePower());
        case MediaCommand.previous:
          radio.media(FmSeekDirection.down, held: false);
        case MediaCommand.next:
          radio.media(FmSeekDirection.up, held: false);
      }
      return;
    }
    final playback = VideoPlayback.active ?? services.playback;
    unawaited(switch (command) {
      MediaCommand.toggle => playback.toggle(),
      MediaCommand.previous => playback.previous(),
      MediaCommand.next => playback.next(),
    });
  }

  /// A media button held. Play held is stop - the queue let go, the card
  /// off home - and previous and next seek within the track. (Play held
  /// used to sleep the screen, the click wheel's oldest gesture, but a
  /// thumb resting on it in a pocket put the screen out too easily.)
  static void _mediaHold(PlayerServices services, MediaCommand command) {
    final radio = FmRadioSession.active;
    if (radio != null) {
      switch (command) {
        case MediaCommand.toggle:
          unawaited(FmRadioSession.stopActive());
        case MediaCommand.previous:
          radio.media(FmSeekDirection.down, held: true);
        case MediaCommand.next:
          radio.media(FmSeekDirection.up, held: true);
      }
      return;
    }
    switch (command) {
      case MediaCommand.toggle:
        unawaited((VideoPlayback.active ?? services.playback).stop());
      case MediaCommand.previous:
        unawaited(
          (VideoPlayback.active ?? services.playback).seekBy(
            -TempoApp.seekStride,
          ),
        );
      case MediaCommand.next:
        unawaited(
          (VideoPlayback.active ?? services.playback).seekBy(
            TempoApp.seekStride,
          ),
        );
    }
  }

  /// What the power button does. One tap puts the screen to sleep, or
  /// wakes it; two taps toggle the dock. A hold opens the power dialog to show
  /// it, and a hold while it is up closes it again. Deeper sleep - the CPU, not just the panel - comes later, behind
  /// rules of its own (a wait, no media playing, not on the charger).
  static void _power(ScreenService screen, PowerPress press) {
    switch (press) {
      case PowerHold():
        unawaited(screen.setOn(true));
        // The dialog takes the wheel; the dock, which would also want it,
        // goes away rather than waiting underneath.
        MenuDock.shown.value = false;
        PowerDialog.toggle(TempoApp._navigator.currentState);
      case PowerTaps(taps: 2):
        unawaited(screen.setOn(true));
        PowerDialog.dismiss();
        MenuDock.toggle();
      case PowerTaps(taps: 1):
        unawaited(screen.setOn(!screen.value));
      case PowerTaps(:final taps):
        debugPrint('power: $taps tap(s)');
    }
  }
}

/// The clock that puts the screen to sleep: restarted by every word the
/// wheel says while the screen is awake, and by the screen waking; put
/// down while it sleeps. At [ScreenSleep.dimAfter] the screen dims - the
/// warning - and any word then brings the light back
/// and winds the clock again; when it runs out the screen goes dark, the
/// way a tap of the power key would send it. [ScreenSleep.after] says how
/// long; null and it never runs, and nor does it while
/// [ScreenSleep.inhibited] holds it.
class IdleSleep extends StatefulWidget {
  const IdleSleep({required this.screen, required this.builder, super.key});

  final ScreenService screen;

  /// Builds the input, handed the hand that resets the clock.
  final Widget Function(BuildContext context, VoidCallback touch) builder;

  @override
  State<IdleSleep> createState() => _IdleSleepState();
}

class _IdleSleepState extends State<IdleSleep> {
  Timer? _clock;
  Timer? _dimmer;

  @override
  void initState() {
    super.initState();
    widget.screen.addListener(_screenMoved);
    ScreenSleep.after.addListener(_restart);
    ScreenSleep.dimAfter.addListener(_restart);
    ScreenSleep.inhibited.addListener(_restart);
    VideoPlayback.keepAwake.addListener(_restart);
    _restart();
  }

  @override
  void didUpdateWidget(IdleSleep oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.screen != oldWidget.screen) {
      oldWidget.screen.removeListener(_screenMoved);
      widget.screen.addListener(_screenMoved);
      _restart();
    }
  }

  @override
  void dispose() {
    widget.screen.removeListener(_screenMoved);
    ScreenSleep.after.removeListener(_restart);
    ScreenSleep.dimAfter.removeListener(_restart);
    ScreenSleep.inhibited.removeListener(_restart);
    VideoPlayback.keepAwake.removeListener(_restart);
    _clock?.cancel();
    _dimmer?.cancel();
    super.dispose();
  }

  void _screenMoved() => _restart();

  /// Wind the clock: from now, if the screen is awake and there is a
  /// wait to keep; otherwise put it down.
  void _restart() {
    _clock?.cancel();
    _clock = null;
    _dimmer?.cancel();
    _dimmer = null;
    if (widget.screen.value && widget.screen.dimmed.value) {
      unawaited(widget.screen.setDimmed(false));
    }
    final after = ScreenSleep.after.value;
    if (after == null ||
        ScreenSleep.inhibited.value ||
        VideoPlayback.keepAwake.value ||
        !widget.screen.value) {
      return;
    }
    // The dim is its own wait from the same moment, not a countdown to
    // the sleep: one at or past the sleep simply never lands, which is
    // how "no warning" is said.
    final dimAt = ScreenSleep.dimAfter.value;
    if (dimAt != null && dimAt > Duration.zero && dimAt < after) {
      _dimmer = Timer(dimAt, () {
        if (!mounted || !widget.screen.value) return;
        unawaited(widget.screen.setDimmed(true));
      });
    }
    _clock = Timer(after, () {
      if (!mounted || !widget.screen.value) return;
      unawaited(widget.screen.setOn(false));
    });
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _restart);
}
