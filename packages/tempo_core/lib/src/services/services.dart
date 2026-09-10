import 'dart:io' show Directory, Platform;

import 'package:flutter/foundation.dart' show ValueListenable, debugPrint;
import 'package:tomeui/tomeui.dart';

import '../applet.dart';
import '../storage/places.dart';
import 'device_services.dart';
import 'fm_radio.dart';
import 'library.dart';
import 'cadence_playback.dart';
import 'playback.dart';
import 'serialized_playback.dart';
import 'readings.dart';
import 'radios.dart';
import 'screen.dart';
import 'feedback.dart';
import 'output.dart';
import 'volume.dart';
import 'time_zone.dart';
import 'data_storage.dart';
export 'data_storage.dart';
import 'card_maintenance.dart';
export 'card_maintenance.dart';

export 'device_services.dart';
export 'fm_radio.dart';
export 'library.dart';
export 'cadence_library.dart';
export 'cadence_media_library.dart';
export 'playback.dart';
export 'serialized_playback.dart';
export 'readings.dart';
export 'radios.dart';
export 'screen.dart';
export 'tempod.dart';
export 'feedback.dart';
export 'output.dart';
export 'volume.dart';
export 'time_zone.dart';

/// What the player knows about the machine it is running on.
///
/// The UI reads these and nothing else - no sysfs paths in a widget, no
/// `Platform.isLinux` in a screen. On the device they are fed by the kernel
/// (see [PlayerServices.device]); in the emulator they are fed by hand from
/// the rig, which is the whole point: a battery at 3% and a card that isn't
/// there are states the UI has to be right about, and neither is easy to
/// arrange on real hardware.
@immutable
class PlayerServices {
  const PlayerServices({
    required this.battery,
    required this.wifi,
    required this.bluetooth,
    required this.storage,
    required this.places,
    required this.screen,
    required this.volume,
    required this.output,
    required this.feedback,
    this.readSettings,
    this.writeSettings,
    this.dataStorage,
    this.cardMaintenance,
    this.resolveLibraryPath,
    this.fmRadio,
    this.timeZone,
    this.radios,
    this.applets = const AppletStore.ephemeral(),
    this._library,
    this._playback,
  });

  final Future<Map<String, Object?>> Function()? readSettings;
  final Future<void> Function(Map<String, Object?>)? writeSettings;
  final DataStorageController? dataStorage;
  final CardMaintenanceController? cardMaintenance;
  final Future<String> Function(TrackSummary)? resolveLibraryPath;

  /// The services as the machine reports them.
  ///
  /// Under the test harness the library and the player are left out: the
  /// harness's "home" is the machine the tests run on, and nobody's to
  /// open a database in or play sound from.
  factory PlayerServices.device({
    Places? initialPlaces,
    LibraryService? library,
    Future<String> Function(TrackSummary)? resolveLibraryPath,
    Future<Map<String, Object?>> Function(Map<String, Object?>)? mediaTransport,
    Future<void> Function()? closeMediaTransport,
    Future<Map<String, Object?>> Function()? readSettings,
    Future<void> Function(Map<String, Object?>)? writeSettings,
    DataStorageController? dataStorage,
    CardMaintenanceController? cardMaintenance,
    ValueListenable<BatteryReading>? battery,
    ValueListenable<StorageReading>? storage,
  }) {
    final places = DevicePlaces(initialPlaces);
    final deviceStorage = storage ?? DeviceStorage();
    final underTest = Platform.environment.containsKey('FLUTTER_TEST');
    final home = places.value.home;
    final volume = DeviceVolume();
    final radios = underTest
        ? null
        : (RadioService(mode: RadioMode.host)..start());
    return PlayerServices(
      readSettings: readSettings,
      writeSettings: writeSettings,
      dataStorage: dataStorage,
      cardMaintenance: cardMaintenance,
      resolveLibraryPath: resolveLibraryPath,
      battery: battery ?? DeviceBattery(),
      wifi: radios?.wifi ?? DeviceWifi(),
      bluetooth: radios?.bluetooth ?? DeviceBluetooth(),
      radios: radios,
      storage: deviceStorage,
      places: places,
      screen: DeviceScreen(),
      volume: volume,
      output: DeviceOutput(),
      feedback: DeviceFeedback(),
      fmRadio: underTest ? null : DeviceFmRadio(),
      timeZone: underTest ? null : DeviceTimeZone(),
      applets: AppletStore(places.value),
      library:
          library ??
          (underTest
              ? null
              : MediaLibrary.open(
                  // Beside the applets' state, in the player's own storage.
                  databasePath: '${places.value.data}/library.db',
                  transport: mediaTransport,
                  daemonScheduled: mediaTransport != null,
                  closeTransport: closeMediaTransport,
                  roots: () =>
                      deviceRoots(home: home, card: deviceStorage.value),
                  sectionRoots: (section) => collectionRoots(
                    home: home,
                    card: deviceStorage.value,
                    section: section,
                  ),
                  locations: () => [home, ?deviceStorage.value.path],
                  storage: deviceStorage,
                  autoScan: firstScanAfter,
                  recheck: recheckAfter,
                )),
      playback: underTest
          ? null
          : resolveLibraryPath == null
          ? devicePlayback(volume: volume)
          : CadencePlayback(
              devicePlayback(volume: volume),
              resolvePath: resolveLibraryPath,
            ),
    );
  }

  /// How long after coming up an empty library looks at the card: long
  /// enough for the first frame and the hand-off to be behind us.
  static const firstScanAfter = Duration(seconds: 8);

  /// How long after coming up a library with music in it looks the card
  /// over for changes - quietly, at low priority, and later still, so the
  /// player is entirely itself first.
  static const recheckAfter = Duration(seconds: 25);

  /// The folders the device's library claims: the card's Music folder -
  /// or the whole card, when it keeps no such folder - and the player's
  /// own. Only what exists; the card comes and goes.
  static List<String> deviceRoots({
    required String home,
    required StorageReading card,
  }) {
    final cardPath = card.present ? card.path : null;
    return [
      if (cardPath != null)
        Directory('$cardPath/Music').existsSync()
            ? '$cardPath/Music'
            : cardPath,
      if (Directory('$home/Music').existsSync()) '$home/Music',
    ];
  }

  static List<String> collectionRoots({
    required String home,
    required StorageReading card,
    required LibrarySection section,
  }) => [
    '$home/${section.label}',
    if (card.path case final path?) '$path/${section.label}',
  ];

  /// The player over libmpv when the machine has one; a silent one, and
  /// a word in the log, when it has not.
  static PlaybackService devicePlayback({DeviceVolume? volume}) {
    try {
      return SerializedPlayback(MediaKitPlayback());
    } on Object catch (error) {
      debugPrint('playback: no libmpv, playing silently ($error)');
      return SerializedPlayback(SilentPlayback());
    }
  }

  final RadioService? radios;

  /// Absent in the emulator: previewing a zone must not change the host.
  final DeviceTimeZone? timeZone;

  final ValueListenable<BatteryReading> battery;
  final ValueListenable<WifiReading> wifi;
  final ValueListenable<BluetoothReading> bluetooth;
  final ValueListenable<StorageReading> storage;

  /// The machine's filesystem and the places worth starting from in it.
  final ValueListenable<Places> places;

  /// The panel's backlight: awake, or asleep behind the shade.
  final ScreenService screen;

  /// The mixer: the level the player is heard at.
  final VolumeService volume;

  /// Where the sound goes: the speaker, the jack, a Bluetooth device.
  final OutputService output;

  /// The tick, the click and the thump that answer the wheel.
  final FeedbackService feedback;

  /// The broadcast FM receiver and its decoded station data, when present.
  final FmRadioService? fmRadio;

  FmRadioService get tuner => fmRadio ?? UnavailableFmRadio.shared;

  /// Where the applets keep what they remember. Ephemeral unless the
  /// machine names a home to keep it in - so a test that mounts the app
  /// bare never writes into anyone's real one.
  final AppletStore applets;

  final LibraryService? _library;
  final PlaybackService? _playback;

  /// The library: the tracks the player knows. Empty, and looking nowhere,
  /// unless the machine opened one.
  LibraryService get library => _library ?? NoLibrary.shared;

  /// The player: what is playing, and the words the wheel says to it.
  /// Silent unless the machine has a sound to make.
  PlaybackService get playback => _playback ?? SilentPlayback.shared;

  /// What a widget gets when nobody has installed anything: the machine
  /// itself, read once and shared, so a screen built in isolation still
  /// shows something true.
  static final PlayerServices fallback = PlayerServices.device();
}

/// Installs [services] for everything below it.
class PlayerServicesScope extends InheritedWidget {
  const PlayerServicesScope({
    required this.services,
    required super.child,
    super.key,
  });

  final PlayerServices services;

  static PlayerServices of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<PlayerServicesScope>()
          ?.services ??
      PlayerServices.fallback;

  @override
  bool updateShouldNotify(PlayerServicesScope oldWidget) =>
      oldWidget.services != services;
}
