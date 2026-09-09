import 'dart:async';
import 'dart:convert';

import 'package:file/file.dart';
import 'package:tomeui/tomeui.dart';

import '../storage/places.dart';
import 'settings.dart';

/// What the player is set to, kept between boots: one JSON object at
/// `settings.json` in the player's config folder, keyed by setting path.
///
/// Only what a user has actually moved is written. A setting sitting at
/// its default is absent, so the file is a record of choices rather than a
/// copy of the tree - which means a default that changes in a later build
/// reaches everyone who never touched it.
///
/// Writes are on a settle timer: dragging a slider writes once when it
/// stops rather than eighty times on the way, and the last change before
/// the power goes is still written ([saveSync], from [dispose]).
class SettingsFile {
  SettingsFile({
    required this.settings,
    required this.file,
    this.readRemote,
    this.writeRemote,
  });

  /// Where the settings live for [places]: `settings.json`, beside the
  /// wallpaper, in `Places.config`.
  factory SettingsFile.at(
    Places places, {
    required Settings settings,
    Future<Map<String, Object?>> Function()? readRemote,
    Future<void> Function(Map<String, Object?>)? writeRemote,
  }) => SettingsFile(
    settings: settings,
    readRemote: readRemote,
    writeRemote: writeRemote,
    file: places.fileSystem.file('${places.config}/settings.json'),
  );

  final Settings settings;
  final File file;
  final Future<Map<String, Object?>> Function()? readRemote;
  final Future<void> Function(Map<String, Object?>)? writeRemote;
  Future<void> _writing = Future<void>.value();
  bool _disposed = false;
  bool _paused = false;

  /// Long enough that a wheel-driven slider writes once, short enough that
  /// a crash after a change loses nothing. The emulator's own session file
  /// settles on the same 400 ms, for the same reason.
  static const Duration settle = Duration(milliseconds: 400);

  Timer? _pending;
  StreamSubscription<SettingChange>? _subscription;

  /// Read what was saved and put it back, announcing each value as a
  /// change so whatever answers settings catches up with the file.
  ///
  /// Anything missing or unreadable leaves the defaults in place: a
  /// settings file is a convenience, and a broken one must not be a
  /// broken player.
  Future<void> load({SettingSource source = SettingSource.restore}) async {
    if (readRemote case final read?) {
      // A failed remote load must not overwrite existing choices with defaults.
      settings.restore(await read(), source: source);
      return;
    }
    final Map<String, Object?> saved;
    try {
      if (!file.existsSync()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) {
        debugPrint('settings: ${file.path} is not an object');
        return;
      }
      saved = decoded;
    } on Object catch (error) {
      debugPrint('settings: ${file.path} unreadable: $error');
      return;
    }
    settings.restore(saved, source: source);
  }

  /// Write whenever anything moves, from here on.
  void watch() {
    _paused = false;
    _subscription ??= settings.changes.listen((_) => _schedule());
  }

  /// Stop watching - and a change still waiting is written now, not
  /// dropped: the last thing done before the player goes off is the one
  /// most worth remembering.
  void dispose() {
    _disposed = true;
    _subscription?.cancel();
    _subscription = null;
    if (_pending != null) {
      _pending!.cancel();
      _pending = null;
      saveSync();
    }
  }

  /// Stop automatic writes while the bootstrap owner changes profiles.
  /// The caller flushes with save() before beginning the transition.
  void pauseWrites() {
    _paused = true;
    _pending?.cancel();
    _pending = null;
    _subscription?.cancel();
    _subscription = null;
  }

  Future<void> flushForStorageChange() async {
    _pending?.cancel();
    _pending = null;
    await _writing;
    if (writeRemote case final write?) {
      await write(Map<String, Object?>.from(settings.stored));
    } else {
      file.parent.createSync(recursive: true);
      await file.writeAsString(_encoded(), flush: true);
    }
    pauseWrites();
  }

  void _schedule() {
    _pending?.cancel();
    _pending = Timer(settle, save);
  }

  Future<void> save() async {
    if (_paused) return;
    _pending?.cancel();
    _pending = null;
    if (writeRemote case final write?) {
      final snapshot = Map<String, Object?>.from(settings.stored);
      _writing = _writing.then((_) => write(snapshot)).catchError((
        Object error,
      ) {
        debugPrint('settings: daemon save failed: $error');
        if (!_disposed && !_paused) {
          _pending?.cancel();
          _pending = Timer(const Duration(seconds: 5), save);
        }
      });
      await _writing;
      return;
    }
    try {
      file.parent.createSync(recursive: true);
      await file.writeAsString(_encoded());
    } on FileSystemException catch (error) {
      debugPrint('settings: unwritable: ${error.message}');
    }
  }

  /// [save], without waiting: for the way out, when there is no later.
  void saveSync() {
    if (_paused) return;
    if (writeRemote != null) {
      unawaited(save());
      return;
    }
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(_encoded());
    } on FileSystemException catch (error) {
      debugPrint('settings: unwritable: ${error.message}');
    }
  }

  /// Sorted by path, so a diff of two files reads as a list of choices
  /// rather than as whatever order they were made in.
  String _encoded() {
    final stored = settings.stored;
    final keys = stored.keys.toList()..sort();
    return const JsonEncoder.withIndent(
      '  ',
    ).convert({for (final key in keys) key: stored[key]});
  }
}
