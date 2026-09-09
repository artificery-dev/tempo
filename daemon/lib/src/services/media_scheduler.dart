import 'dart:async';
import 'dart:io';
import 'package:cadence_media/cadence_media.dart';
import 'package:path/path.dart' as p;

/// Schedules scans in the daemon; status reads never walk media folders.
final class MediaScheduler {
  MediaScheduler(
    this.client, {
    required this.home,
    this.firstScanAfter = const Duration(seconds: 8),
    this.recheckAfter = const Duration(seconds: 25),
    this.cardSettle = const Duration(seconds: 3),
    this.pollPeriod = const Duration(milliseconds: 500),
  });
  final MediaClient client;
  final String home;
  final Duration firstScanAfter, recheckAfter, cardSettle, pollPeriod;
  static const sections = <String, (String, LibraryType)>{
    'music': ('Music', LibraryType.music),
    'podcasts': ('Podcasts', LibraryType.podcasts),
    'recordings': ('Recordings', LibraryType.music),
    'audiobooks': ('Audiobooks', LibraryType.books),
    'shows': ('Shows', LibraryType.shows),
    'movies': ('Movies', LibraryType.videos),
  };
  final ids = <String, int>{};
  final _remembered = <String, Set<String>>{};
  Map<String, Object?> _settings = {};
  String? _card;
  bool _observedCard = false, _closed = false;
  Timer? _startup, _arrival;
  Future<void>? _scanning;
  int _revision = 0;
  final String _epoch = DateTime.now().microsecondsSinceEpoch.toString();
  Map<String, Object?>? _scan;
  String? _error;
  Map<String, Object?> get status => {
    'epoch': _epoch,
    'revision': _revision,
    'running': _scanning != null,
    if (_scan != null) 'scan': _scan,
    if (_error != null) 'error': _error,
  };
  void configure(Map<String, Object?> values) {
    _settings = Map.from(values);
  }

  Object? setting(String key) => _settings['/settings/library/$key'];

  Future<void> start() async {
    final libraries = await client.listLibraries();
    for (final entry in sections.entries) {
      ids[entry.key] =
          libraries
              .where(
                (v) => v.name == entry.value.$1 && v.type == entry.value.$2,
              )
              .firstOrNull
              ?.id ??
          await client.createLibrary(entry.value.$1, entry.value.$2);
      // Remember roots from previous boots so removing a card never forgets it.
      _remembered[entry.key] = {
        for (final root in await client.listRoots(ids[entry.key]!)) root.path,
      };
    }
    var empty = true;
    for (final id in ids.values) {
      if ((await client.mediaItems(id)).isNotEmpty) {
        empty = false;
        break;
      }
    }
    if (_closed) return;
    _startup = Timer(empty ? firstScanAfter : recheckAfter, () {
      if (empty
          ? setting('scan-on-boot') != false
          : (setting('recheck') ?? 'startup') == 'startup') {
        unawaited(scan());
      }
    });
  }

  void observeCard(String? path) {
    final previous = _card;
    _card = path;
    final first = !_observedCard;
    _observedCard = true;
    if (first || path == previous || _closed) return;
    _arrival?.cancel();
    if (path != null) {
      _arrival = Timer(cardSettle, () {
        if (setting('scan-on-card') != false) unawaited(scan());
      });
    }
  }

  List<String> roots(String section) {
    final configured = setting('roots');
    if (configured is Map && configured[section] is List) {
      return [
        for (final path in configured[section] as List)
          if (path is String && p.isAbsolute(path)) p.normalize(path),
      ];
    }
    final known = _remembered.putIfAbsent(section, () => {});
    final label = sections[section]!.$1;
    known.add(p.join(home, label));
    if (_card != null) known.add(p.join(_card!, label));
    return known.toList();
  }

  Future<void> scan() {
    if (_closed) return Future.value();
    _startup?.cancel();
    return _scanning ??= _run().whenComplete(() {
      _scanning = null;
      _revision++;
    });
  }

  Future<void> _run() async {
    _error = null;
    final errors = <String>[];
    try {
      for (final entry in ids.entries) {
        if (_closed) break;
        final desired = roots(entry.key).toSet();
        final existing = await client.listRoots(entry.value);
        for (final root in existing) {
          if (!desired.contains(p.normalize(root.path))) {
            await client.removeRoot(entry.value, root.id);
          }
        }
        final claimed = existing.map((r) => p.normalize(r.path)).toSet();
        for (final root in desired) {
          if (!claimed.contains(root) && await Directory(root).exists()) {
            await client.addRoot(entry.value, root);
          }
        }
        if (_closed) break;
        final outcome = await client.scan(entry.value);
        if (!outcome.accepted && outcome.status != 409) {
          errors.add('${entry.key}: ${outcome.message}');
          continue;
        }
        while (true) {
          if (_closed) {
            await client.cancelScan(entry.value);
            break;
          }
          final response = await client.send(
            ServiceMethod.get,
            '/libraries/${entry.value}/scan',
          );
          _scan = response.body;
          final progress = ScanStatus.fromJson(response.body);
          if (!progress.running) {
            errors.addAll(
              progress.errors.map((e) => '${entry.key}: ${e.message}'),
            );
            break;
          }
          await Future<void>.delayed(pollPeriod);
        }
      }
    } catch (error) {
      errors.add('$error');
    }
    _error = errors.isEmpty ? null : errors.take(3).join('\n');
  }

  Future<void> close() async {
    _closed = true;
    _startup?.cancel();
    _arrival?.cancel();
    await _scanning;
  }
}
