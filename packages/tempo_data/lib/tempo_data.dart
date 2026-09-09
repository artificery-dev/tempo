import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:file/file.dart';

class _DigestResult implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}

String _hashFile(File file) {
  final result = _DigestResult();
  final sink = sha256.startChunkedConversion(result);
  final input = file.openSync();
  try {
    while (true) {
      final bytes = input.readSync(65536);
      if (bytes.isEmpty) break;
      sink.add(bytes);
    }
  } finally {
    input.closeSync();
    sink.close();
  }
  return result.value.toString();
}

enum TempoStoragePolicy { yes, no, ask }

enum TempoStorageLocation { device, sd }

/// Paths use the supplied filesystem's namespace, never the host environment.
class TempoProfilePaths {
  const TempoProfilePaths({required this.data, required this.config});
  factory TempoProfilePaths.device(
    FileSystem fs, {
    required String home,
    required String configHome,
  }) => TempoProfilePaths(
    data: fs.path.join(home, '.tempo'),
    config: fs.path.join(configHome, 'tempo'),
  );
  factory TempoProfilePaths.sd(FileSystem fs, String cardRoot) =>
      TempoProfilePaths(
        data: fs.path.join(cardRoot, '.tempo'),
        config: fs.path.join(cardRoot, '.tempo', 'config'),
      );
  final String data, config;
}

class TempoStorageDecision {
  const TempoStorageDecision({
    required this.policy,
    required this.location,
    required this.activePaths,
    required this.needsPrompt,
    required this.sdAvailable,
  });
  final TempoStoragePolicy policy;
  final TempoStorageLocation location;

  /// Null when SD is selected but absent; callers must not open a device fallback.
  final TempoProfilePaths? activePaths;
  final bool needsPrompt, sdAvailable;
}

class TempoStorageRequest {
  const TempoStorageRequest({
    required this.policy,
    this.adoptExisting = false,
    this.replaceExisting = false,
    this.id,
  });
  final TempoStoragePolicy policy;
  final bool adoptExisting, replaceExisting;
  final String? id;
  Map<String, Object?> toJson() => {
    'version': 1,
    'policy': policy.name,
    'adoptExisting': adoptExisting,
    'replaceExisting': replaceExisting,
    'id': id,
  };
  factory TempoStorageRequest.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1)
      throw FormatException('Invalid pending profile request');
    return TempoStorageRequest(
      policy: TempoStoragePolicy.values.byName(json['policy'] as String),
      adoptExisting: json['adoptExisting'] == true,
      replaceExisting: json['replaceExisting'] == true,
      id: json['id'] as String?,
    );
  }
}

class TempoProfileConflict implements Exception {
  TempoProfileConflict(this.message);
  final String message;
  @override
  String toString() => 'TempoProfileConflict: $message';
}

/// Single-owner profile coordinator. Callers MUST close/checkpoint SQLite and
/// stop all profile readers/writers before switching or recovering. Media roots
/// are not part of a profile and this package never changes them.
///
/// Publication uses flushed journal/selector files and same-parent renames.
/// Recovery covers process interruption. package:file has no portable directory
/// fsync: this is not a claim of power-loss durability on every filesystem.
class TempoStorageManager {
  TempoStorageManager({
    required this.fs,
    required this.devicePaths,
    required this.selectorPath,
    this.cardRoot,
    this.checkpoint,
  }) {
    for (final path in [
      devicePaths.data,
      devicePaths.config,
      selectorPath,
      if (cardRoot != null) cardRoot!,
    ]) {
      if (!fs.path.isAbsolute(path))
        throw ArgumentError('Require absolute paths: $path');
    }
    for (final path in [
      devicePaths.data,
      devicePaths.config,
      if (cardRoot != null) sdPaths!.data,
    ]) {
      if (_inside(path, selectorPath)) {
        throw ArgumentError(
          'Selector must remain outside every copied profile',
        );
      }
    }
    if (_inside(devicePaths.data, devicePaths.config) ||
        _inside(devicePaths.config, devicePaths.data)) {
      throw ArgumentError('Device data/config roots must be separate');
    }
    if (cardRoot != null &&
        (_inside(devicePaths.data, sdPaths!.data) ||
            _inside(sdPaths!.data, devicePaths.data) ||
            _inside(devicePaths.config, sdPaths!.data) ||
            _inside(sdPaths!.data, devicePaths.config))) {
      throw ArgumentError('Device and SD profile roots must not overlap');
    }
  }
  final FileSystem fs;
  final TempoProfilePaths devicePaths;
  final String selectorPath;
  final String? cardRoot;

  /// Fault-injection seam, normally absent. Throwing simulates interruption.
  final Future<void> Function(String phase)? checkpoint;
  bool _busy = false;
  TempoProfilePaths? get sdPaths =>
      cardRoot == null ? null : TempoProfilePaths.sd(fs, cardRoot!);
  String get _journal => '$selectorPath.transaction';
  String get _pending => '$selectorPath.pending';
  String? _applyingId;
  bool _inside(String parent, String child) =>
      fs.path.equals(parent, child) || fs.path.isWithin(parent, child);
  bool get _cardPresent =>
      cardRoot != null && fs.directory(cardRoot!).existsSync();

  static String defaultSelectorPath(FileSystem fs, String home) =>
      fs.path.join(home, '.local', 'state', 'tempo', 'storage-selector.json');

  TempoStoragePolicy readSelector() {
    final file = fs.file(selectorPath);
    if (!file.existsSync()) return TempoStoragePolicy.ask;
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    if (json['version'] != 1)
      throw FormatException('Unsupported storage selector');
    return TempoStoragePolicy.values.byName(json['policy'] as String);
  }

  Future<T> _exclusive<T>(Future<T> Function() body) async {
    if (_busy) throw StateError('Profile operation already in progress');
    _busy = true;
    try {
      return await body();
    } finally {
      _busy = false;
    }
  }

  void _write(String path, Object value) {
    final file = fs.file(path);
    file.parent.createSync(recursive: true);
    final temp = fs.file('$path.new');
    if (temp.existsSync()) temp.deleteSync();
    temp.writeAsStringSync('${jsonEncode(value)}\n', flush: true);
    temp.renameSync(path);
  }

  void _select(TempoStoragePolicy policy, {String? requestId}) =>
      _write(selectorPath, {
        'version': 1,
        'policy': policy.name,
        'requestId': requestId ?? _applyingId,
      });
  Future<void> _step(String phase) async {
    await checkpoint?.call(phase);
  }

  TempoStorageRequest? readPendingRequest() => fs.file(_pending).existsSync()
      ? TempoStorageRequest.fromJson(
          jsonDecode(fs.file(_pending).readAsStringSync())
              as Map<String, dynamic>,
        )
      : null;

  /// Persists intent only. Safe with open databases: no database bytes are read.
  Future<TempoStorageRequest> prepareRequest(
    TempoStorageRequest request, {
    bool replacePending = false,
  }) => _exclusive(() async {
    if ((!replacePending && readPendingRequest() != null) ||
        fs.file(_journal).existsSync())
      throw StateError('A storage request is already pending');
    if (request.adoptExisting && request.replaceExisting)
      throw ArgumentError('Choose adoption or replacement');
    final current = readSelector();
    if (request.policy == TempoStoragePolicy.yes) {
      if (!_cardPresent) throw StateError('SD card unavailable');
      if (current != TempoStoragePolicy.yes &&
          fs.directory(sdPaths!.data).existsSync() &&
          !request.adoptExisting &&
          !request.replaceExisting) {
        throw TempoProfileConflict(
          'Existing SD profile requires explicit adoption or replacement',
        );
      }
      if (request.adoptExisting && !fs.directory(sdPaths!.data).existsSync())
        throw StateError('No SD profile to adopt');
    } else if (current == TempoStoragePolicy.yes) {
      if (!request.adoptExisting && !_cardPresent)
        throw StateError('SD source unavailable');
      if (!request.adoptExisting &&
          !request.replaceExisting &&
          (fs.directory(devicePaths.data).existsSync() ||
              fs.directory(devicePaths.config).existsSync())) {
        throw TempoProfileConflict(
          'Existing device profile requires explicit adoption or replacement',
        );
      }
    }
    final prepared = TempoStorageRequest(
      policy: request.policy,
      adoptExisting: request.adoptExisting,
      replaceExisting: request.replaceExisting,
      id: DateTime.now().microsecondsSinceEpoch.toString(),
    );
    _write(_pending, prepared.toJson());
    return prepared;
  });

  /// For failed restart scheduling, before any startup migration begins.
  Future<void> clearPendingRequest() => _exclusive(() async {
    if (fs.file(_journal).existsSync())
      throw StateError('Cannot discard a started migration');
    if (fs.file(_pending).existsSync()) fs.file(_pending).deleteSync();
  });

  /// Only call after all old profile readers/writers have stopped. Errors retain
  /// pending intent and recovery state; never silently open a different profile.
  Future<TempoStorageDecision> applyPendingAtStartup() async {
    if (_applyingId != null || _busy)
      throw StateError('Profile operation already in progress');
    await recover();
    final request = readPendingRequest();
    if (request == null) return resolveStartup();
    if (request.id == null)
      throw FormatException('Pending request lacks identity');
    final selector = fs.file(selectorPath);
    if (selector.existsSync() &&
        (jsonDecode(selector.readAsStringSync()) as Map)['requestId'] ==
            request.id) {
      await clearPendingRequest();
      return resolveStartup();
    }
    _applyingId = request.id;
    try {
      final current = readSelector();
      if (request.policy == TempoStoragePolicy.yes) {
        if (current == TempoStoragePolicy.yes) {
          if (!_cardPresent || !fs.directory(sdPaths!.data).existsSync())
            throw StateError('Selected SD profile unavailable');
          await setPolicy(request.policy);
        } else {
          await switchToSd(
            adoptExisting: request.adoptExisting,
            replaceExisting: request.replaceExisting,
          );
        }
      } else if (current == TempoStoragePolicy.yes) {
        await switchToDevice(
          adoptExisting: request.adoptExisting,
          replaceExisting: request.replaceExisting,
          policy: request.policy,
        );
      } else {
        await setPolicy(request.policy);
      }
      await _step('request-applied');
      await clearPendingRequest();
    } finally {
      _applyingId = null;
    }
    return resolveStartup();
  }

  /// No copies occur here. Choosing yes for a new SD profile should use
  /// switchToSd first. Dialog No leaves ask untouched; Don't Ask Again sets no.
  Future<void> setPolicy(TempoStoragePolicy policy) => _exclusive(() async {
    if (fs.file(_journal).existsSync())
      throw StateError('Recover pending switch first');
    _select(policy);
  });

  Future<TempoStorageDecision> resolveStartup() async {
    await recover();
    final policy = readSelector();
    final sd = policy == TempoStoragePolicy.yes;
    return TempoStorageDecision(
      policy: policy,
      location: sd ? TempoStorageLocation.sd : TempoStorageLocation.device,
      activePaths: sd
          ? (_cardPresent && fs.directory(sdPaths!.data).existsSync()
                ? sdPaths
                : null)
          : devicePaths,
      needsPrompt:
          policy == TempoStoragePolicy.ask &&
          _cardPresent &&
          fs.directory(sdPaths!.data).existsSync(),
      sdAvailable: _cardPresent,
    );
  }

  /// Explicit adoption leaves the existing card profile byte-for-byte intact.
  Future<void> acceptExistingSd() => _exclusive(() async {
    if (fs.file(_journal).existsSync())
      throw StateError('Recover pending switch first');
    if (!_cardPresent || !fs.directory(sdPaths!.data).existsSync()) {
      throw StateError('Existing SD profile is unavailable');
    }
    _inventory(
      sdPaths!.data,
    ); // Reject external links before opening this profile.
    _select(TempoStoragePolicy.yes);
  });

  Future<void> switchToSd({
    bool adoptExisting = false,
    bool replaceExisting = false,
  }) => _exclusive(() async {
    if (!_cardPresent) throw StateError('SD card unavailable');
    if (adoptExisting && replaceExisting)
      throw ArgumentError('Choose adoption or replacement');
    if (adoptExisting) {
      if (fs.file(_journal).existsSync())
        throw StateError('Recover pending switch first');
      if (!fs.directory(sdPaths!.data).existsSync())
        throw StateError('No SD profile to adopt');
      _inventory(sdPaths!.data);
      _select(TempoStoragePolicy.yes);
      return;
    }
    await _copy(devicePaths, sdPaths!, TempoStoragePolicy.yes, replaceExisting);
  });

  Future<void> switchToDevice({
    bool adoptExisting = false,
    bool replaceExisting = false,
    TempoStoragePolicy policy = TempoStoragePolicy.no,
  }) => _exclusive(() async {
    if (adoptExisting && replaceExisting)
      throw ArgumentError('Choose adoption or replacement');
    if (adoptExisting) {
      if (fs.file(_journal).existsSync())
        throw StateError('Recover pending switch first');
      if (policy == TempoStoragePolicy.yes)
        throw ArgumentError('Device policy must be no or ask');
      if (!fs.directory(devicePaths.data).existsSync())
        throw StateError('No device profile to adopt');
      _inventory(devicePaths.data);
      _inventory(devicePaths.config);
      _select(policy);
      return;
    }
    if (!_cardPresent || !fs.directory(sdPaths!.data).existsSync())
      throw StateError('SD profile unavailable');
    if (policy == TempoStoragePolicy.yes)
      throw ArgumentError('Device policy must be no or ask');
    await _copy(sdPaths!, devicePaths, policy, replaceExisting);
  });

  Map<String, String> _inventory(String directory) {
    final result = <String, String>{};
    if (fs.typeSync(directory, followLinks: false) ==
        FileSystemEntityType.link) {
      throw TempoProfileConflict('Profile root is a symlink: $directory');
    }
    if (fs.typeSync(directory, followLinks: false) ==
        FileSystemEntityType.notFound)
      return result;
    if (!fs.directory(directory).existsSync())
      throw TempoProfileConflict('Profile root is not a directory: $directory');
    for (final entry
        in fs
            .directory(directory)
            .listSync(recursive: true, followLinks: false)) {
      final relative = fs.path.relative(entry.path, from: directory);
      if (entry is Link)
        throw TempoProfileConflict('Symlink in profile: ${entry.path}');
      if (entry is File)
        result[relative] = _hashFile(entry);
      else if (entry is Directory)
        result['$relative/'] = 'directory';
      else
        throw TempoProfileConflict('Unsupported profile entry: ${entry.path}');
    }
    return result;
  }

  void _copyTree(String source, String target, {String? exclude}) {
    _inventory(source);
    fs.directory(target).createSync(recursive: true);
    if (!fs.directory(source).existsSync()) return;
    for (final entry
        in fs.directory(source).listSync(recursive: true, followLinks: false)) {
      if (exclude != null && _inside(exclude, entry.path)) continue;
      final path = fs.path.join(
        target,
        fs.path.relative(entry.path, from: source),
      );
      if (entry is Directory) fs.directory(path).createSync(recursive: true);
      if (entry is File) {
        fs.file(path).parent.createSync(recursive: true);
        final input = entry.openSync();
        try {
          final output = fs.file(path).openSync(mode: FileMode.write);
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
    }
  }

  Future<void> _copy(
    TempoProfilePaths source,
    TempoProfilePaths target,
    TempoStoragePolicy policy,
    bool replace,
  ) async {
    if (fs.file(_journal).existsSync())
      throw StateError('Recover pending switch first');
    final targets = [
      target.data,
      if (!_inside(target.data, target.config)) target.config,
    ];
    for (final path in targets) {
      if (fs.typeSync(path, followLinks: false) !=
              FileSystemEntityType.notFound &&
          !replace) {
        throw TempoProfileConflict(
          'Destination exists; explicitly adopt or replace: $path',
        );
      }
    }
    if (fs.path.equals(source.config, fs.path.join(source.data, 'config')) ==
            false &&
        fs.typeSync(fs.path.join(source.data, 'config'), followLinks: false) !=
            FileSystemEntityType.notFound &&
        _inside(target.data, target.config)) {
      throw TempoProfileConflict(
        'Device data/config would collide with SD config',
      );
    }
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final entries = [
      for (final path in targets)
        <String, dynamic>{
          'target': path,
          'stage': '$path.stage-$id',
          'backup': '$path.backup-$id',
          'files': <String, String>{},
        },
    ];
    final journal = <String, dynamic>{
      'version': 1,
      'phase': 'preparing',
      'policy': policy.name,
      'requestId': _applyingId,
      'replace': replace,
      'entries': entries,
    };
    _write(_journal, journal);
    await _step('preparing');
    _copyTree(
      source.data,
      entries.first['stage'] as String,
      exclude: _inside(source.data, source.config) ? source.config : null,
    );
    final configTarget = entries.length == 1
        ? fs.path.join(
            entries.first['stage'] as String,
            fs.path.relative(target.config, from: target.data),
          )
        : entries[1]['stage'] as String;
    _copyTree(source.config, configTarget);
    for (final entry in entries) {
      entry['files'] = _inventory(entry['stage'] as String);
    }
    journal['phase'] = 'prepared';
    _write(_journal, journal);
    await _step('prepared');
    await _finish(journal);
  }

  Future<void> recover() => _exclusive(() async {
    if (!fs.file(_journal).existsSync()) return;
    final journal =
        jsonDecode(fs.file(_journal).readAsStringSync())
            as Map<String, dynamic>;
    _validateJournal(journal);
    if (journal['policy'] == 'yes' && !_cardPresent) return;
    if (journal['phase'] == 'preparing') {
      for (final entry in journal['entries'] as List) {
        final stage = fs.directory(entry['stage'] as String);
        if (stage.existsSync()) stage.deleteSync(recursive: true);
      }
      fs.file(_journal).deleteSync();
      return;
    }
    await _finish(journal);
  });
  void _validateJournal(Map<String, dynamic> journal) {
    if (journal['version'] != 1 ||
        !['preparing', 'prepared'].contains(journal['phase']) ||
        !['yes', 'no', 'ask'].contains(journal['policy']))
      throw FormatException('Invalid profile journal');
    final target = journal['policy'] == 'yes' ? sdPaths : devicePaths;
    if (target == null)
      throw StateError('SD location needed to recover pending copy');
    final allowed = [
      target.data,
      if (!_inside(target.data, target.config)) target.config,
    ];
    final entries = journal['entries'] as List;
    if (entries.length != allowed.length)
      throw FormatException('Invalid copy destinations');
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i] as Map;
      if (entry['target'] != allowed[i])
        throw FormatException('Unexpected copy destination');
      for (final kind in ['stage', 'backup']) {
        final value = entry[kind] as String;
        if (!RegExp(
          '^${RegExp.escape(allowed[i])}\\.$kind-[0-9]+\$',
        ).hasMatch(value)) {
          throw FormatException('Unsafe recovery path');
        }
      }
    }
  }

  bool _matches(String path, Map expected) {
    if (!fs.directory(path).existsSync()) return false;
    final actual = _inventory(path);
    return actual.length == expected.length &&
        actual.entries.every((e) => expected[e.key] == e.value);
  }

  Future<void> _finish(Map<String, dynamic> journal) async {
    _validateJournal(journal);
    final entries = journal['entries'] as List;
    // Validate every staged/published tree before the first destination rename.
    for (final entry in entries) {
      final stage = entry['stage'] as String;
      if (!_matches(
        fs.directory(stage).existsSync() ? stage : entry['target'] as String,
        entry['files'] as Map,
      )) {
        throw TempoProfileConflict(
          'Pending profile copy is incomplete or modified; source and recovery backups retained',
        );
      }
    }
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      final stage = fs.directory(entry['stage'] as String);
      final target = fs.directory(entry['target'] as String);
      final backup = fs.directory(entry['backup'] as String);
      if (stage.existsSync()) {
        if (fs.typeSync(target.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          if (journal['replace'] != true || backup.existsSync()) {
            throw TempoProfileConflict(
              'Destination changed during profile copy; recovery retained',
            );
          }
          if (fs.typeSync(target.path, followLinks: false) !=
              FileSystemEntityType.directory) {
            throw TempoProfileConflict('Refusing non-directory replacement');
          }
          target.renameSync(backup.path);
          await _step('backed-up:$i');
        }
        stage.renameSync(target.path);
      }
      await _step('published:$i');
    }
    _select(
      TempoStoragePolicy.values.byName(journal['policy'] as String),
      requestId: journal['requestId'] as String?,
    );
    await _step('selected');
    for (final entry in entries) {
      final backup = fs.directory(entry['backup'] as String);
      if (backup.existsSync()) backup.deleteSync(recursive: true);
    }
    fs.file(_journal).deleteSync();
  }
}
