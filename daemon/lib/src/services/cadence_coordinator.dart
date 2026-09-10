import 'dart:async';
import 'dart:io';
import 'package:cadence_client/cadence_client.dart';
import 'package:path/path.dart' as p;
import 'cadence_roots.dart';

/// Hardware-side policy for library sections and boot scans. cadenced owns all
/// filesystem scanning, job execution, database writes, and artifact generation.
class CadenceCoordinator {
  CadenceCoordinator(this.client, {required this.roots, required this.log});
  final CadenceClient client;
  final CadenceRoots roots;
  final void Function(String) log;
  static const sections = {
    'music': ('Music', 'music'),
    'podcasts': ('Podcasts', 'podcasts'),
    'recordings': ('Recordings', 'music'),
    'audiobooks': ('Audiobooks', 'books'),
    'shows': ('Shows', 'shows'),
    'movies': ('Movies', 'videos'),
  };
  Map<String, Object?> _settings = {};
  final _ids = <String, int>{};
  bool _closed = false;
  Future<void> _tail = Future.value();
  Timer? _startup, _observations;
  Future<void> _queue(Future<void> Function() action) {
    final result = _tail.then<void>((_) async {
      if (!_closed) await action();
    });
    _tail = result.catchError((Object error) => log('Cadence policy: $error'));
    return result;
  }

  Future<void> start(Map<String, Object?> settings) async {
    _settings = Map.of(settings);
    await _queue(_configure);
    _observations = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(
        _queue(() async {
          await roots.synchronize();
        }),
      );
    });
    _startup = Timer(const Duration(seconds: 8), () {
      if (_settings['/settings/library/scan-on-boot'] != false) {
        unawaited(_queue(_scan));
      }
    });
  }

  Future<void> configure(Map<String, Object?> settings) {
    _settings = Map.of(settings);
    return _queue(_configure);
  }

  Future<void> _configure() async {
    final volume = await client.volume();
    if (volume['state'] != 'attached') return;
    final mediaRoot = volume['resolvedMediaRoot'];
    if (mediaRoot is! String || !p.posix.isAbsolute(mediaRoot)) {
      throw StateError('Cadence did not declare an absolute media base');
    }
    final mediaMount = volume['mediaMount'];
    final reading = roots.device();
    final mediaAvailable =
        mediaMount == null ||
        (reading.cardPath == mediaMount && reading.cardMountId != null);
    final libraries =
        (await client.call('get', '/libraries'))['libraries'] as List;
    final configured = _settings['/settings/library/roots'];
    for (final entry in sections.entries) {
      final matching = libraries.cast<Map>().where(
        (v) => v['name'] == entry.value.$1 && v['type'] == entry.value.$2,
      );
      final id = matching.isEmpty
          ? await client.createLibrary(entry.value.$1, entry.value.$2)
          : matching.first['id'] as int;
      _ids[entry.key] = id;
      final custom = configured is Map ? configured[entry.key] : null;
      final wanted = <String>{};
      if (custom is List) {
        for (final raw in custom) {
          if (raw is! String ||
              !p.posix.isAbsolute(raw) ||
              p.posix.normalize(raw) != raw) {
            throw FormatException('Invalid library folder: $raw');
          }
          wanted.add(raw);
        }
      } else {
        final defaultFolder = '/${entry.value.$1}';
        if (mediaAvailable &&
            await Directory(p.posix.join(mediaRoot, entry.value.$1)).exists()) {
          wanted.add(defaultFolder);
        }
      }
      final existing =
          (await client.call('get', '/libraries/$id/roots'))['roots'] as List;
      // Missing media must never remove roots. Only an explicit folder setting
      // authorizes removing a configured root.
      for (final raw in existing.cast<Map>()) {
        if (custom is List && !wanted.contains(raw['path'])) {
          await client.call('delete', '/libraries/$id/roots/${raw['id']}');
        }
      }
      final known = existing.cast<Map>().map((v) => v['path']).toSet();
      for (final path in wanted.difference(known.cast<String>())) {
        await client.call('post', '/libraries/$id/roots', {'path': path});
      }
    }
    await roots.synchronize();
  }

  Future<void> _scan() async {
    await roots.synchronize();
    for (final id in _ids.values) {
      if (_closed) return;
      try {
        await client.scan(id);
      } on MediaError catch (error) {
        if (error.status != 409) rethrow;
      }
    }
  }

  Future<void> observeCard() => _queue(() async {
    await _configure();
    // Cadence owns reconciliation when the observed media returns. Do not
    // duplicate that job in a frontend or on every hardware poll.
  });
  Future<void> close() async {
    _closed = true;
    _startup?.cancel();
    _observations?.cancel();
    await _tail;
    await roots.close();
  }
}
