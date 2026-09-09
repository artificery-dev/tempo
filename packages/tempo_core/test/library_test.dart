import 'dart:io';

import 'package:cadence_media/cadence_media.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tempo_core/tempo_core.dart';

/// A tier that reads nothing: the title from the filename, the album
/// from the folder, so the library under test is Cadence's service and
/// scanner with a canned extractor rather than the real readers.
class _CannedTier implements MetadataExtractor {
  const _CannedTier();

  @override
  bool handles(MediaKind kind, String extension) => true;

  @override
  Future<ExtractionResult?> extract(String path, MediaKind kind) async =>
      ExtractionResult(
        metadata: kind == MediaKind.video
            ? VideoMetadata(title: p.basenameWithoutExtension(path))
            : AudioMetadata(
                title: p.basenameWithoutExtension(path),
                artist: 'The Canned',
                album: p.basename(p.dirname(path)),
              ),
      );
}

MediaExtractor _buildCanned() => const MediaExtractor([_CannedTier()]);

/// The service in process over a memory database, with the canned tier
/// on the calling isolate - the shape [MediaLibrary.over] takes. Hand in
/// a [db] to open a second library over the same one.
Future<MediaClient> _client([MediaDatabase? db]) async {
  db ??= MediaDatabase(NativeDatabase.memory());
  final coordinator = ScanCoordinator(
    db,
    scanner: LibraryScanner(
      db,
      buildExtractor: _buildCanned,
      extractInIsolates: false,
      policy: ScanPolicy.lean,
    ),
  );
  return MediaClient.direct(
    db,
    service: MediaService(db, coordinator: coordinator),
  );
}

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('tempo_library'));
  tearDown(() => root.deleteSync(recursive: true));

  String write(String relative) {
    final file = File(p.join(root.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(relative, flush: true);
    return file.path;
  }

  Future<void> until(bool Function() ready) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!ready()) {
      if (DateTime.now().isAfter(deadline)) fail('never came true');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  group('MediaLibrary', () {
    test('scans separate libraries and mixed audio/video podcasts', () async {
      for (final section in LibrarySection.values) {
        write(
          '${section.label}/sample.${section == LibrarySection.shows || section == LibrarySection.movies ? 'mp4' : 'mp3'}',
        );
      }
      write('Podcasts/video.mp4');
      final library = MediaLibrary.over(
        _client(),
        roots: () => [p.join(root.path, 'Music')],
        sectionRoots: (section) => [p.join(root.path, section.label)],
      );
      addTearDown(library.dispose);
      await library.scan();
      expect(library.status.value.error, isNull);
      for (final section in LibrarySection.values) {
        expect(
          library.shelf(section).value,
          hasLength(section == LibrarySection.podcasts ? 2 : 1),
          reason: section.label,
        );
      }
      final podcasts = library.shelf(LibrarySection.podcasts).value;
      expect(podcasts.where(library.isVideo).single.title, 'video');
      expect(library.tracks.value.single.path, contains('/Music/'));
    });

    test(
      'refresh retains video classification while publishing other shelves',
      () async {
        write('Music/song.mp3');
        write('Shows/episode.mp4');
        final library = MediaLibrary.over(
          _client(),
          roots: () => [p.join(root.path, 'Music')],
          sectionRoots: (section) => [p.join(root.path, section.label)],
        );
        addTearDown(library.dispose);
        await library.scan();
        final episode = library.shelf(LibrarySection.shows).value.single;
        expect(library.isVideo(episode), isTrue);
        final observed = <bool>[];
        library.tracks.addListener(
          () => observed.add(library.isVideo(episode)),
        );
        await library.scan();
        expect(observed, isNotEmpty);
        expect(observed, everyElement(isTrue));
      },
    );

    test(
      'replacing a configured folder stops scanning the old folder',
      () async {
        final old = write('old/a.mp3');
        write('new/b.mp3');
        final library = MediaLibrary.over(
          _client(),
          roots: () => [p.dirname(old)],
        );
        addTearDown(library.dispose);
        await library.scan();
        library.configureFolders({
          'music': [p.join(root.path, 'new')],
        });
        await library.scan();
        expect(library.status.value.error, isNull);
        expect(library.tracks.value.map((track) => track.title), ['b']);
        expect(File(old).existsSync(), isTrue);
      },
    );

    test(
      'opens, keeps one Music library, and claims the roots that exist',
      () async {
        write('card/Music/Adele/19/Hometown Glory.mp3');
        write('home/Music/Beck/Odelay/Devils Haircut.flac');
        final card = p.join(root.path, 'card', 'Music');
        final home = p.join(root.path, 'home', 'Music');
        final gone = p.join(root.path, 'nowhere');

        final library = MediaLibrary.over(
          _client(),
          roots: () => [card, home, gone],
        );
        addTearDown(library.dispose);
        expect(library.status.value.phase, LibraryPhase.opening);
        await until(() => library.status.value.ready);
        expect(library.tracks.value, isEmpty, reason: 'nothing scanned yet');

        await library.scan();

        expect(library.status.value.error, isNull);
        final titles = library.tracks.value.map((t) => t.title).toList();
        expect(titles, unorderedEquals(['Hometown Glory', 'Devils Haircut']));
        final status = library.status.value;
        expect(status.phase, LibraryPhase.idle);
        expect(status.scan?.state, ScanState.done);
        expect(status.scan?.added, 2);
        expect(status.error, isNull);

        // A second scan finds nothing new and claims nothing twice.
        await library.scan();
        expect(library.status.value.scan?.added, 0);
        expect(library.tracks.value, hasLength(2));
      },
    );

    test('the status moves through scanning and settles idle', () async {
      write('card/Music/a.mp3');
      final library = MediaLibrary.over(
        _client(),
        roots: () => [p.join(root.path, 'card', 'Music')],
      );
      addTearDown(library.dispose);
      final seen = <LibraryPhase>[];
      library.status.addListener(() => seen.add(library.status.value.phase));
      await until(() => library.status.value.ready);

      await library.scan();

      expect(seen, contains(LibraryPhase.scanning));
      expect(seen.last, LibraryPhase.idle);
    });

    test('one scan at a time: a second ask joins the first', () async {
      write('card/Music/a.mp3');
      final library = MediaLibrary.over(
        _client(),
        roots: () => [p.join(root.path, 'card', 'Music')],
      );
      addTearDown(library.dispose);
      await until(() => library.status.value.ready);

      final first = library.scan();
      final second = library.scan();
      expect(identical(first, second), isTrue);
      await first;
      expect(library.tracks.value, hasLength(1));
    });

    test('a card that arrives is scanned once it has settled; the first '
        'reading is a baseline, not an arrival', () async {
      write('card/Music/a.mp3');
      final storage = ValueNotifier(StorageReading.empty);
      final inSlot = StorageReading(
        present: true,
        label: 'SD card',
        path: p.join(root.path, 'card'),
      );
      final library = MediaLibrary.over(
        _client(),
        roots: () => [
          if (storage.value.present) p.join(root.path, 'card', 'Music'),
        ],
        storage: storage,
        cardSettle: const Duration(milliseconds: 50),
      );
      addTearDown(library.dispose);
      await until(() => library.status.value.ready);
      expect(library.tracks.value, isEmpty);

      // The storage service's first look finds the card that was in all
      // along: nothing to do.
      storage.value = inSlot;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(library.tracks.value, isEmpty);
      expect(library.status.value.scan, isNull);

      // Out, and back in: that is an arrival.
      storage.value = StorageReading.empty;
      storage.value = inSlot;
      await until(() => library.tracks.value.isNotEmpty);
      expect(library.tracks.value.single.title, 'a');
    });

    test('an empty library scans by itself after the wait; one with '
        'tracks looks the card over after its own, quietly', () async {
      write('card/Music/a.mp3');
      final db = MediaDatabase(NativeDatabase.memory());
      final first = MediaLibrary.over(
        _client(db),
        roots: () => [p.join(root.path, 'card', 'Music')],
        autoScan: const Duration(milliseconds: 50),
      );
      await until(() => first.tracks.value.isNotEmpty);
      // Let the library go without closing the database it shares.
      first.status.dispose();
      first.tracks.dispose();

      final second = MediaLibrary.over(
        _client(db),
        roots: () => [p.join(root.path, 'card', 'Music')],
        autoScan: const Duration(milliseconds: 50),
        recheck: const Duration(milliseconds: 150),
      );
      addTearDown(second.dispose);
      await until(() => second.status.value.ready);
      expect(second.tracks.value, hasLength(1), reason: 'the shelf is kept');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(second.status.value.scan, isNull, reason: 'not the first wait');
      await until(() => second.status.value.scan?.state == ScanState.done);
      final scan = second.status.value.scan!;
      expect(scan.changed, 0, reason: 'nothing new: nothing to announce');
      expect(scan.added, 0);
      expect(second.tracks.value, hasLength(1));
    });
  });

  group('PlayerServices.deviceRoots', () {
    test('the card\'s Music folder when it has one, the card otherwise', () {
      write('card/Music/a.mp3');
      write('bare/b.mp3');
      write('home/Music/c.mp3');
      final home = p.join(root.path, 'home');

      expect(
        PlayerServices.deviceRoots(
          home: home,
          card: StorageReading(
            present: true,
            label: 'SD card',
            path: p.join(root.path, 'card'),
          ),
        ),
        [p.join(root.path, 'card', 'Music'), p.join(home, 'Music')],
      );
      expect(
        PlayerServices.deviceRoots(
          home: home,
          card: StorageReading(
            present: true,
            label: 'SD card',
            path: p.join(root.path, 'bare'),
          ),
        ),
        [p.join(root.path, 'bare'), p.join(home, 'Music')],
      );
      expect(
        PlayerServices.deviceRoots(
          home: p.join(root.path, 'nowhere'),
          card: StorageReading.empty,
        ),
        isEmpty,
      );
    });
  });

  group('MusicShelf', () {
    const tracks = [
      TrackSummary(
        id: 1,
        fileId: 1,
        path: '/m/1',
        title: 'Zebra',
        artist: 'The Beatles',
        album: 'Abbey Road',
        trackNumber: 2,
        year: 1969,
      ),
      TrackSummary(
        id: 2,
        fileId: 2,
        path: '/m/2',
        title: 'apple',
        artist: 'The Beatles',
        album: 'Abbey Road',
        trackNumber: 1,
        year: 1969,
      ),
      TrackSummary(
        id: 3,
        fileId: 3,
        path: '/m/3',
        title: 'The Middle',
        artist: 'Adele',
        album: '19',
        trackNumber: 1,
        year: 2008,
      ),
      TrackSummary(
        id: 4,
        fileId: 4,
        path: '/m/4',
        title: 'Bonus',
        artist: 'A Guest',
        albumArtist: 'Adele',
        album: '19',
        discNumber: 2,
        trackNumber: 1,
        year: 2008,
      ),
      TrackSummary(
        id: 5,
        fileId: 5,
        path: '/m/5',
        title: 'Early',
        artist: 'Adele',
        album: 'Demos',
        trackNumber: 1,
        year: 2006,
      ),
      TrackSummary(id: 6, fileId: 6, path: '/m/6', title: 'Untagged'),
    ];

    test('songs sort by title, without case or a leading article', () {
      expect(MusicShelf.songs(tracks).map((t) => t.title), [
        'apple',
        'Bonus',
        'Early',
        'The Middle',
        'Untagged',
        'Zebra',
      ]);
    });

    test('albums group by album and album artist, tracks in playing order', () {
      final albums = MusicShelf.albums(tracks);
      expect(albums.map((a) => a.title), [
        '19',
        'Abbey Road',
        'Demos',
        MusicShelf.unknownAlbum,
      ]);
      final nineteen = albums.first;
      expect(nineteen.artist, 'Adele');
      expect(nineteen.tracks.map((t) => t.title), ['The Middle', 'Bonus']);
      expect(albums[1].tracks.map((t) => t.title), ['apple', 'Zebra']);
      expect(albums.last.artist, isNull);
    });

    test('artists file under the album artist, albums by year', () {
      final artists = MusicShelf.artists(tracks);
      expect(artists.map((a) => a.name), [
        'Adele',
        'The Beatles',
        MusicShelf.unknownArtist,
      ]);
      final adele = artists.first;
      expect(adele.albums.map((a) => a.title), ['Demos', '19']);
      expect(adele.tracks.map((t) => t.title), [
        'Early',
        'The Middle',
        'Bonus',
      ]);
    });
  });
}
