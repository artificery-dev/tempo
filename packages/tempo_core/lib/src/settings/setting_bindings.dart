import 'dart:async';
import 'dart:io' show FileSystemException;

import 'package:tomeui/tomeui.dart';

import '../appearance.dart';
import '../debug_menu.dart';
import '../dock.dart';
import '../menu/menu_node.dart';
import '../menu/menu_screen.dart';
import '../power.dart';
import '../osd.dart';
import '../scale.dart';
import '../screens.dart';
import '../services/services.dart';
import '../status.dart';
import '../storage/places.dart';
import '../wallpaper.dart';
import '../time_zones.dart';
import '../wheel_settings.dart';
import 'settings.dart';

/// What a bind key does when its setting moves.
///
/// It is handed the whole [SettingChange], so a sink can see where the
/// value came from, what it was, and what the item says about itself
/// (its bounds, its store) without going back to the tree.
typedef SettingSink = void Function(SettingChange change);

/// What a bind key does when an action is invoked. Actions carry no value,
/// so there is nothing to hand over but the path.
typedef SettingAction = void Function(String path);

/// The far end of a setting: the code that actually moves something.
///
/// The tree says `bind: appearance.mode` and this is the other half, where
/// `appearance.mode` becomes a write to [Appearance.mode] - the same trick
/// `MenuScreens` plays with screens, and for the same reason. A change
/// arrives here from [SettingsBridge] whether it came from the settings
/// screens, the quick settings sheet, an OOBE page or a restored backup,
/// so the machinery that answers a setting is written once.
///
/// A key nobody has registered is a setting that cannot do anything yet.
/// That is not an error and not a crash: the screens read [keys] and show
/// those rows disabled, which is the honest state for most of a tree whose
/// hardware is still being brought up.
abstract final class SettingBindings {
  static final Map<String, SettingSink> _sinks = {};
  static final Map<String, SettingAction> _actions = {};

  /// Every key something answers.
  static Set<String> get keys => {..._sinks.keys, ..._actions.keys};

  static bool knows(String key) =>
      _sinks.containsKey(key) || _actions.containsKey(key);

  /// Offer to answer [key]. A later registration replaces an earlier one,
  /// which is how a plugin takes a setting over.
  static void register(String key, SettingSink sink) {
    _actions.remove(key);
    _sinks[key] = sink;
  }

  /// Offer to answer an action's [key].
  static void registerAction(String key, SettingAction action) {
    _sinks.remove(key);
    _actions[key] = action;
  }

  static void registerAll(Map<String, SettingSink> sinks) =>
      sinks.forEach(register);

  static void registerActions(Map<String, SettingAction> actions) =>
      actions.forEach(registerAction);

  /// Forget everything. For a test that installs its own.
  static void clear() {
    _sinks.clear();
    _actions.clear();
  }

  /// Answer a change, if anybody does. Returns whether anybody did.
  static bool apply(SettingChange change) {
    final key = change.bind;
    if (key == null) return false;
    final sink = _sinks[key];
    if (sink == null) return false;
    sink(change);
    return true;
  }

  /// Invoke an action. Returns whether anybody answered.
  static bool invoke(String key, String path) {
    final action = _actions[key];
    if (action == null) return false;
    action(path);
    return true;
  }
}

/// Listens to a [Settings] and forwards every change to whatever
/// [SettingBindings] says answers it.
///
/// One of these, made once and left running: it is the thing between "the
/// user moved a switch" and "the backlight changed". Nothing else has to
/// know both ends, and a screen that moves a setting does not have to know
/// whether that setting is a field in this process, a line to the daemon,
/// or nothing at all yet.
class SettingsBridge {
  SettingsBridge({required this.settings});

  final Settings settings;
  VoidCallback? synchronize;
  VoidCallback? onDetach;

  StreamSubscription<SettingChange>? _subscription;

  /// Changes nobody answered, newest last. Kept for the debug screen and
  /// for tests: a setting whose bind key is a typo is silent otherwise.
  final List<SettingChange> unanswered = [];

  /// How many are kept.
  static const int unansweredKept = 32;

  void attach() {
    _subscription ??= settings.changes.listen(_forward);
  }

  void detach() {
    onDetach?.call();
    onDetach = null;
    _subscription?.cancel();
    _subscription = null;
  }

  void _forward(SettingChange change) {
    if (SettingBindings.apply(change)) return;
    // A setting with no bind at all is not unanswered: being stored is
    // the whole of what it does.
    if (change.bind == null) return;
    unanswered.add(change);
    if (unanswered.length > unansweredKept) unanswered.removeAt(0);
    debugPrint('settings: nobody answers ${change.bind} (${change.path})');
  }

  /// Push every setting's current value out through its sink, as though it
  /// had just been moved by the machine.
  ///
  /// What a boot needs: the file has been read, and the theme, the
  /// backlight and the rest have to catch up with it. Only the settings
  /// somebody answers are sent, and each is sent once.
  void applyAll({SettingSource source = SettingSource.system}) {
    synchronize?.call();
    for (final entry in settings.tree.settings) {
      final bind = entry.node.bind;
      if (bind == null || !SettingBindings.knows(bind)) continue;
      final value = settings.value(entry.path);
      SettingBindings.apply(
        SettingChange(
          path: entry.path,
          node: entry.node,
          from: value,
          to: value,
          source: source,
        ),
      );
    }
  }
}

/// What this player can actually do, for the items that name `needs`.
///
/// An item whose capability is missing is not shown at all - a Wi-Fi row
/// on a player whose radio has no driver is not a row to hunt for, and it
/// is not a row to grey out either. The app says what it has: the device
/// binary adds `device`, developer mode adds `dev`, and the radios say
/// nothing until their drivers land.
abstract final class SettingCapabilities {
  static final ValueNotifier<Set<String>> available = ValueNotifier(const {});

  static bool has(String capability) => available.value.contains(capability);

  static void add(String capability) =>
      available.value = {...available.value, capability};

  static void remove(String capability) =>
      available.value = {...available.value}..remove(capability);

  /// Keep `dev` in step with the developer-mode switch, whoever moved it.
  static void followDeveloperMode() {
    void update() => DebugSettings.enabled.value ? add('dev') : remove('dev');
    DebugSettings.enabled.addListener(update);
    update();
  }
}

/// The player's own far end: every setting that moves something today.
///
/// Deliberately short. Most of the tree is settings for hardware that is
/// still being brought up (the radios, the USB modes, an equalizer with no
/// filter behind it) and for machinery that does not exist (updates,
/// backups, a PIN), and those keys are not registered here - so the
/// screens draw them disabled rather than lying about them.
///
/// What is here moves a notifier in this process or a line to the daemon.
abstract final class PlayerSettings {
  /// Register the lot against [services], and forward from [settings].
  ///
  /// Returns the bridge, attached: hold it for as long as the app lives.
  static SettingsBridge install(
    Settings settings, {
    required PlayerServices services,
  }) {
    SettingBindings.registerAll(sinks(services, settings: settings));
    SettingBindings.registerActions(actions(services, settings: settings));
    final bridge = SettingsBridge(settings: settings)..attach();
    if (services.library case final MediaLibrary library) {
      library.configureFolders(settings.value('/settings/library/roots'));
      library.scanOnStartup =
          settings.value('/settings/library/scan-on-boot') != false;
      library.scanOnCard =
          settings.value('/settings/library/scan-on-card') != false;
      library.recheck =
          '${settings.value('/settings/library/recheck') ?? 'startup'}';
    }
    final radios = services.radios;
    if (radios != null) {
      SettingCapabilities.add('wifi');
      SettingCapabilities.add('bluetooth');
      void sync() {
        settings.set(
          '/settings/connections/wifi/enabled',
          radios.wifi.value.status != WifiStatus.off,
          source: SettingSource.system,
        );
        settings.set(
          '/settings/connections/bluetooth/enabled',
          radios.bluetooth.value.status != BluetoothStatus.off,
          source: SettingSource.system,
        );
      }

      radios.addListener(sync);
      bridge.synchronize = sync;
      bridge.onDetach = () => radios.removeListener(sync);
      sync();
    }
    return bridge;
  }

  static int _zoneRequest = 0;
  static bool _rollingBackZone = false;

  static Future<void> _setTimeZone(
    String zone,
    PlayerServices services,
    Settings? settings,
  ) async {
    final request = ++_zoneRequest;
    try {
      // Reject unknown zones before changing the machine.
      ClockZone.location(zone);
      final device = services.timeZone;
      if (device != null) await device.setZone(zone);
      ClockZone.selected.value = zone;
      Appearance.place.value = TimeZones.placeOf(zone);
    } on Object catch (error) {
      debugPrint('time zone: $zone not applied: $error');
      // Let the settings stream finish delivering the original selection.
      await Future<void>.value();
      if (request != _zoneRequest) return;
      if (settings != null) {
        _rollingBackZone = true;
        try {
          settings.set(
            '/settings/system/time/zone',
            ClockZone.selected.value,
            source: SettingSource.system,
          );
        } finally {
          _rollingBackZone = false;
        }
      }
      Osd.show(
        (context) => const OsdToast(
          icon: LucideIcons.clock,
          body: BodyText('Could not set the time zone. Try again.'),
        ),
      );
    }
  }

  /// The settings that move something, by bind key.
  static Map<String, SettingSink> sinks(
    PlayerServices services, {
    Settings? settings,
  }) => {
    'library.scanOnBoot': (change) {
      if (services.library case final MediaLibrary library) {
        library.scanOnStartup = change.to == true;
      }
    },
    'library.scanOnCard': (change) {
      if (services.library case final MediaLibrary library) {
        library.scanOnCard = change.to == true;
      }
    },
    'library.recheck': (change) {
      if (services.library case final MediaLibrary library) {
        library.recheck = '${change.to}';
      }
    },
    'library.roots': (change) {
      if (services.library case final MediaLibrary library) {
        library.configureFolders(change.to);
      }
    },
    if (services.radios case final radios?) ...{
      'wifi.enabled': (change) {
        if (change.source != SettingSource.system) {
          unawaited(radios.enableWifi(change.to == true));
        }
      },
      'bluetooth.enabled': (change) {
        if (change.source != SettingSource.system) {
          unawaited(radios.enableBluetooth(change.to == true));
        }
      },
      'wifi.network': (_) {},
      'wifi.known': (_) {},
      'bluetooth.devices': (_) {},
    },
    // -- Appearance ------------------------------------------------------
    'appearance.mode': (change) {
      Appearance.mode.value = AppearanceMode.values.firstWhere(
        (mode) => mode.name == change.to,
        orElse: () => Appearance.mode.value,
      );
    },
    // The three the UI is mixed from. An unrecognised name leaves the
    // notifier holding it and the theme falling back to Tome's own for
    // that role, which is what a settings file written by a newer build
    // should come to rather than a crash.
    'appearance.primary': (change) => Appearance.primary.value = '${change.to}',
    'appearance.accent': (change) => Appearance.accent.value = '${change.to}',
    'appearance.neutral': (change) => Appearance.neutral.value = '${change.to}',

    // -- Status Bar ------------------------------------------------------
    'status.batteryIcon': (change) =>
        StatusReadings.batteryIcon.value = change.to == true,
    'status.wifiIcon': (change) =>
        StatusReadings.wifiIcon.value = change.to == true,
    'status.bluetoothIcon': (change) =>
        StatusReadings.bluetoothIcon.value = change.to == true,
    'status.playGlyph': (change) =>
        StatusReadings.playGlyph.value = change.to == true,
    'status.hideIdle': (change) =>
        StatusReadings.hideIdle.value = change.to == true,
    'status.batteryPercent': (change) =>
        StatusReadings.batteryPercent.value = change.to == true,

    // -- Wallpaper -------------------------------------------------------
    // The picture itself is written by the picker, which has already taken
    // it in and put it on screen; the stored name is what the row reads
    // back and what the picker opens on. Registered even so: a bind key
    // nobody answers is a row the screens draw disabled, and this one is a
    // page that very much works.
    'wallpaper.image': (_) {},
    'wallpaper.tint': (change) {
      final percent = change.to;
      if (percent is num) Backdropped.tint.value = percent / 100;
    },
    'wallpaper.glass': (change) => Glass.enabled.value = change.to == true,

    // How a picture that is not the panel's shape is fitted to it. The
    // stored one is already cropped to cover, so this is about a wallpaper
    // that came from somewhere else - and about a person who would rather
    // see the whole of theirs than the middle of it.
    'wallpaper.fit': (change) {
      final fit = WallpaperSource.fitNamed(change.to);
      if (fit != null) WallpaperSource.fit.value = fit;
    },

    // Which of the wallpaper's readings of itself the UI is mixed from.
    'wallpaper.autoPalette': (change) {
      final at = change.to;
      if (at is num) WallpaperSource.paletteIndex.value = at.round();
    },

    'appearance.scale': (change) {
      Appearance.scale.value = UiScale.values.firstWhere(
        (scale) => scale.name == change.to,
        orElse: () => Appearance.scale.value,
      );
    },

    // -- Time & Language -------------------------------------------------
    'wheel.acceleration': (change) => WheelSettings.feel.value = WheelSettings
        .feel
        .value
        .copyWith(acceleration: change.to == true),
    'wheel.sensitivity': (change) => WheelSettings.setFirmness('${change.to}'),

    'time.hour': (change) => ClockFormat.hour24.value = change.to != 12,
    'time.zone': (change) {
      final zone = change.to;
      if (zone is! String || _rollingBackZone) return;
      unawaited(_setTimeZone(zone, services, settings));
    },

    // -- Display ---------------------------------------------------------
    // The backlight, through the daemon: a percent here, raw levels there.
    'screen.brightness': (change) {
      final percent = change.to;
      if (percent is num) {
        unawaited(services.screen.setBrightness(percent.round()));
      }
    },
    'sleep.after': (change) => ScreenSleep.after.value = _duration(change.to),
    'sleep.dimAfter': (change) =>
        ScreenSleep.dimAfter.value = _duration(change.to),

    // -- Sound -----------------------------------------------------------
    'volume.level': (change) {
      final level = change.to;
      // A change the mixer itself reported is already true; sending it
      // back would be a loop.
      if (level is num && change.source != SettingSource.system) {
        unawaited(services.volume.setLevel(level.round()));
      }
    },
    'output.onNewDevice': (change) =>
        services.output.onNewDevice.value = '${change.to}',
    'feedback.sounds': (change) =>
        services.feedback.sounds.value = change.to == true,
    'feedback.speaker-only': (change) =>
        services.feedback.speakerOnly.value = change.to == true,
    'feedback.sound-type': (change) =>
        services.feedback.soundType.value = '${change.to}',
    'feedback.haptic-feel': (change) =>
        services.feedback.hapticFeel.value = '${change.to}',
    'feedback.haptics': (change) =>
        services.feedback.haptics.value = change.to == true,

    // -- Home & Menus ----------------------------------------------------
    'home.clock': (change) => HomeOptions.clock.value = change.to == true,
    'home.barClock': (change) => HomeOptions.barClock.value = change.to == true,
    'home.artwork': (change) {
      final artwork = HomeArtwork.named(change.to);
      if (artwork != null) HomeOptions.artwork.value = artwork;
    },

    'dock.flow': (change) => DockOptions.flow.value = change.to == true,
    'dock.atRoot': (change) => DockOptions.atRoot.value = change.to == true,

    'menu.view': (change) {
      final view = MenuLayout.named(change.to);
      if (view != null) MenuOptions.view.value = view;
    },
    'menu.remember': (change) => MenuOptions.remember.value = change.to == true,
    'menu.wrap': (change) => MenuOptions.wrap.value = change.to == true,

    'menu.order': (change) {
      if (change.to case final List paths) {
        MenuDock.order.value = [for (final path in paths) '$path'];
      }
    },

    'dock.pins': (change) {
      final pins = change.to;
      if (pins is List) {
        MenuDock.pins.value = [for (final pin in pins) '$pin'];
      }
    },

    // -- Storage ---------------------------------------------------------
    'files.fullFilesystem': (change) =>
        FullFilesystem.enabled.value = change.to == true,

    // -- System ----------------------------------------------------------
    'debug.enabled': (change) =>
        DebugSettings.enabled.value = change.to == true,
    'debug.frameCounter': (change) =>
        DebugSettings.frameCounter.value = change.to == true,
  };

  /// The actions that do something, by bind key.
  ///
  /// [settings] is the store an action writes back through, for the ones
  /// that put settings themselves back rather than moving the machine. An
  /// action given no store does what it can to the notifiers directly,
  /// which is what a test that registered no store gets.
  static Map<String, SettingAction> actions(
    PlayerServices services, {
    Settings? settings,
  }) => {
    'library.scan': (_) => unawaited(services.library.scan()),

    // Back through the store rather than straight at the notifiers: the
    // stored value is the setting, and moving only the notifier would
    // leave the file holding the old color to put back on the next boot.
    // Back to the picture the player ships.
    'wallpaper.reset': (_) {
      final store = settings;
      unawaited(() async {
        final places = services.places.value;
        for (final ext in WallpaperSource.extensions) {
          final file = places.fileSystem.file(
            WallpaperSource.pathFor(places, ext),
          );
          try {
            if (file.existsSync()) file.deleteSync();
          } on FileSystemException catch (error) {
            debugPrint('wallpaper: ${file.path}: ${error.message}');
          }
        }
        await WallpaperSource.load(places);
        store?.set('/settings/appearance/wallpaper/image', null);
        store?.set('/settings/appearance/wallpaper/auto-palette', 0);
      }());
    },

    'appearance.resetColours': (_) {
      final store = settings;
      if (store == null) {
        Appearance.resetColors();
        return;
      }
      const bound = {
        'appearance.primary',
        'appearance.accent',
        'appearance.neutral',
      };
      for (final entry in store.tree.entries) {
        if (bound.contains(entry.node.bind)) {
          store.set(entry.path, entry.node.defaultValue);
        }
      }
    },
    // Every menu row back to what it shipped as: what is in the tree, how
    // it is drawn, and what the dock holds. Through the store, so the
    // file agrees with the screen - the notifiers follow from there.
    'menu.reset': (_) {
      final store = settings;
      if (store == null) return;
      for (final entry in store.tree.entries) {
        final bind = entry.node.bind;
        if (bind != null &&
            (bind.startsWith('menu.') || bind.startsWith('dock.')) &&
            entry.node.defaultValue != null) {
          store.set(entry.path, entry.node.defaultValue);
        }
      }
    },
    'power.restart': (_) =>
        unawaited(PowerDialog.perform(PowerCommand.restart)),
    'power.shutdown': (_) =>
        unawaited(PowerDialog.perform(PowerCommand.shutDown)),
  };

  /// A duration from what a setting stores: milliseconds, or null for
  /// `never`.
  static Duration? _duration(Object? value) =>
      value is num ? Duration(milliseconds: value.round()) : null;
}
