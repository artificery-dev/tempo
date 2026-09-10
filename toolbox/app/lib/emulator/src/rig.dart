import 'dart:async';
import 'dart:io' show Platform;

import 'package:tempo_core/tempo_core.dart';
import 'package:file/file.dart';
import 'package:file/local.dart';
import 'package:file/memory.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tempo_data/tempo_data.dart';

import 'data_storage.dart';

import 'paths.dart';

import 'emulator_fm_radio.dart';

/// Where the emulated card's contents come from.
enum CardSource {
  /// A card the emulator makes up: it exists and it has a name, and
  /// nothing written to it outlives the session.
  inMemory,

  /// A directory on this machine, handed to the player as its card.
  hostFolder,
}

/// The states the hardware would have to be put in, put in by hand.
///
/// Everything the player reads about its machine comes from
/// [PlayerServices]; on the device those are the kernel's answers, and here
/// they are these. That is what the rig is for: a battery at 3%, a card
/// pulled out mid-track, a radio that is on but has nothing to join - all
/// states the UI has to be right about, and none of them easy to arrange on
/// real hardware.
class Rig extends ChangeNotifier {
  final battery = ValueNotifier(const BatteryReading(percent: 78));

  final RadioService radios;
  ValueNotifier<WifiReading> get wifi => radios.wifi;
  ValueNotifier<BluetoothReading> get bluetooth => radios.bluetooth;

  /// The slot, empty to begin with: putting a card in is the moment the
  /// player asks where its library should live, and the rig starts on the
  /// near side of that question so it can be watched happening.
  final storage = ValueNotifier(StorageReading.empty);

  /// The machine's filesystem: a made-up Linux tree with the real things
  /// mounted into it where the device has them.
  late final places = ValueNotifier(_machine());

  /// The backlight. A value and nothing more here: the player's own shade
  /// is what a sleep looks like on a desk, and the body draws the panel
  /// dark behind it.
  final screen = ScreenSwitch();

  /// The emulated mixer also controls the host FM audio stream.
  final volume = VolumeSwitch();

  /// The same receiver identity follows mock/live mode changes.
  late final EmulatorFmRadio fmRadio = EmulatorFmRadio(
    live: FmRadioSwitch(),
    watch: false,
    checkAttached: () async => false,
  );

  /// Where the sound goes: the rig plugs and unplugs the jack.
  final output = OutputSwitch();

  /// The ticks and clicks, counted rather than heard: the emulator has
  /// no motor and plays no sound.
  final feedback = FeedbackSwitch();

  Rig({
    RadioService? radios,
    FileSystem? homeFileSystem,
    String? homeRoot,
    this.libraryFactory,
  }) : radios = radios ?? MockOnlyRadios(),
       _homeFileSystem =
           homeFileSystem ??
           (_underTest ? MemoryFileSystem() : LocalFileSystem()),
       _homeRoot =
           homeRoot ?? (_underTest ? '/' : Paths.ensureHome().absolute.path) {
    this.radios.addListener(notifyListeners);
    fmRadio.configuration.addListener(notifyListeners);
    this.radios.mockReadings(
      wifi: const WifiReading(
        status: WifiStatus.connected,
        network: 'Neon Bramble',
        bars: 3,
      ),
      bluetooth: const BluetoothReading(
        status: BluetoothStatus.connected,
        device: 'Sundial Buds',
      ),
    );
    if (!_underTest) this.radios.start();
    _hostFolder = Paths.card.path;
    _publishCard();
  }

  /// The fake machine, rebuilt whenever what is mounted in it changes.
  ///
  /// A memory filesystem for the tree itself, so browsing it costs nothing
  /// and breaks nothing, with two real filesystems mounted into it at the
  /// paths the device uses: the player's own storage at [Places.home], and
  /// the card at `/mnt/sd`. Everything else - `/etc`, `/usr`, `/proc` - is
  /// furniture, there so that browsing the root looks like browsing a
  /// machine.
  final FileSystem _homeFileSystem;
  final String _homeRoot;
  final LibraryService Function(String? databasePath)? libraryFactory;
  TempoProfilePaths? _profilePaths;
  bool _storageInitialized = false;
  bool _disposed = false;
  bool get storageInitialized => _storageInitialized;
  bool profileSuspended = false;
  int profileGeneration = 0;
  Future<void> Function()? detachProfile;
  Future<void>? _initializing;
  late final dataStorage = EmulatorDataStorage(
    manager: _storageManager,
    restart: _restartProfile,
  );
  bool get _profileCardAvailable =>
      _cardInserted &&
      (_cardSource == CardSource.inMemory ||
          _testDefaultCard ||
          LocalFileSystem()
              .directory(_hostFolder.isEmpty ? Paths.card.path : _hostFolder)
              .existsSync());

  TempoStorageManager _storageManager() => TempoStorageManager(
    fs: places.value.fileSystem,
    devicePaths: TempoProfilePaths.device(
      places.value.fileSystem,
      home: _home,
      configHome: '$_home/.config',
    ),
    selectorPath: TempoStorageManager.defaultSelectorPath(
      places.value.fileSystem,
      _home,
    ),
    cardRoot: _profileCardAvailable ? '/mnt/sd' : null,
  );
  Future<void> initializeStorage() => _initializing ??= _initializeStorage();
  Future<void> _initializeStorage() async {
    try {
      final decision = await _storageManager().applyPendingAtStartup();
      if (_disposed) return;
      _profilePaths = decision.activePaths;
      places.value = _machine();
      dataStorage.publish(decision);
    } catch (error) {
      if (_disposed) return;
      dataStorage.failure(error, unavailable: true);
    }
    _storageInitialized = true;
    notifyListeners();
  }

  /// Restart the player without deleting its settings, library, or media.
  Future<void> restart() => _restartProfile();

  Future<void> _restartProfile() async {
    if (_disposed) return;
    profileSuspended = true;
    notifyListeners();
    await detachProfile?.call();
    if (_disposed) return;
    try {
      await _closeLibrary();
      _services = null;
      await _initializeStorage();
    } catch (error) {
      if (!_disposed) dataStorage.failure(error, unavailable: true);
      rethrow;
    } finally {
      profileGeneration++;
      profileSuspended = false;
      if (!_disposed) notifyListeners();
    }
  }

  Places _machine() {
    final tree = MemoryFileSystem();
    for (final folder in const [
      '/etc',
      '/usr/bin',
      '/usr/share',
      '/var/log',
      '/proc',
      '/tmp',
      '/mnt',
      '/opt/tempo',
      '/root',
      _home,
    ]) {
      tree.directory(folder).createSync(recursive: true);
    }
    tree.file('/etc/hostname').writeAsStringSync('tempo\n');

    return Places(
      fileSystem: MountedFileSystem(
        root: tree,
        mounts: {
          // The player's own storage, kept on the host so that what the
          // emulated player writes is still there tomorrow.
          _home: _homeFileSystem,
          if (_cardInserted) '/mnt/sd': _card(),
        },
        mountRoots: {
          _home: _homeRoot,
          if (_cardInserted &&
              _cardSource == CardSource.hostFolder &&
              !_testDefaultCard)
            '/mnt/sd': _hostFolder.isEmpty
                ? Paths.ensureCard().absolute.path
                : _hostFolder,
        },
      ),
      home: _home,
      data: '$_home/.local/share/tempo',
      config: _profilePaths?.config,
    );
  }

  /// Where the player's storage lives on the device: the home of the
  /// unprivileged user the frontend runs as (config.yaml's user.name).
  static const _home = '/home/tempo';

  FileSystem _card() => switch (_cardSource) {
    CardSource.inMemory => _memory,
    CardSource.hostFolder => _testDefaultCard ? _testCard : LocalFileSystem(),
  };

  /// The services to hand the player: the rig's own notifiers, which it
  /// writes to as the controls move.
  bool get _testDefaultCard => _underTest && _hostFolder == Paths.card.path;
  late final _testCard = _emptyCard();
  PlayerServices? _services;
  PlayerServices get services => _services ??= _createServices();
  Directory? _libraryBridge;
  File? _bridgeDestination;
  String? _databasePath() {
    final mounted = places.value.fileSystem as MountedFileSystem;
    final at = mounted.resolve(
      '${_profilePaths?.data ?? places.value.data}/library.db',
    );
    if (at.fs is LocalFileSystem) return at.path;
    // SQLite needs an actual host path. Import/export a session-local native
    // database instead of pretending a virtual /mnt/sd path is on the host.
    final temp = LocalFileSystem().systemTempDirectory.createTempSync(
      'tempo-emulator-db-',
    );
    _libraryBridge = temp;
    _bridgeDestination = mounted.file(
      '${_profilePaths?.data ?? places.value.data}/library.db',
    );
    final target = temp.childFile('library.db');
    if (_bridgeDestination!.existsSync()) {
      _copyDatabase(_bridgeDestination!, target);
    }
    return target.path;
  }

  void _copyDatabase(File source, File target) {
    final input = source.openSync();
    try {
      final output = target.openSync(mode: FileMode.write);
      try {
        while (true) {
          final bytes = input.readSync(65536);
          if (bytes.isEmpty) break;
          output.writeFromSync(bytes);
        }
        output.flushSync();
      } finally {
        output.closeSync();
      }
    } finally {
      input.closeSync();
    }
  }

  Future<void> closeProfile() => _closeLibrary();
  Future<void> _closeLibrary() async {
    final library = _services?.library;
    _services = null;
    if (library != null) await library.dispose();
    final bridge = _libraryBridge;
    if (bridge != null) {
      final db = bridge.childFile('library.db');
      if (db.existsSync()) {
        final destination = _bridgeDestination!;
        destination.parent.createSync(recursive: true);
        final staged = destination.fileSystem.file(
          '${destination.path}.export',
        );
        _copyDatabase(db, staged);
        staged.renameSync(destination.path);
      }
      bridge.deleteSync(recursive: true);
      _libraryBridge = null;
      _bridgeDestination = null;
    }
  }

  PlaybackService? _playback;
  PlayerServices _createServices() {
    return PlayerServices(
      dataStorage: dataStorage,
      battery: battery,
      radios: radios,
      wifi: wifi,
      bluetooth: bluetooth,
      storage: storage,
      places: places,
      screen: screen,
      volume: volume,
      output: output,
      feedback: feedback,
      fmRadio: fmRadio,
      // Remembered in the emulated player's home, which lives on the host.
      applets: AppletStore(places.value),
      // The library, in the same home; it scans the host folders behind
      // the emulated card and home, since the scanner and the player both
      // read the machine's own disk. Not under the test harness, whose
      // home is the machine the tests run on - the same rule the device
      // keeps.
      library: !dataStorage.value.available
          ? null
          : libraryFactory != null
          ? libraryFactory!(_databasePath())
          : _underTest
          ? null
          : MediaLibrary.open(
              databasePath: _databasePath(),
              roots: hostRoots,
              sectionRoots: (section) => [
                '${Paths.ensureHome().path}/${section.label}',
                if (_cardSource == CardSource.hostFolder)
                  '${_hostFolder.isEmpty ? Paths.ensureCard().path : _hostFolder}/${section.label}',
              ],
              locations: () => [
                Paths.ensureHome().path,
                if (_cardSource == CardSource.hostFolder)
                  _hostFolder.isEmpty ? Paths.ensureCard().path : _hostFolder,
              ],
              storage: storage,
              autoScan: const Duration(seconds: 3),
              recheck: const Duration(seconds: 5),
            ),
      // Sound, when the desk has a libmpv; the silent player otherwise.
      playback: _underTest ? null : (_playback ??= _hostPlayback()),
    );
  }

  PlaybackService _hostPlayback() {
    try {
      return SerializedPlayback(MediaKitPlayback());
    } catch (error) {
      debugPrint('Emulator audio unavailable: $error');
      return SerializedPlayback(SilentPlayback());
    }
  }

  static final bool _underTest = Platform.environment.containsKey(
    'FLUTTER_TEST',
  );

  /// The host folders the library looks in: the card's Music folder (or
  /// the card) while a host folder stands in for the card, and the home's
  /// Music folder. A card made up in memory has nothing on disk to scan.
  List<String> hostRoots() {
    final card = _cardInserted && _cardSource == CardSource.hostFolder
        ? (_hostFolder.isEmpty ? Paths.ensureCard().path : _hostFolder)
        : null;
    return PlayerServices.deviceRoots(
      home: Paths.ensureHome().path,
      card: card == null
          ? StorageReading.empty
          : StorageReading(present: true, label: 'SD card', path: card),
    );
  }

  // -- the card ------------------------------------------------------------

  bool _cardInserted = false;

  bool get cardInserted => _cardInserted;

  /// Putting a card in or taking it out: each is an event the player
  /// sees, the way the hardware would report it.
  set cardInserted(bool inserted) {
    if (inserted == _cardInserted) return;
    _cardInserted = inserted;
    _publishCard();
  }

  /// A made-up card to begin with: nothing on this machine's disk is
  /// touched until a host folder is chosen on purpose.
  CardSource _cardSource = CardSource.inMemory;

  CardSource get cardSource => _cardSource;

  /// A different card, not a changed one: while a card is in the slot,
  /// switching what stands behind it takes that card out and puts the
  /// other in, so the player sees an eject and an insert.
  set cardSource(CardSource source) {
    if (source == _cardSource) return;
    _swapCard(() => _cardSource = source);
  }

  late String _hostFolder;

  String get hostFolder => _hostFolder;

  set hostFolder(String folder) {
    if (folder == _hostFolder) return;
    if (_cardSource == CardSource.hostFolder) {
      _swapCard(() => _hostFolder = folder);
    } else {
      _hostFolder = folder;
      notifyListeners();
    }
  }

  void _swapCard(void Function() change) {
    if (!_cardInserted) {
      change();
      notifyListeners();
      return;
    }
    _cardInserted = false;
    _publishCard();
    change();
    _cardInserted = true;
    _publishCard();
  }

  /// The made-up card, kept between switches so that what is written to it
  /// survives being unplugged and plugged back in - a session's worth of
  /// card, which is what it claims to be.
  late final MemoryFileSystem _memory = _emptyCard();

  static MemoryFileSystem _emptyCard() {
    final card = MemoryFileSystem();
    // Not empty: a card with nothing on it tells you nothing about how the
    // player handles one that has something.
    for (final folder in const ['Music', 'Podcasts', 'Audiobooks']) {
      card.directory('/$folder').createSync(recursive: true);
    }
    return card;
  }

  Future<void> _cardRefresh = Future<void>.value();
  void _publishCard() {
    storage.value = !_cardInserted
        ? StorageReading.empty
        : switch (_cardSource) {
            CardSource.inMemory => const StorageReading(
              present: true,
              label: 'Emulated card',
            ),
            CardSource.hostFolder => StorageReading(
              present: true,
              label: _folderName ?? 'Host folder',
              path: _hostFolder.isEmpty ? null : _hostFolder,
            ),
          };
    // Mounting the card is a change to the machine, not just to a reading.
    places.value = _machine();
    if (_storageInitialized) _followCard();
    notifyListeners();
  }

  /// What a card arriving or leaving means for the profile. A profile on
  /// the card, or none at all, restarts the player. With the player's own
  /// profile active the card only changes what the player may ask - the
  /// decision the device makes at boot, so a card holding a library under
  /// a Yes policy is taken up, and any card under Ask is offered. That
  /// last case is decided here and now, from the slot as it is at this
  /// moment, so a swap reads as an eject and then an insert rather than
  /// as one merged state.
  void _followCard() {
    if (dataStorage.value.usingCard || !dataStorage.value.available) {
      _restartForCard();
      return;
    }
    final m = _storageManager();
    final policy = m.readSelector();
    final card = _profileCardAvailable;
    final cardProfile =
        card &&
        m.sdPaths != null &&
        m.fs.directory(m.sdPaths!.data).existsSync();
    if (policy == TempoStoragePolicy.yes && cardProfile) {
      _restartForCard();
      return;
    }
    dataStorage.publish(
      TempoStorageDecision(
        policy: policy,
        location: TempoStorageLocation.device,
        activePaths: _profilePaths ?? m.devicePaths,
        needsPrompt: policy != TempoStoragePolicy.no && card,
        sdAvailable: card,
      ),
    );
  }

  void _restartForCard() {
    _cardRefresh = _cardRefresh.then((_) async {
      if (_disposed) return;
      try {
        await dataStorage.beforeChange?.call();
        await _restartProfile();
      } catch (error) {
        if (!_disposed) dataStorage.failure(error, unavailable: true);
      }
    });
  }

  /// Wait for mock card insertion/removal owner changes in tests or shutdown.
  Future<void> get cardSettled => _cardRefresh;

  String? get _folderName {
    final parts = _hostFolder
        .split(RegExp(r'[/\\]'))
        .where((part) => part.isNotEmpty);
    return parts.isEmpty ? null : parts.last;
  }

  // -- the battery ---------------------------------------------------------

  void setCharge(int percent) {
    if (percent == battery.value.percent) return;
    battery.value = BatteryReading(
      percent: percent,
      charging: battery.value.charging,
    );
    notifyListeners();
  }

  void setCharging(bool charging) {
    if (charging == battery.value.charging) return;
    battery.value = BatteryReading(
      percent: battery.value.percent,
      charging: charging,
    );
    notifyListeners();
  }

  // -- the radio -----------------------------------------------------------

  void setWifi(WifiStatus status) {
    if (status == wifi.value.status) return;
    radios.mockReadings(
      wifi: switch (status) {
        WifiStatus.off => WifiReading.off,
        WifiStatus.disconnected => const WifiReading(
          status: WifiStatus.disconnected,
        ),
        WifiStatus.connected => WifiReading(
          status: WifiStatus.connected,
          network: wifi.value.network ?? 'Neon Bramble',
          bars: wifi.value.bars == 0 ? 3 : wifi.value.bars,
        ),
      },
    );
    notifyListeners();
  }

  // -- the other radio -----------------------------------------------------

  void setBluetooth(BluetoothStatus status) {
    if (status == bluetooth.value.status) return;
    radios.mockReadings(
      bluetooth: switch (status) {
        BluetoothStatus.off => BluetoothReading.off,
        BluetoothStatus.on => const BluetoothReading(
          status: BluetoothStatus.on,
        ),
        BluetoothStatus.connected => BluetoothReading(
          status: BluetoothStatus.connected,
          device: bluetooth.value.device ?? 'Sundial Buds',
        ),
      },
    );
    notifyListeners();
  }

  void setBars(int bars) {
    if (bars == wifi.value.bars) return;
    radios.mockReadings(
      wifi: WifiReading(
        status: wifi.value.status,
        network: wifi.value.network,
        bars: bars,
      ),
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    if (_services != null) {
      unawaited(_closeLibrary());
      final playback = _playback;
      if (playback is ChangeNotifier) (playback as ChangeNotifier).dispose();
    }
    dataStorage.dispose();
    volume.dispose();
    output.dispose();
    fmRadio.configuration.removeListener(notifyListeners);
    fmRadio.dispose();
    battery.dispose();
    radios.removeListener(notifyListeners);
    radios.dispose();
    storage.dispose();
    places.dispose();
    screen.dispose();
    super.dispose();
  }
}

/// The emulator never changes the host computer's radios.
class MockOnlyRadios extends RadioService {
  @override
  Future<void> setMode(RadioMode mode) => super.setMode(RadioMode.mocked);
}
