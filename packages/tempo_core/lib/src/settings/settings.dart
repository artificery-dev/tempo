import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:tomeui/tomeui.dart';

import 'setting_node.dart';

/// Who moved a setting.
///
/// Not for bookkeeping: a change's source decides how loud the answer is.
/// A brightness moved from the settings screen wants no on-screen notice -
/// the user is looking at the slider - and the same change arriving from an
/// OOBE page or a restored backup does.
enum SettingSource {
  /// The settings screens.
  settings,

  /// The quick settings sheet.
  quick,

  /// A first-run or upgrade page.
  oobe,

  /// A backup being put back, or a reset putting defaults in.
  restore,

  /// The player itself, not a person: a value the machine reports back
  /// (the volume the mixer actually took), a migration.
  system,
}

/// One setting moved: what, from what, to what, and who by.
@immutable
class SettingChange {
  const SettingChange({
    required this.path,
    required this.node,
    required this.from,
    required this.to,
    required this.source,
  });

  /// The setting's full path - `/settings/display/brightness`.
  final String path;

  /// The item itself, so whoever answers has its bind key, its store and
  /// its bounds without going back to the tree.
  final SettingNode node;

  final Object? from;
  final Object? to;

  final SettingSource source;

  /// The key of the code meant to answer this, or null for a setting that
  /// is only stored.
  String? get bind => node.bind;

  @override
  String toString() => 'SettingChange($path: $from -> $to, by ${source.name})';
}

/// Every setting the player has, what each is worth now, and a word to
/// whoever cares when one moves.
///
/// The tree says what the settings *are* ([SettingsTree]); this says what
/// they are *at*. Reading is [value] (or [read] for a typed one), writing
/// is [set], and a write does three things in this order: it stores the new
/// value, it tells the listeners for that one path, and it announces a
/// [SettingChange] on [changes].
///
/// That announcement is the whole design. Nothing here knows what a
/// brightness *is*: it does not talk to the backlight, the daemon, the
/// theme or the mixer. Something else listens and forwards - see
/// `SettingsBridge` - so the screens, the quick settings sheet and an OOBE
/// page all move settings the same way, and the machinery that answers
/// them is written once and in one place.
///
/// [changes] is synchronous: a listener sees the change before [set]
/// returns, which is what lets the theme repaint in the same frame as the
/// switch that asked for it.
class Settings {
  Settings({required this.tree, Map<String, Object?>? values})
    : _values = {...?values};

  /// What the settings are.
  final SettingsTree tree;

  /// What has been *stored*, which is only the settings somebody has
  /// moved. Everything else answers with its default, so a fresh install
  /// has an empty map and a full set of answers.
  final Map<String, Object?> _values;

  final StreamController<SettingChange> _changes =
      StreamController<SettingChange>.broadcast(sync: true);

  final Map<String, _SettingValue> _listenables = {};

  /// Every setting that moves, in the order it moves. Synchronous.
  Stream<SettingChange> get changes => _changes.stream;

  /// The stored values, for the file to write. Only what has been moved.
  Map<String, Object?> get stored => Map.unmodifiable(_values);

  /// What [path] is worth: what was stored for it, or its default.
  ///
  /// An alias answers with its target's value, so a pin, a screen and a
  /// search hit all read the one setting.
  Object? value(String path) {
    final entry = _entry(path);
    if (entry == null) return _values[path];
    final resolved = tree.resolve(entry);
    return _values.containsKey(resolved.path)
        ? _values[resolved.path]
        : resolved.node.defaultValue;
  }

  /// [value], typed, with the default as the floor: a setting whose stored
  /// value is the wrong shape (a file written by an older build, a hand
  /// edit) reads as its default rather than throwing into a screen.
  T read<T>(String path) {
    final value = this.value(path);
    if (value is T) return value;
    final fallback = _entry(path)?.node.defaultValue;
    if (fallback is T) return fallback;
    throw StateError('settings: $path is not a $T (it is $value)');
  }

  /// An int that may have been stored as a double, or the other way: JSON
  /// does not keep the difference and a slider's value is a number either
  /// way.
  int readInt(String path) => (read<num>(path)).round();
  double readDouble(String path) => (read<num>(path)).toDouble();
  bool readBool(String path) => read<bool>(path);

  /// A duration stored as milliseconds, or `never`/`off` for none.
  Duration? readDuration(String path) {
    final value = this.value(path);
    if (value is num) return Duration(milliseconds: value.round());
    return null;
  }

  /// Move [path] to [to]. Nothing happens if it is already there.
  ///
  /// The value is stored, the listeners for this path are told, and a
  /// [SettingChange] goes out on [changes] - in that order, so anything
  /// that reads the value while answering the change reads the new one.
  void set(
    String path,
    Object? to, {
    SettingSource source = SettingSource.settings,
  }) {
    final entry = _entry(path);
    final resolved = entry == null ? null : tree.resolve(entry);
    final key = resolved?.path ?? path;
    final from = value(key);
    if (from == to) return;

    // A value equal to the default is not stored: a settings file should
    // be what a user changed, not a copy of the tree.
    if (resolved != null && to == resolved.node.defaultValue) {
      _values.remove(key);
    } else {
      _values[key] = to;
    }

    _listenables[key]?.publish(to);
    if (resolved != null) {
      _changes.add(
        SettingChange(
          path: key,
          node: resolved.node,
          from: from,
          to: to,
          source: source,
        ),
      );
    }
  }

  /// Put every setting back to its default, one change each, so whatever
  /// answers them gets told about all of it.
  void resetAll({SettingSource source = SettingSource.restore}) {
    for (final path in _values.keys.toList()) {
      set(path, tree.at(path)?.node.defaultValue, source: source);
    }
  }

  /// Take a whole map of stored values at once - a file just read, a
  /// backup put back - announcing each one that actually moved.
  ///
  /// Values for paths the tree no longer has are kept but announced to
  /// nobody: a setting an older build stored is not a setting to throw
  /// away because this build's tree came from somewhere else.
  void restore(
    Map<String, Object?> values, {
    SettingSource source = SettingSource.restore,
  }) {
    for (final MapEntry(:key, :value) in values.entries) {
      if (tree.at(key) == null) {
        _values[key] = value;
        continue;
      }
      set(key, value, source: source);
    }
  }

  /// One setting as a listenable, for a widget that watches just it.
  ValueListenable<Object?> listen(String path) {
    final entry = _entry(path);
    final key = entry == null ? path : tree.resolve(entry).path;
    return _listenables.putIfAbsent(key, () => _SettingValue(value(key)));
  }

  /// Whether [path] can be moved right now: its `when` holds, and
  /// something is registered to answer it.
  ///
  /// [bound] is the set of bind keys somebody answers - `SettingBindings`'
  /// keys. A setting that is only stored (no bind at all) is always
  /// enabled: storing it *is* what it does.
  bool enabled(String path, {Set<String> bound = const {}}) {
    final entry = _entry(path);
    if (entry == null) return false;
    final node = tree.resolve(entry).node;
    final when = node.when;
    if (when != null && !when.holds(value(when.path))) return false;
    final bind = node.bind;
    if (bind != null && bound.isNotEmpty && !bound.contains(bind)) return false;
    return true;
  }

  /// Whether [path] is shown at all: every capability it needs is
  /// [available].
  bool visible(String path, {Set<String> available = const {}}) {
    final node = _entry(path)?.node;
    if (node == null) return false;
    return node.needs.every(available.contains);
  }

  SettingLocation? _entry(String path) => tree.at(path);

  void dispose() {
    for (final listenable in _listenables.values) {
      listenable.dispose();
    }
    _listenables.clear();
    _changes.close();
  }
}

class _SettingValue extends ValueNotifier<Object?> {
  _SettingValue(super.value);

  void publish(Object? next) => value = next;
}

/// Tells the widgets under it which [Settings] they are reading and
/// writing. The app installs one; a test installs its own.
class SettingsScope extends InheritedWidget {
  const SettingsScope({
    required this.settings,
    required super.child,
    super.key,
  });

  final Settings settings;

  static Settings of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<SettingsScope>();
    assert(scope != null, 'No SettingsScope above this widget.');
    return scope!.settings;
  }

  static Settings? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingsScope>()?.settings;

  @override
  bool updateShouldNotify(SettingsScope oldWidget) =>
      !identical(oldWidget.settings, settings);
}
