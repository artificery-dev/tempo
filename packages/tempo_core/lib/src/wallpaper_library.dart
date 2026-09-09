import 'package:file/file.dart';
import 'package:path/path.dart' as p;
import 'package:tomeui/tomeui.dart';

import 'storage/places.dart';
import 'wallpaper.dart';

/// Something in the wallpaper folders: a picture, or a folder of them.
@immutable
class WallpaperCandidate {
  const WallpaperCandidate({
    required this.path,
    required this.name,
    this.isFolder = false,
  });

  /// Where it is, in the player's own namespace.
  final String path;

  /// What the picker calls it: the filename without its extension, or the
  /// folder's own name.
  final String name;

  /// Whether choosing it opens it rather than sets it.
  final bool isFolder;

  @override
  bool operator ==(Object other) =>
      other is WallpaperCandidate && other.path == path;

  @override
  int get hashCode => path.hashCode;
}

/// Where the player looks for wallpapers, and what is in there.
///
/// Three folders, in the order a picture is most likely to be in one: the
/// card's, the home's, and the one inside the home's Pictures. Named
/// folders rather than "every image on the card", because a wallpaper is a
/// thing chosen deliberately and a music card is full of cover art nobody
/// meant to offer.
///
/// What is inside them is browsed rather than flattened. A collection of
/// wallpapers is almost always *sorted* - by where it came from, by who
/// made it - and flattening it into one list of nine hundred names throws
/// away the only organisation it had.
abstract final class WallpaperLibrary {
  /// The folder name looked for in each root.
  static const folder = 'Wallpapers';

  /// The roots, in the order they are searched.
  static List<String> rootsIn(Places places) => [
    p.posix.join(places.sdCard, folder),
    p.posix.join(places.home, folder),
    p.posix.join(places.home, 'Pictures', folder),
  ];

  /// What is at the top of the picker: the three roots' contents together,
  /// as though they were one folder.
  ///
  /// Together rather than as three rows, because "the card's Wallpapers"
  /// and "the home's Wallpapers" is a distinction about where a file
  /// happens to live, not about what the picture is - and a player with
  /// only one of them would otherwise make you walk through a folder to
  /// reach anything at all.
  static List<WallpaperCandidate> top(Places places) =>
      _merge(places, rootsIn(places));

  /// What is inside one folder.
  static List<WallpaperCandidate> inside(Places places, String path) =>
      _merge(places, [path]);

  /// Every picture in the wallpaper folders and their subfolders, flat.
  /// Not what the picker shows - it browses - but what a caller wanting
  /// "any wallpaper at all" needs.
  static List<WallpaperCandidate> everyPicture(
    Places places, {
    String? folder,
    int depth = 8,
  }) {
    final found = <WallpaperCandidate>[];
    for (final entry in folder == null ? top(places) : inside(places, folder)) {
      if (!entry.isFolder) {
        found.add(entry);
      } else if (depth > 0) {
        found.addAll(
          everyPicture(places, folder: entry.path, depth: depth - 1),
        );
      }
    }
    return found;
  }

  /// The contents of [roots], merged and ordered: folders first, then
  /// pictures, each by name.
  ///
  /// A root or folder that is not there is not an error: a player with no
  /// card, or nobody who has made a Wallpapers folder, simply has fewer to
  /// choose from - and the picker says so rather than failing.
  static List<WallpaperCandidate> _merge(Places places, List<String> roots) {
    final found = <String, WallpaperCandidate>{};
    for (final root in roots) {
      final directory = places.fileSystem.directory(root);
      try {
        if (!directory.existsSync()) continue;
        for (final entity in directory.listSync()) {
          final base = p.posix.basename(entity.path);
          if (base.startsWith('.')) continue;
          final WallpaperCandidate candidate;
          if (entity is Directory) {
            candidate = WallpaperCandidate(
              path: entity.path,
              name: base,
              isFolder: true,
            );
          } else if (entity is File) {
            final ext = p.posix
                .extension(base)
                .replaceFirst('.', '')
                .toLowerCase();
            if (!WallpaperSource.extensions.contains(ext)) continue;
            candidate = WallpaperCandidate(
              path: entity.path,
              name: p.posix.basenameWithoutExtension(base),
            );
          } else {
            continue;
          }
          // The first root to offer a name keeps it: the card is the one
          // the user is most likely to have just put a picture on.
          found.putIfAbsent(
            '${candidate.isFolder}/${candidate.name.toLowerCase()}',
            () => candidate,
          );
        }
      } on FileSystemException catch (error) {
        debugPrint('wallpaper: $root: ${error.message}');
      }
    }
    return found.values.toList()..sort((a, b) {
      if (a.isFolder != b.isFolder) return a.isFolder ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  }
}
