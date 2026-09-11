import 'package:flutter/foundation.dart';
import 'package:tempo_core/tempo_core.dart';

/// One library for the player's whole run, over whichever library the rig
/// has open at the moment.
///
/// The device keeps its interface up while Cadence swaps datastores under
/// it, so a card coming or going never restarts the player. The emulator
/// hosts its library in process and has to open a different one when the
/// profile moves between the card and the player's own storage; this
/// wrapper is what the player holds, and its notifiers stay the same
/// objects across a swap, so every shelf on screen simply reads the new
/// library's rows.
class SwappableLibrary implements CollectionLibrary {
  LibraryService? _current;
  LibraryService? get current => _current;

  final _status = ValueNotifier<LibraryStatus>(LibraryStatus.idle);
  final _tracks = ValueNotifier<List<TrackSummary>>(const []);
  final _shelves = <LibrarySection, ValueNotifier<List<TrackSummary>>>{};
  final _detach = <VoidCallback>[];

  // Settings the player pushes at the library, kept for the next one.
  Object? _folders;
  bool? _scanOnStartup;
  bool? _scanOnCard;
  String? _recheck;

  @override
  ValueListenable<LibraryStatus> get status => _status;

  @override
  ValueListenable<List<TrackSummary>> get tracks => _tracks;

  @override
  ValueListenable<List<TrackSummary>> shelf(LibrarySection section) =>
      section == LibrarySection.music ? _tracks : _shelfOf(section);

  ValueNotifier<List<TrackSummary>> _shelfOf(LibrarySection section) =>
      _shelves.putIfAbsent(section, () {
        final shelf = ValueNotifier<List<TrackSummary>>(const []);
        if (_current case final CollectionLibrary library) {
          _mirror(library.shelf(section), shelf);
        }
        return shelf;
      });

  /// Close what is open, then take up what [open] gives - in that order,
  /// since the next library may be over the same file as the last.
  Future<void> replace(LibraryService? Function() open) async {
    final old = _current;
    for (final detach in _detach) {
      detach();
    }
    _detach.clear();
    _current = null;
    if (old != null) await old.dispose();
    final next = open();
    if (next == null) {
      _status.value = LibraryStatus.idle;
      _tracks.value = const [];
      for (final shelf in _shelves.values) {
        shelf.value = const [];
      }
      return;
    }
    _current = next;
    if (next is CollectionLibrary) {
      if (_folders != null) next.configureFolders(_folders);
      if (_scanOnStartup case final value?) next.scanOnStartup = value;
      if (_scanOnCard case final value?) next.scanOnCard = value;
      if (_recheck case final value?) next.recheck = value;
    }
    _mirror(next.status, _status);
    _mirror(next.tracks, _tracks);
    for (final entry in _shelves.entries) {
      if (entry.key == LibrarySection.music) continue;
      if (next is CollectionLibrary) {
        _mirror(next.shelf(entry.key), entry.value);
      } else {
        entry.value.value = const [];
      }
    }
  }

  void _mirror<T>(ValueListenable<T> source, ValueNotifier<T> target) {
    void follow() => target.value = source.value;
    source.addListener(follow);
    _detach.add(() => source.removeListener(follow));
    follow();
  }

  @override
  Future<void> scan() => _current?.scan() ?? Future.value();

  @override
  Future<Uint8List?> artwork(int fileId) =>
      _current?.artwork(fileId) ?? Future.value(null);

  @override
  Future<void> prefetch(List<int> fileIds) =>
      _current?.prefetch(fileIds) ?? Future.value();

  @override
  bool isVideo(TrackSummary track) => switch (_current) {
    final CollectionLibrary library => library.isVideo(track),
    _ => false,
  };

  @override
  List<String> rootsFor(LibrarySection section) => switch (_current) {
    final CollectionLibrary library => library.rootsFor(section),
    _ => const [],
  };

  @override
  void configureFolders(Object? value) {
    _folders = value;
    if (_current case final CollectionLibrary library) {
      library.configureFolders(value);
    }
  }

  @override
  LibraryRoots? get locations => switch (_current) {
    final CollectionLibrary library => library.locations,
    _ => null,
  };

  @override
  String encodeFolderPath(String path) => switch (_current) {
    final CollectionLibrary library => library.encodeFolderPath(path),
    _ => path,
  };

  @override
  set scanOnStartup(bool value) {
    _scanOnStartup = value;
    if (_current case final CollectionLibrary library) {
      library.scanOnStartup = value;
    }
  }

  @override
  set scanOnCard(bool value) {
    _scanOnCard = value;
    if (_current case final CollectionLibrary library) {
      library.scanOnCard = value;
    }
  }

  @override
  set recheck(String value) {
    _recheck = value;
    if (_current case final CollectionLibrary library) {
      library.recheck = value;
    }
  }

  @override
  Future<void> dispose() async {
    await replace(() => null);
    _status.dispose();
    _tracks.dispose();
    for (final shelf in _shelves.values) {
      shelf.dispose();
    }
  }
}
