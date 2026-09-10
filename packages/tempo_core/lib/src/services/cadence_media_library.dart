import 'dart:async';
import 'package:cadence_client/cadence_client.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'cadence_library.dart';
import 'library.dart';

/// Device shelves read Cadence directly. The hardware bridge owns root
/// configuration/automatic scans; closing this client never cancels those jobs.
class CadenceMediaLibrary implements CollectionLibrary {
  CadenceMediaLibrary(this.attachment) {
    _ready = _open();
  }
  final CadenceLibrary attachment;
  CadenceClient get client => attachment.client;
  late final Future<void> _ready;
  Future<void> get ready => _ready;
  Future<void>? _refreshing, _scanning;
  StreamSubscription<Map<String, Object?>>? _events;
  StreamSubscription<VolumeStatus?>? _volumeEvents;
  Timer? _poll, _debounce;
  bool _closed = false;
  String? _identity, _mediaBase;
  final _ids = <LibrarySection, int>{};
  final _shelves = <LibrarySection, ValueNotifier<List<TrackSummary>>>{};
  final _folders = <LibrarySection, List<String>>{};
  final _references =
      Expando<({String uuid, String volume, String generation})>();
  Set<int> _videos = {};
  final _art = <int, Uint8List>{};

  @override
  final ValueNotifier<LibraryStatus> status = ValueNotifier<LibraryStatus>(
    LibraryStatus.opening,
  );
  @override
  final ValueNotifier<List<TrackSummary>> tracks =
      ValueNotifier<List<TrackSummary>>(const []);
  @override
  ValueListenable<List<TrackSummary>> shelf(LibrarySection section) =>
      section == LibrarySection.music
      ? tracks
      : _shelves.putIfAbsent(section, () => ValueNotifier(const []));
  @override
  bool isVideo(TrackSummary track) => _videos.contains(track.fileId);
  @override
  List<String> rootsFor(LibrarySection section) => [
    if (_mediaBase != null)
      for (final path in _folders[section] ?? <String>[])
        p.posix.join(_mediaBase!, path.substring(1)),
  ];
  @override
  String encodeFolderPath(String path) {
    final base = _mediaBase;
    if (base == null ||
        !(p.posix.equals(base, path) || p.posix.isWithin(base, path))) {
      throw ArgumentError('Folder must be inside the declared media root');
    }
    return p.posix.equals(base, path)
        ? '/'
        : '/${p.posix.relative(path, from: base)}';
  }

  @override
  LibraryRoots? get locations =>
      () => [?_mediaBase];
  // These preferences are persisted through SettingsClient and acted on by the
  // headless host; the UI never schedules a second startup/arrival scan.
  @override
  set scanOnStartup(bool _) {}
  @override
  set scanOnCard(bool _) {}
  @override
  set recheck(String _) {}
  @override
  void configureFolders(Object? _) {
    _scheduleRefresh();
  }

  Future<void> _open() async {
    _events = client.events.listen((event) {
      if (event['type'] == 'volume-activity') return;
      if (event['type'] == 'media-artwork-updated') _art.clear();
      _scheduleRefresh();
    }, onError: (Object error) => _fail(error));
    _volumeEvents = attachment.changes.listen((volume) {
      final identity = volume == null
          ? null
          : '${volume.id}/${volume.generation}/${volume.state}';
      if (identity == _identity) return;
      _identity = identity;
      _clear();
      _scheduleRefresh();
    });
    await refresh();
    if (_closed) return;
    _poll = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(
        attachment.refresh().then<void>(
          (_) {},
          onError: (Object error) => _fail(error),
        ),
      );
    });
  }

  void _scheduleRefresh() {
    if (_closed || _debounce != null) return;
    _debounce = Timer(const Duration(milliseconds: 250), () {
      _debounce = null;
      unawaited(refresh());
    });
  }

  void _clear() {
    if (_closed) return;
    tracks.value = const [];
    for (final shelf in _shelves.values) {
      shelf.value = const [];
    }
    _art.clear();
    _ids.clear();
    _folders.clear();
    _videos = {};
    _mediaBase = null;
  }

  Future<void> refresh() =>
      _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  Future<void> _refresh() async {
    try {
      final volume = await attachment.refresh();
      if (_closed) return;
      if (volume.state != 'attached' ||
          volume.id == null ||
          volume.generation == null) {
        _clear();
        _fail(volume.error ?? 'Library unavailable');
        return;
      }
      final declaration = await client.volume();
      if (declaration['id'] != volume.id ||
          declaration['generation'] != volume.generation) {
        return;
      }
      final mediaBase = declaration['resolvedMediaRoot'];
      if (declaration['pathStyle'] != 'volume-posix' ||
          mediaBase is! String ||
          !p.posix.isAbsolute(mediaBase)) {
        throw const FormatException('Cadence media root is unavailable');
      }
      final libraries =
          (await client.call('get', '/libraries'))['libraries'] as List;
      final next = <LibrarySection, List<TrackSummary>>{};
      final folders = <LibrarySection, List<String>>{};
      final ids = <LibrarySection, int>{};
      final videos = <int>{};
      ScanStatus? latestScan;
      var scanning = false;
      for (final section in LibrarySection.values) {
        final rows = libraries.cast<Map>().where(
          (row) =>
              row['name'] == section.label && row['type'] == section.type.name,
        );
        if (rows.isEmpty) {
          next[section] = [];
          continue;
        }
        final row = rows.first;
        final id = row['id'] as int;
        final uuid = row['uuid'] as String;
        ids[section] = id;
        final rootRows =
            (await client.call('get', '/libraries/$id/roots'))['roots'] as List;
        folders[section] = [
          for (final root in rootRows) (root as Map)['path'] as String,
        ];
        final rowsOfItems = section == LibrarySection.music
            ? (await client.call('get', '/libraries/$id/tracks'))['tracks']
                  as List
            : await client.items(id);
        final summaries = <TrackSummary>[];
        for (final raw in rowsOfItems) {
          final item = raw as Map;
          final kind = section == LibrarySection.music ? 'audio' : item['kind'];
          if (kind != 'audio' && kind != 'video') continue;
          final metadata = section == LibrarySection.music
              ? item.cast<String, Object?>()
              : (item['metadata'] as Map).cast<String, Object?>();
          final path = item['path'] as String;
          final summary = TrackSummary.fromJson({
            ...metadata,
            if (section != LibrarySection.music) ...{
              'track': metadata['trackNumber'],
              'disc': metadata['discNumber'],
            },
            'id': item['id'],
            'fileId': item['fileId'],
            'path': path,
            'title':
                metadata['title'] ?? p.posix.basenameWithoutExtension(path),
          });
          _references[summary] = (
            uuid: uuid,
            volume: volume.id!,
            generation: volume.generation!,
          );
          if (kind == 'video') videos.add(summary.fileId);
          summaries.add(summary);
        }
        next[section] = summaries;
        final progress = await client.call('get', '/libraries/$id/scan');
        // Cadence's discovery phase is also a file-discovery phase in the UI.
        final scan = ScanStatus.fromJson({
          ...progress,
          if (progress['state'] == 'discovering') 'state': 'walking',
        });
        if (scan.running || latestScan == null) latestScan = scan;
        scanning = scanning || scan.running;
      }
      final current = attachment.volume;
      if (_closed ||
          current?.id != volume.id ||
          current?.generation != volume.generation ||
          current?.state != 'attached') {
        return;
      }
      _mediaBase = mediaBase;
      _ids
        ..clear()
        ..addAll(ids);
      _folders
        ..clear()
        ..addAll(folders);
      _videos = videos;
      for (final entry in next.entries) {
        if (entry.key == LibrarySection.music) {
          tracks.value = entry.value;
        } else {
          _shelves.putIfAbsent(entry.key, () => ValueNotifier(const [])).value =
              entry.value;
        }
      }
      status.value = LibraryStatus(
        phase: scanning ? LibraryPhase.scanning : LibraryPhase.idle,
        scan: latestScan,
      );
    } catch (error) {
      _fail(error);
    }
  }

  void _fail(Object error) {
    if (!_closed) {
      status.value = LibraryStatus(phase: LibraryPhase.idle, error: '$error');
    }
  }

  /// The display path is never used to open a library item.
  Future<String> resolvePath(TrackSummary track) async {
    final ref = _references[track];
    if (ref == null) throw StateError('Track is not from the current library');
    final current = await attachment.refresh();
    if (current.id != ref.volume || current.generation != ref.generation) {
      throw StateError('Library changed; select the track again');
    }
    return (await attachment.resolve(ref.uuid, track.id)).path;
  }

  @override
  Future<void> scan() =>
      _scanning ??= _scan().whenComplete(() => _scanning = null);
  Future<void> _scan() async {
    await _ready;
    for (final id in _ids.values.toList()) {
      if (_closed) return;
      try {
        await client.scan(id);
      } catch (error) {
        _fail(error);
        rethrow;
      }
    }
    await refresh();
  }

  @override
  Future<Uint8List?> artwork(int fileId) async {
    if (_closed) return null;
    if (_art[fileId] case final value?) return value;
    final before = _identity;
    final bytes = await client.artwork(fileId);
    if (_closed || before != _identity || bytes == null) return null;
    if (_art.length >= 48) _art.remove(_art.keys.first);
    return _art[fileId] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> prefetch(List<int> fileIds) async {
    if (_closed || fileIds.isEmpty) return;
    try {
      await client.call('post', '/artwork/prefetch', {'fileIds': fileIds});
    } catch (_) {
      /* On-demand artwork may retry. */
    }
  }

  @override
  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _poll?.cancel();
    _debounce?.cancel();
    await _events?.cancel();
    await _volumeEvents?.cancel();
    await _refreshing;
    status.dispose();
    tracks.dispose();
    for (final shelf in _shelves.values) {
      shelf.dispose();
    }
  }
}
