import 'dart:async';
import 'dart:io';

import 'package:cadence_media/cadence_media.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'readings.dart';

export 'package:cadence_media/cadence_media.dart'
    show
        ArtworkPolicy,
        IdentityHash,
        ScanPolicy,
        ScanState,
        ScanStatus,
        TrackSummary;

/// The libraries on the player's shelf. Podcasts accept audio and video.
enum LibrarySection {
  music('Music', 'music', LibraryType.music),
  podcasts('Podcasts', 'podcast', LibraryType.podcasts),
  recordings('Recordings', 'mic', LibraryType.music),
  audiobooks('Audiobooks', 'book-audio', LibraryType.books),
  shows('Shows', 'tv', LibraryType.shows),
  movies('Movies', 'film', LibraryType.videos);

  const LibrarySection(this.label, this.icon, this.type);
  final String label;
  final String icon;
  final LibraryType type;
}

/// Where the library is in its life.
enum LibraryPhase {
  /// The service is coming up: the database opening, the shelf loading.
  opening,

  /// Ready, and holding still.
  idle,

  /// A scan is in motion; [LibraryStatus.scan] has the counters.
  scanning,
}

/// One reading of the library: its phase, the latest scan, and whatever
/// went wrong last.
@immutable
class LibraryStatus {
  const LibraryStatus({required this.phase, this.scan, this.error});

  static const opening = LibraryStatus(phase: LibraryPhase.opening);
  static const idle = LibraryStatus(phase: LibraryPhase.idle);

  final LibraryPhase phase;

  /// The scan in motion, or the last one that ran. Null before any has.
  final ScanStatus? scan;

  /// What the last attempt to open or scan said when it failed.
  final String? error;

  bool get scanning => phase == LibraryPhase.scanning;
  bool get ready => phase != LibraryPhase.opening;

  @override
  bool operator ==(Object other) =>
      other is LibraryStatus &&
      other.phase == phase &&
      other.scan == scan &&
      other.error == error;

  @override
  int get hashCode => Object.hash(phase, scan, error);
}

/// The player's library: the tracks it knows, and the way to find more.
///
/// Behind it is Cadence's media service - the same database, scanner and
/// protocol the desktop player runs - hosted here in the app; see
/// [MediaLibrary]. The UI reads this and nothing else: a shelf is a list
/// of [TrackSummary]s, an update is [scan], and where the files are is
/// the host's business.
abstract class LibraryService {
  ValueListenable<LibraryStatus> get status;

  /// Every playable track, in the order the library met them. Sorting and
  /// grouping are the shelves' job; see [MusicShelf].
  ValueListenable<List<TrackSummary>> get tracks;

  /// Update the library: claim the folders that are there to claim, scan
  /// them, and reload the shelf. Returns when the scan has finished, or
  /// at once when one is already running.
  Future<void> scan();

  /// A picture for the file, or null when it has none. Under the
  /// player's policy the scan makes no pictures; asking for one puts it
  /// at the front of the artwork queue and waits for the render.
  Future<Uint8List?> artwork(int fileId);

  /// The files about to be drawn, in the order they will be: their
  /// pictures go to the front of the queue without anyone waiting.
  Future<void> prefetch(List<int> fileIds);

  Future<void> dispose();
}

/// A library with nothing in it and nowhere to look: what a widget gets
/// when nobody installed one, and what a test that never asks for music
/// mounts.
class NoLibrary implements LibraryService {
  NoLibrary();

  static final shared = NoLibrary();

  @override
  final ValueNotifier<LibraryStatus> status = ValueNotifier(LibraryStatus.idle);

  @override
  final ValueNotifier<List<TrackSummary>> tracks = ValueNotifier(const []);

  @override
  Future<void> scan() async {}

  @override
  Future<Uint8List?> artwork(int fileId) async => null;

  @override
  Future<void> prefetch(List<int> fileIds) async {}

  @override
  Future<void> dispose() async {}
}

/// The folders worth scanning right now, as the machine's own filesystem
/// has them. Evaluated at every scan, since the card comes and goes.
typedef LibraryRoots = List<String> Function();

/// The library over Cadence's media service.
///
/// The service runs in its own isolate ([MediaServer.spawn]) and owns the
/// database; this end speaks to it through a [MediaClient] and keeps the
/// shelf - the track list - in memory for the screens. One "Music"
/// library is made on first run and every scan claims whatever [roots]
/// answers that exists: the card's Music folder, the player's own.
///
/// Scans run under [playerPolicy] by default - sampled hashes over a
/// quarter megabyte of each end, and the pictures deferred - which is
/// what a card of a hundred gigabytes on a Cortex-A7 can afford: with the
/// covers decoded during the scan it indexed a file every two seconds;
/// without, twelve a second. The pictures are made afterwards by the
/// service's artwork queue, at low priority, the rows on screen first.
class MediaLibrary implements LibraryService {
  /// The player's scan budget.
  static const playerPolicy = ScanPolicy(
    identity: IdentityHash.sampled,
    artwork: ArtworkPolicy.deferred,
    hashSpan: 256 * 1024,
  );

  /// Opens the database at [databasePath] (null: in memory) and comes
  /// up. [roots] says where to look; [storage] - the card - is watched,
  /// and a card that arrives is scanned after a moment. [autoScan] is how
  /// long after opening an *empty* library's first scan starts; a library
  /// with tracks in it is looked over after [recheck] instead - a walk
  /// of the card against the database, at low priority, which says
  /// nothing unless it finds music new or changed. Null for either never
  /// starts that one unasked.
  MediaLibrary.open({
    required String? databasePath,
    ServiceTransport? transport,
    bool daemonScheduled = false,
    Future<void> Function()? closeTransport,
    required LibraryRoots roots,
    ValueListenable<StorageReading>? storage,
    Duration? autoScan,
    Duration? recheck,
    Duration cardSettle = defaultCardSettle,
    ScanPolicy policy = playerPolicy,
    List<String> Function(LibrarySection)? sectionRoots,
    LibraryRoots? locations,
  }) : this.over(
         transport == null
             ? _spawn(databasePath, policy)
             : Future.value(MediaClient(transport, onClose: closeTransport)),
         roots: roots,
         daemonScheduled: daemonScheduled,
         sectionRoots: sectionRoots,
         locations: locations,
         storage: storage,
         autoScan: autoScan,
         recheck: recheck,
         cardSettle: cardSettle,
       );

  /// The same library over a client somebody else made - the service in
  /// process, for tests.
  MediaLibrary.over(
    Future<MediaClient> client, {
    required this._roots,
    this.daemonScheduled = false,
    this.sectionRoots,
    this.locations,
    this._storage,
    Duration? autoScan,
    Duration? recheck,
    this.cardSettle = defaultCardSettle,
  }) : _firstScanAfter = autoScan,
       _recheckAfter = recheck {
    _ready = _open(client);
    if (!daemonScheduled) _storage?.addListener(_storageMoved);
  }

  static Future<MediaClient> _spawn(String? path, ScanPolicy policy) {
    if (path != null) Directory(p.dirname(path)).createSync(recursive: true);
    // Last in line for the CPU, the service and every worker it spawns:
    // the wheel on a small machine must not wait on a card being read.
    return MediaServer.spawn(
      databasePath: path,
      policy: policy,
      lowPriority: true,
    );
  }

  /// The name of the one library the player keeps.
  static const libraryName = 'Music';

  /// How often a running scan is asked how it is doing.
  static const pollPeriod = Duration(milliseconds: 500);

  /// How long after a card arrives its scan starts: long enough for the
  /// mount to settle and the browser to show it first.
  static const defaultCardSettle = Duration(seconds: 3);

  /// This library's own wait, see [defaultCardSettle].
  final Duration cardSettle;

  final bool daemonScheduled;
  Timer? _observer;
  Future<void>? _observing;
  String? _remoteVersion;
  final LibraryRoots _roots;
  final List<String> Function(LibrarySection)? sectionRoots;
  final LibraryRoots? locations;
  final _ids = <LibrarySection, int>{};
  final _shelves = <LibrarySection, ValueNotifier<List<TrackSummary>>>{};
  final _videoFiles = <int>{};
  Map<String, List<String>> _configured = {};
  final _defaultRoots = <LibrarySection, Set<String>>{};

  ValueListenable<List<TrackSummary>> shelf(LibrarySection section) =>
      section == LibrarySection.music
      ? tracks
      : _shelves.putIfAbsent(section, () => ValueNotifier(const []));

  bool isVideo(TrackSummary track) => _videoFiles.contains(track.fileId);

  List<String> rootsFor(LibrarySection section) {
    final configured = _configured[section.name];
    if (configured != null) return configured;
    final remembered = _defaultRoots.putIfAbsent(section, () => <String>{});
    remembered.addAll(
      sectionRoots?.call(section) ??
          (section == LibrarySection.music ? _roots() : const []),
    );
    return remembered.toList();
  }

  /// Missing cards keep their roots; an explicit settings change releases
  /// a removed root on the next scan without deleting its files.
  void configureFolders(Object? value) {
    _configured = {
      if (value is Map)
        for (final entry in value.entries)
          if (entry.key is String && entry.value is List)
            entry.key as String: [
              for (final path in entry.value as List)
                if (path is String && p.isAbsolute(path)) p.normalize(path),
            ],
    };
  }

  final ValueListenable<StorageReading>? _storage;
  final Duration? _firstScanAfter;
  final Duration? _recheckAfter;
  bool scanOnStartup = true;
  bool scanOnCard = true;
  String recheck = 'startup';
  late final Future<MediaClient?> _ready;
  MediaClient? _client;
  int? _libraryId;
  Timer? _autoScan;
  Timer? _cardScan;

  /// Whether the card was in, as of the last reading - and null until
  /// there has been one: the storage service starts at "empty" before it
  /// has looked, and a card that was in all along must not read as one
  /// that just arrived.
  bool? _cardPresent;
  bool _disposed = false;
  Future<void>? _scanning;

  /// A few pictures, kept: the rows on screen ask for the same ones over
  /// and over as the wheel moves.
  final _art = <int, Uint8List?>{};
  static const _artKept = 48;

  @override
  final ValueNotifier<LibraryStatus> status = ValueNotifier(
    LibraryStatus.opening,
  );

  @override
  final ValueNotifier<List<TrackSummary>> tracks = ValueNotifier(const []);

  /// The id of the Music library, once the service is up.
  Future<int?> get libraryId => _ready.then((_) => _libraryId);

  Future<MediaClient?> _open(Future<MediaClient> pending) async {
    try {
      final client = await pending;
      if (_disposed) {
        await client.close();
        return null;
      }
      _client = client;
      final libraries = await client.listLibraries();
      for (final section in LibrarySection.values) {
        if (sectionRoots == null && section != LibrarySection.music) continue;
        _ids[section] =
            libraries
                .where(
                  (row) =>
                      row.name == section.label && row.type == section.type,
                )
                .firstOrNull
                ?.id ??
            await client.createLibrary(section.label, section.type);
      }
      _libraryId = _ids[LibrarySection.music];
      await _refresh();
      _publish(const LibraryStatus(phase: LibraryPhase.idle));
      if (daemonScheduled) {
        await _observeRemote();
        _observer = Timer.periodic(
          const Duration(seconds: 2),
          (_) => unawaited(_observeRemote()),
        );
        return client;
      }
      final after = tracks.value.isEmpty ? _firstScanAfter : _recheckAfter;
      if (after != null && !_disposed) {
        _autoScan = Timer(after, () {
          final empty =
              tracks.value.isEmpty &&
              _shelves.values.every((shelf) => shelf.value.isEmpty);
          if (empty ? scanOnStartup : recheck == 'startup') unawaited(scan());
        });
      }
      return client;
    } on Object catch (error) {
      _publish(LibraryStatus(phase: LibraryPhase.idle, error: '$error'));
      return null;
    }
  }

  Future<void> _observeRemote() =>
      _observing ??= _readRemote().whenComplete(() => _observing = null);
  Future<void> _readRemote() async {
    if (_disposed || _client == null) return;
    try {
      final response = await _client!.send(ServiceMethod.get, '/scheduler');
      if (!response.ok) {
        throw StateError('Daemon scheduler unavailable (${response.status})');
      }
      final body = response.body;
      final version = '${body['epoch']}:${body['revision']}';
      if (version != _remoteVersion) {
        _art.clear();
        await _refresh();
        _remoteVersion = version;
      }
      _publish(
        LibraryStatus(
          phase: body['running'] == true
              ? LibraryPhase.scanning
              : LibraryPhase.idle,
          scan: body['scan'] is Map<String, Object?>
              ? ScanStatus.fromJson(body['scan'] as Map<String, Object?>)
              : null,
          error: body['error'] as String?,
        ),
      );
    } catch (error) {
      _publish(LibraryStatus(phase: LibraryPhase.idle, error: '$error'));
    }
  }

  Future<void> _refresh() async {
    final client = _client;
    if (client == null) return;
    final nextVideoFiles = <int>{};
    final nextShelves = <LibrarySection, List<TrackSummary>>{};
    for (final entry in _ids.entries) {
      final items = entry.key == LibrarySection.music
          ? await client.tracks(entry.value)
          : [
              for (final item in await client.mediaItems(entry.value))
                if (item.metadata.kind == MediaKind.audio ||
                    item.metadata.kind == MediaKind.video)
                  _summary(item, nextVideoFiles),
            ];
      if (_disposed) return;
      final roots = rootsFor(entry.key);
      final visible = items
          .where((item) => roots.any((root) => p.isWithin(root, item.path)))
          .toList();
      nextShelves[entry.key] = visible;
    }
    // Keep the currently displayed shelves classified while asynchronous reads
    // are in progress. Publishing music must not temporarily turn existing
    // video rows into audio-only playback commands.
    _videoFiles
      ..clear()
      ..addAll(nextVideoFiles);
    for (final entry in nextShelves.entries) {
      if (entry.key == LibrarySection.music) {
        tracks.value = entry.value;
      } else {
        _shelves.putIfAbsent(entry.key, () => ValueNotifier(const [])).value =
            entry.value;
      }
    }
  }

  TrackSummary _summary(MediaItem item, Set<int> videoFiles) {
    final metadata = item.metadata;
    if (metadata.kind == MediaKind.video) videoFiles.add(item.fileId);
    final json = metadata.toJson();
    final title = json['title'] as String?;
    return TrackSummary(
      id: item.id,
      fileId: item.fileId,
      path: item.path,
      title: title == null || title.isEmpty
          ? p.basenameWithoutExtension(item.path)
          : title,
      artist: json['artist'] as String?,
      album: json['album'] as String?,
      duration: json['durationMs'] is num
          ? Duration(milliseconds: (json['durationMs'] as num).toInt())
          : null,
    );
  }

  void _publish(LibraryStatus next) {
    if (_disposed) return;
    status.value = next;
  }

  void _storageMoved() {
    final present = _storage!.value.present;
    final was = _cardPresent;
    _cardPresent = present;
    // The first reading is the baseline, not an arrival.
    if (was == null || present == was) return;
    _cardScan?.cancel();
    _cardScan = null;
    if (present) {
      _cardScan = Timer(cardSettle, () {
        if (scanOnCard) unawaited(scan());
      });
    }
  }

  @override
  Future<void> scan() => _scanning ??= _scan().whenComplete(() {
    _scanning = null;
  });

  Future<void> _scan() async {
    final client = await _ready;
    final id = _libraryId;
    if (client == null || id == null || _disposed) return;
    try {
      if (daemonScheduled) {
        final response = await client.send(ServiceMethod.post, '/scheduler');
        if (!response.ok) {
          throw StateError('Daemon scan refused (${response.status})');
        }
        do {
          await _observeRemote();
          if (!status.value.scanning || _disposed) break;
          await Future<void>.delayed(pollPeriod);
        } while (!_disposed);
        return;
      }
      final errors = <String>[];
      ScanStatus? last;
      _publish(const LibraryStatus(phase: LibraryPhase.scanning));
      for (final entry in _ids.entries) {
        if (_disposed) return;
        final id = entry.value;
        await _claimRoots(client, id, entry.key);
        final outcome = await client.scan(id);
        if (!outcome.accepted && outcome.status != 409) {
          errors.add('${entry.key.label}: ${outcome.message}');
          continue;
        }
        var scan = await client.scanStatus(id);
        _publish(LibraryStatus(phase: LibraryPhase.scanning, scan: scan));
        while (scan.running && !_disposed) {
          await Future<void>.delayed(pollPeriod);
          scan = await client.scanStatus(id);
          _publish(LibraryStatus(phase: LibraryPhase.scanning, scan: scan));
        }
        last = scan;
        for (final error in scan.errors) {
          errors.add('${entry.key.label}: ${error.message}');
        }
      }
      _art.clear();
      await _refresh();
      _publish(
        LibraryStatus(
          phase: LibraryPhase.idle,
          scan: last,
          error: errors.isEmpty ? null : errors.take(3).join('\n'),
        ),
      );
    } on Object catch (error) {
      _publish(
        LibraryStatus(
          phase: LibraryPhase.idle,
          scan: status.value.scan,
          error: '$error',
        ),
      );
    }
  }

  /// Reconcile configured folders with scanner roots, without deleting media.
  Future<void> _claimRoots(
    MediaClient client,
    int id,
    LibrarySection section,
  ) async {
    final desired = rootsFor(section).map(p.normalize).toSet();
    final existing = await client.listRoots(id);
    for (final root in existing) {
      if (!desired.contains(p.normalize(root.path))) {
        await client.removeRoot(id, root.id);
      }
    }
    final claimed = existing.map((root) => p.normalize(root.path)).toSet();
    for (final path in desired) {
      if (!claimed.contains(path) && Directory(path).existsSync()) {
        await client.addRoot(id, path);
      }
    }
  }

  @override
  Future<Uint8List?> artwork(int fileId) async {
    if (_art.containsKey(fileId)) return _art[fileId];
    final client = await _ready;
    if (client == null || _disposed) return null;
    Uint8List? bytes;
    try {
      bytes = (await client.artwork(fileId))?.bytes;
    } on Object {
      bytes = null;
    }
    // A miss is not remembered: the queue may render it a moment later.
    if (bytes == null) return null;
    if (_art.length >= _artKept) _art.remove(_art.keys.first);
    _art[fileId] = bytes;
    return bytes;
  }

  @override
  Future<void> prefetch(List<int> fileIds) async {
    final wanted = [
      for (final id in fileIds)
        if (!_art.containsKey(id)) id,
    ];
    if (wanted.isEmpty) return;
    final client = await _ready;
    if (client == null || _disposed) return;
    try {
      await client.prefetchArtwork(wanted);
    } on Object {
      // The queue is a courtesy; a shelf draws without it.
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _autoScan?.cancel();
    _cardScan?.cancel();
    _observer?.cancel();
    _storage?.removeListener(_storageMoved);
    final client = await _ready;
    await client?.close();
    status.dispose();
    tracks.dispose();
    for (final shelf in _shelves.values) {
      shelf.dispose();
    }
  }
}

/// An album on the shelf: a title, the artist it files under, and its
/// tracks in playing order.
@immutable
class AlbumShelf {
  const AlbumShelf({
    required this.title,
    required this.artist,
    required this.tracks,
  });

  final String title;

  /// The album artist when tagged, else the first track's - so a
  /// compilation is one album, not one per singer.
  final String? artist;

  /// Disc by disc, track by track, then by title for the untagged.
  final List<TrackSummary> tracks;

  int? get year =>
      tracks.map((track) => track.year).whereType<int>().firstOrNull;
}

/// An artist on the shelf and the albums filed under them.
@immutable
class ArtistShelf {
  const ArtistShelf({required this.name, required this.albums});

  final String name;
  final List<AlbumShelf> albums;

  /// Every track, album by album.
  List<TrackSummary> get tracks => [
    for (final album in albums) ...album.tracks,
  ];
}

/// The shelves: the one flat list of tracks, grouped and sorted the ways
/// the Music menu offers them. Pure functions - the same tracks in, the
/// same shelves out - so a screen can build its own from the library's
/// list and a test can check the order.
abstract final class MusicShelf {
  static const unknownAlbum = 'Unknown Album';
  static const unknownArtist = 'Unknown Artist';

  /// Every track, by title.
  static List<TrackSummary> songs(List<TrackSummary> tracks) =>
      [...tracks]..sort((a, b) => _byName(a.title, b.title));

  /// Every album, by title; each with its tracks in playing order.
  static List<AlbumShelf> albums(List<TrackSummary> tracks) {
    final grouped = <(String, String), List<TrackSummary>>{};
    for (final track in tracks) {
      final title = track.album ?? unknownAlbum;
      final artist = track.shelfArtist ?? unknownArtist;
      grouped.putIfAbsent((_fold(title), _fold(artist)), () => []).add(track);
    }
    final albums = [
      for (final group in grouped.values)
        AlbumShelf(
          title: group.first.album ?? unknownAlbum,
          artist: group.first.shelfArtist,
          tracks: [...group]..sort(_byPlayingOrder),
        ),
    ];
    albums.sort((a, b) {
      final byTitle = _byName(a.title, b.title);
      if (byTitle != 0) return byTitle;
      return _byName(a.artist ?? unknownArtist, b.artist ?? unknownArtist);
    });
    return albums;
  }

  /// Every artist, by name, each with their albums by year then title.
  static List<ArtistShelf> artists(List<TrackSummary> tracks) {
    final byArtist = <String, List<AlbumShelf>>{};
    final names = <String, String>{};
    for (final album in albums(tracks)) {
      final name = album.artist ?? unknownArtist;
      final key = _fold(name);
      names.putIfAbsent(key, () => name);
      byArtist.putIfAbsent(key, () => []).add(album);
    }
    final artists = [
      for (final MapEntry(:key, value: shelf) in byArtist.entries)
        ArtistShelf(
          name: names[key]!,
          albums: [...shelf]
            ..sort((a, b) {
              final byYear = (a.year ?? 0).compareTo(b.year ?? 0);
              if (byYear != 0) return byYear;
              return _byName(a.title, b.title);
            }),
        ),
    ];
    artists.sort((a, b) => _byName(a.name, b.name));
    return artists;
  }

  static int _byPlayingOrder(TrackSummary a, TrackSummary b) {
    final byDisc = (a.discNumber ?? 1).compareTo(b.discNumber ?? 1);
    if (byDisc != 0) return byDisc;
    final byTrack = (a.trackNumber ?? 0).compareTo(b.trackNumber ?? 0);
    if (byTrack != 0) return byTrack;
    return _byName(a.title, b.title);
  }

  /// Names sort without their case and without a leading article, the way
  /// a record shop files them: The Beatles under B.
  static int _byName(String a, String b) => _fold(a).compareTo(_fold(b));

  /// The letter used by fast library navigation, matching the sort key.
  static String sectionOf(String name, {bool ignoreArticles = true}) {
    final folded = ignoreArticles ? _fold(name) : name.trim().toLowerCase();
    if (folded.isEmpty) return '#';
    final first = String.fromCharCode(folded.runes.first).toUpperCase();
    return RegExp(r'^\p{L}', unicode: true).hasMatch(first) ? first : '#';
  }

  static String _fold(String name) {
    var folded = name.trim().toLowerCase();
    for (final article in const ['the ', 'a ', 'an ']) {
      if (folded.startsWith(article) && folded.length > article.length) {
        folded = folded.substring(article.length);
        break;
      }
    }
    return folded;
  }
}
