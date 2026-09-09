import 'dart:async';
import 'dart:convert';

import 'package:file/file.dart';
import 'package:tomeui/tomeui.dart';

import 'menu/menu_node.dart';
import 'storage/places.dart';

/// One of the player's top-level apps, as the thing that outlives its
/// screens: Home, Apps, Library, Settings, the pinned Files, Debug.
///
/// The dock gives every applet a stage of its own and keeps it mounted
/// while another is on stage, which is what makes switching back land
/// where you left off. An applet is the object behind that stage - its
/// navigator, its focus scope, the observer its screens watch their routes
/// through, the bar chrome it publishes - plus [state]: a small store of
/// what the applet wants to remember across restarts, written to a file in
/// the player's home. Files keeps its open folders there; the dock will
/// keep its pins.
class Applet {
  Applet({required this.entry, required AppletStore store})
    : navigator = GlobalKey<NavigatorState>(),
      scope = FocusScopeNode(debugLabel: 'applet ${entry.path}'),
      observer = RouteObserver<PageRoute<dynamic>>(),
      state = store.open(entry.path);

  /// The menu entry the applet is: its path is the applet's id.
  final MenuLocation entry;

  String get id => entry.path;
  String get label => entry.label;

  /// The applet's own stack of screens.
  final GlobalKey<NavigatorState> navigator;

  /// The applet's own focus, so the wheel returns to what it was on.
  final FocusScopeNode scope;

  /// What the applet's screens subscribe to for their route's comings and
  /// goings.
  final RouteObserver<PageRoute<dynamic>> observer;

  /// What the applet remembers.
  final AppletState state;

  void dispose() {
    scope.dispose();
    state.flush();
  }

  /// The applet the screen at [context] belongs to, or null off the dock:
  /// a screen pushed by a test, or one that is not an applet's.
  static Applet? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppletScope>()?.applet;

  @override
  String toString() => 'Applet($id)';
}

/// Tells the screens under it which [Applet] they are part of.
class AppletScope extends InheritedWidget {
  const AppletScope({required this.applet, required super.child, super.key});

  final Applet applet;

  @override
  bool updateShouldNotify(AppletScope oldWidget) => applet != oldWidget.applet;
}

/// An applet's memory: plain JSON values by key, read from its file when
/// the applet is made and written back a moment after they change.
///
/// Values are what JSON can carry - strings, numbers, booleans, lists and
/// maps of those - so the file is readable and a value written by one
/// version is readable by the next. Reads are synchronous (the file is
/// small and local); writes settle for a beat so a wheel spinning through
/// a list writes once, not eighty times.
class AppletState {
  AppletState._(this._file, Map<String, Object?> values) : _values = values;

  final File? _file;
  final Map<String, Object?> _values;

  /// Fires when a value changes, for anything that shows one.
  final changed = ValueNotifier<int>(0);

  Timer? _pending;
  bool _dirty = false;
  static final _dirtyStates = <AppletState>{};

  /// Persist pending applet changes before switching the owned data profile.
  static void flushForStorageChange() {
    for (final state in _dirtyStates.toList()) {
      state.flush(requireSuccess: true);
    }
  }

  /// Long enough that a run of changes writes once, short enough that a
  /// crash after one loses nothing worth having.
  static const settle = Duration(milliseconds: 400);

  /// The value at [key], if it is there and is a [T].
  T? get<T>(String key) {
    final value = _values[key];
    return value is T ? value : null;
  }

  /// Remember [value] at [key]; null forgets it.
  void set(String key, Object? value) {
    if (value == null ? !_values.containsKey(key) : _values[key] == value) {
      return;
    }
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
    _dirty = true;
    _dirtyStates.add(this);
    changed.value++;
    _pending?.cancel();
    _pending = Timer(settle, flush);
  }

  /// Everything remembered, as it would be written.
  Map<String, Object?> get values => Map.unmodifiable(_values);

  /// Write now, if anything is waiting to be written.
  void flush({bool requireSuccess = false}) {
    if (!_dirty) return;
    _pending?.cancel();
    _pending = null;
    final file = _file;
    if (file == null) {
      _dirty = false;
      _dirtyStates.remove(this);
      return;
    }
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(_values),
        flush: requireSuccess,
      );
      _dirty = false;
      _dirtyStates.remove(this);
    } on FileSystemException catch (error) {
      if (requireSuccess) rethrow;
      debugPrint('applet: ${file.path}: ${error.message}');
    }
  }
}

/// Where applets keep their state: one JSON file each under
/// `~/.tempo/applets/`, in the player's home on the machine's filesystem -
/// the device's, the emulator's host folder, or a test's in memory.
class AppletStore {
  const AppletStore(this.places);

  /// No files at all: state that lives for the session.
  const AppletStore.ephemeral() : places = null;

  final Places? places;

  /// The file [id]'s state lives in.
  File? fileFor(String id) {
    final places = this.places;
    if (places == null) return null;
    final name = id == '/' ? 'root' : id.substring(1).replaceAll('/', '.');
    return places.fileSystem.file('${places.data}/applets/$name.json');
  }

  /// Open [id]'s state: what its file holds, or nothing.
  AppletState open(String id) {
    final file = fileFor(id);
    var values = <String, Object?>{};
    if (file != null) {
      try {
        if (file.existsSync()) {
          final decoded = jsonDecode(file.readAsStringSync());
          if (decoded is Map<String, Object?>) values = decoded;
        }
      } on Object catch (error) {
        // A damaged file is a fresh start, not a broken applet.
        debugPrint('applet: ${file.path} unreadable: $error');
      }
    }
    return AppletState._(file, values);
  }
}
