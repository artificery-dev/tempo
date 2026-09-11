import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:io' as io;
import 'package:file/local.dart';
import 'package:file/memory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tempo_data/tempo_data.dart';
import 'package:tempo_toolbox/emulator/src/rig.dart';
import 'package:tempo_toolbox/emulator/emulator.dart';
import 'package:tempo_toolbox/emulator/src/emulator_window.dart';
import 'package:tomeui/tomeui.dart';

class ClosingLibrary extends NoLibrary {
  ClosingLibrary(this.path, this.events);
  final String path;
  final List<String> events;
  @override
  Future<void> dispose() async {
    events.add('close');
    io.File(path).writeAsStringSync('checkpointed');
  }
}

void main() {
  test(
    'memory profiles survive remount and first switch flushes/closes before copy',
    () async {
      final events = <String>[];
      final rig = Rig(libraryFactory: (path) => ClosingLibrary(path!, events));
      rig.cardSource = CardSource.inMemory;
      rig.cardInserted = true;
      await rig.initializeStorage();
      final original = rig.services;
      final fs = rig.places.value.fileSystem;
      fs.directory('/home/tempo/.config/tempo').createSync(recursive: true);
      fs
          .file('/home/tempo/.config/tempo/settings.json')
          .writeAsStringSync('old');
      rig.dataStorage.beforeChange = () async {
        events.add('flush');
        fs
            .file('/home/tempo/.config/tempo/settings.json')
            .writeAsStringSync('flushed');
      };
      rig.detachProfile = () async {
        events.add('detach');
      };
      await rig.dataStorage.setPolicy(DataStoragePolicy.yes);
      expect(events, ['flush', 'detach', 'close']);
      expect(rig.places.value.home, '/home/tempo');
      expect(rig.places.value.sdCard, '/mnt/sd');
      expect(rig.dataStorage.value.usingCard, isTrue);
      expect(rig.places.value.config, '/home/tempo/.config/tempo');
      expect(
        fs.file('/mnt/sd/.cadence/library.db').readAsStringSync(),
        'checkpointed',
      );
      expect(
        fs.file('/home/tempo/.config/tempo/settings.json').readAsStringSync(),
        'flushed',
      );
      expect(identical(rig.services, original), false);
      await rig.closeProfile();
      // Pulling the card falls back to the device profile without making
      // settings unavailable; putting it back under Yes takes it up again.
      rig.cardInserted = false;
      await rig.cardSettled;
      expect(rig.dataStorage.value.available, true);
      expect(rig.dataStorage.value.usingCard, false);
      rig.cardInserted = true;
      await rig.cardSettled;
      expect(rig.dataStorage.value.available, true);
      expect(rig.dataStorage.value.usingCard, true);
      expect(
        rig.places.value.fileSystem
            .file('/mnt/sd/.cadence/library.db')
            .readAsStringSync(),
        'checkpointed',
      );
      await rig.closeProfile();
      rig.dispose();
    },
  );
  test('a card arriving with the device profile active asks, and a swap ejects '
      'then inserts', () async {
    final rig = Rig();
    await rig.initializeStorage();
    expect(rig.cardInserted, isFalse);
    expect(rig.cardSource, CardSource.inMemory);
    expect(rig.dataStorage.value.available, isTrue);
    expect(rig.dataStorage.value.cardPresent, isFalse);
    expect(rig.dataStorage.value.promptAvailable, isFalse);
    final generation = rig.profileGeneration;

    final seen = <DataStorageStatus>[];
    rig.dataStorage.addListener(() => seen.add(rig.dataStorage.value));
    rig.cardInserted = true;
    await rig.cardSettled;
    expect(rig.dataStorage.value.cardPresent, isTrue);
    expect(rig.dataStorage.value.promptAvailable, isTrue);
    expect(rig.dataStorage.value.usingCard, isFalse);
    expect(rig.dataStorage.value.available, isTrue);
    expect(rig.profileGeneration, generation, reason: 'no restart to ask');

    seen.clear();
    rig.cardSource = CardSource.hostFolder;
    await rig.cardSettled;
    expect(seen.map((s) => s.cardPresent), [false, true]);
    expect(rig.dataStorage.value.promptAvailable, isTrue);

    seen.clear();
    rig.cardInserted = false;
    await rig.cardSettled;
    expect(seen.map((s) => s.cardPresent), [false]);
    expect(rig.dataStorage.value.promptAvailable, isFalse);
    expect(rig.dataStorage.value.available, isTrue);
    await rig.closeProfile();
    rig.dispose();
  });
  test('pulling the card stops whatever was playing', () async {
    final rig = Rig();
    rig.cardInserted = true;
    await rig.initializeStorage();
    final playback = rig.services.playback;
    await playback.play(const [
      TrackSummary(id: 1, fileId: 1, path: '/mnt/sd/Music/a.flac', title: 'a'),
    ]);
    expect(playback.value.hasTrack, isTrue);
    rig.cardInserted = false;
    await rig.cardSettled;
    expect(playback.value.hasTrack, isFalse);
    await rig.closeProfile();
    rig.dispose();
  });
  test('a card-profile card coming or going swaps the library in place, '
      'without a restart', () async {
    final events = <String>[];
    final rig = Rig(libraryFactory: (path) => ClosingLibrary(path!, events));
    rig.cardSource = CardSource.inMemory;
    rig.cardInserted = true;
    await rig.initializeStorage();
    rig.services;
    await rig.dataStorage.setPolicy(DataStoragePolicy.yes);
    expect(rig.dataStorage.value.usingCard, isTrue);
    final generation = rig.profileGeneration;
    final services = rig.services;
    final shelf = services.library.tracks;
    events.clear();

    rig.cardInserted = false;
    await rig.cardSettled;
    expect(rig.profileGeneration, generation, reason: 'no restart');
    expect(identical(rig.services, services), isTrue);
    expect(identical(services.library.tracks, shelf), isTrue);
    expect(rig.dataStorage.value.usingCard, isFalse);
    expect(rig.dataStorage.value.available, isTrue);
    expect(events, ['close']);

    events.clear();
    rig.cardInserted = true;
    await rig.cardSettled;
    expect(rig.profileGeneration, generation);
    expect(identical(rig.services, services), isTrue);
    expect(rig.dataStorage.value.usingCard, isTrue);
    expect(events, ['close']);
    await rig.closeProfile();
    rig.dispose();
  });
  test('adopting existing memory card never overwrites its profile', () async {
    final rig = Rig();
    rig.cardSource = CardSource.inMemory;
    rig.cardInserted = true;
    final fs = rig.places.value.fileSystem;
    fs.directory('/mnt/sd/.cadence').createSync(recursive: true);
    fs.file('/mnt/sd/.cadence/library.db').writeAsStringSync('existing');
    await rig.initializeStorage();
    expect(rig.dataStorage.value.promptAvailable, true);
    expect(rig.dataStorage.value.cardProfileExists, true);
    rig.dataStorage.skipStartup();
    expect(rig.dataStorage.value.policy, DataStoragePolicy.ask);
    await rig.dataStorage.adoptCardForStartup();
    expect(rig.dataStorage.value.usingCard, isTrue);
    expect(
      fs.file('/mnt/sd/.cadence/library.db').readAsStringSync(),
      'existing',
    );
    await rig.closeProfile();
    rig.dispose();
  });
  test('existing destination requires reviewed collision choice', () async {
    final rig = Rig();
    rig.cardSource = CardSource.inMemory;
    rig.cardInserted = true;
    await rig.initializeStorage();
    final fs = rig.places.value.fileSystem;
    fs.directory('/mnt/sd/.cadence').createSync(recursive: true);
    fs.file('/mnt/sd/.cadence/library.db').writeAsStringSync('existing');
    await expectLater(
      rig.dataStorage.setPolicy(DataStoragePolicy.yes),
      throwsA(isA<TempoProfileConflict>()),
    );
    expect(rig.dataStorage.value.busy, false);
    expect(rig.dataStorage.value.available, true);
    expect(rig.dataStorage.value.usingCard, isFalse);
    expect(
      fs.file('/mnt/sd/.cadence/library.db').readAsStringSync(),
      'existing',
    );
    await rig.closeProfile();
    rig.dispose();
  });
  test(
    'host folder profile resolves actual native DB path on reopen',
    () async {
      final temp = io.Directory.systemTemp.createTempSync(
        'tempo-profile-test-',
      );
      final home = io.Directory('${temp.path}/home')..createSync();
      final card = io.Directory('${temp.path}/card')..createSync();
      final opened = <String>[];
      final rig = Rig(
        homeFileSystem: const LocalFileSystem(),
        homeRoot: home.path,
        libraryFactory: (path) {
          opened.add(path!);
          return NoLibrary();
        },
      );
      rig.cardSource = CardSource.hostFolder;
      rig.hostFolder = card.path;
      rig.cardInserted = true;
      await rig.initializeStorage();
      rig.services;
      expect(opened.single, '${home.path}/.cadence/library.db');
      await rig.dataStorage.setPolicy(DataStoragePolicy.yes);
      rig.services;
      expect(opened.last, '${card.path}/.cadence/library.db');
      expect(rig.places.value.home, '/home/tempo');
      await rig.closeProfile();
      rig.dispose();
      final next = Rig(
        homeFileSystem: const LocalFileSystem(),
        homeRoot: home.path,
      );
      next.cardSource = CardSource.hostFolder;
      next.hostFolder = card.path;
      next.cardInserted = true;
      await next.initializeStorage();
      expect(next.dataStorage.value.usingCard, true);
      expect(next.places.value.config, '/home/tempo/.config/tempo');
      await next.closeProfile();
      next.dispose();
      temp.deleteSync(recursive: true);
    },
  );
  test(
    'mounted atomic rename translates host destination and rejects cross mount',
    () {
      final a = MemoryFileSystem(), b = MemoryFileSystem();
      a.directory('/home').createSync();
      b.directory('/card').createSync();
      final mounted = MountedFileSystem(
        root: MemoryFileSystem(),
        mounts: {'/home/tempo': a, '/mnt/sd': b},
        mountRoots: {'/home/tempo': '/home', '/mnt/sd': '/card'},
      );
      mounted.file('/home/tempo/selector.new').writeAsStringSync('yes');
      mounted
          .file('/home/tempo/selector.new')
          .renameSync('/home/tempo/selector');
      expect(a.file('/home/selector').readAsStringSync(), 'yes');
      mounted.directory('/mnt/sd/.cadence.stage').createSync();
      mounted
          .directory('/mnt/sd/.cadence.stage')
          .renameSync('/mnt/sd/.cadence');
      expect(b.directory('/card/.cadence').existsSync(), true);
      expect(
        () =>
            mounted.file('/home/tempo/selector').renameSync('/mnt/sd/selector'),
        throwsA(isA<io.FileSystemException>()),
      );
    },
  );
  test(
    'virtual profile bridges a real SQLite library across owner restarts',
    () async {
      final rig = Rig(
        libraryFactory: (path) =>
            MediaLibrary.open(databasePath: path, roots: () => []),
      );
      rig.cardSource = CardSource.inMemory;
      rig.cardInserted = true;
      await rig.initializeStorage();
      await rig.services.library.scan();
      await rig.dataStorage.setPolicy(DataStoragePolicy.yes);
      final file = rig.places.value.fileSystem.file(
        '/mnt/sd/.cadence/library.db',
      );
      expect(
        String.fromCharCodes(file.readAsBytesSync().take(15)),
        'SQLite format 3',
      );
      await rig.services.library.scan();
      await rig.dataStorage.setPolicy(
        DataStoragePolicy.no,
        replaceExisting: true,
      );
      expect(rig.dataStorage.value.usingCard, isFalse);
      await rig.services.library.scan();
      await rig.closeProfile();
      expect(
        String.fromCharCodes(
          rig.places.value.fileSystem
              .file('/home/tempo/.cadence/library.db')
              .readAsBytesSync()
              .take(15),
        ),
        'SQLite format 3',
      );
      rig.dispose();
    },
  );
  testWidgets(
    'mounted TempoApp is replaced after settings flush and profile migration',
    (tester) async {
      final rig = Rig();
      rig.cardSource = CardSource.inMemory;
      rig.cardInserted = true;
      await rig.initializeStorage();
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        TomeApp(
          home: ProviderScope(
            child: EmulatorShell(window: EmulatorWindow(), rig: rig),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final old = rig.services;
      final switching = rig.dataStorage.setPolicy(DataStoragePolicy.yes);
      await tester.pumpAndSettle();
      await switching;
      await tester.pumpAndSettle();
      expect(rig.profileGeneration, 1);
      expect(identical(old, rig.services), false);
      expect(
        tester.widget<TempoApp>(find.byType(TempoApp)).services,
        same(rig.services),
      );
      expect(rig.places.value.config, '/home/tempo/.config/tempo');
      expect(rig.dataStorage.value.busy, false);
      await tester.pumpWidget(const SizedBox.shrink());
      await rig.closeProfile();
      rig.dispose();
      MenuDock.reset();
      MenuDock.selected.value = null;
    },
  );
  test(
    'device Ask/No preferences and same-policy choices retain owners',
    () async {
      final rig = Rig();
      rig.cardSource = CardSource.inMemory;
      rig.cardInserted = true;
      await rig.initializeStorage();
      final services = rig.services;
      var flushes = 0;
      rig.dataStorage.beforeChange = () async {
        flushes++;
      };
      await rig.dataStorage.setPolicy(DataStoragePolicy.no); // Don't Ask Again.
      expect(rig.dataStorage.value.policy, DataStoragePolicy.no);
      expect(rig.services, same(services));
      expect(rig.profileGeneration, 0);
      expect(rig.profileSuspended, false);
      await rig.dataStorage.setPolicy(DataStoragePolicy.ask);
      await rig.dataStorage.setPolicy(DataStoragePolicy.ask);
      expect(rig.dataStorage.value.policy, DataStoragePolicy.ask);
      expect(rig.services, same(services));
      expect(flushes, 0, reason: 'No profile file owner needs pausing');
      expect(rig.profileGeneration, 0);
      await rig.closeProfile();
      rig.dispose();
    },
  );
}
