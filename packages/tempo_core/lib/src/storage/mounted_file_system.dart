import 'dart:io' as io;

import 'package:file/file.dart';
import 'package:path/path.dart' as p;

import 'mounted_entities.dart';

/// One filesystem assembled out of several.
///
/// The device has a whole Linux filesystem with a card mounted into it at
/// [MountedFileSystem.mount]-style paths, and the player's file browser is
/// written against that: one namespace, with `/mnt/sd` inside it. The
/// emulator has to offer the same shape - a made-up root with a real host
/// folder appearing inside it - which is what this is for.
///
/// Paths are resolved against the longest mount that prefixes them and
/// handed to that filesystem rooted at its own `/`; everything else goes to
/// [root]. What comes back wears the *outer* path, so walking up out of a
/// mount lands in the filesystem the mount point lives in.
///
/// Deliberately no more than a browser needs: no symbolic links across a
/// mount boundary, and [currentDirectory] is the root's.
class MountedFileSystem extends FileSystem {
  MountedFileSystem({
    required this.root,
    Map<String, FileSystem> mounts = const {},
    Map<String, String> mountRoots = const {},
  }) : _mountRoots = {
         for (final entry in mountRoots.entries)
           _normalize(entry.key): entry.value,
       },
       _mounts = {
         for (final entry in mounts.entries) _normalize(entry.key): entry.value,
       };

  /// What a path resolves against when no mount claims it.
  final FileSystem root;

  final Map<String, FileSystem> _mounts;
  final Map<String, String> _mountRoots;

  /// Where each filesystem is mounted, longest first - so `/mnt/sd/x` finds
  /// `/mnt/sd` before `/mnt`.
  Iterable<String> get mountPoints {
    final points = _mounts.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    return points;
  }

  /// The filesystem a path lands in, and the path it lands on inside it.
  ({FileSystem fs, String path, String mount}) resolve(String outer) {
    final normalized = _normalize(outer);
    for (final mount in mountPoints) {
      if (normalized == mount || normalized.startsWith('$mount/')) {
        final inner = normalized.substring(mount.length);
        final fs = _mounts[mount]!;
        final root =
            _mountRoots[mount] ?? fs.path.rootPrefix(fs.currentDirectory.path);
        final target = fs.path.joinAll([
          root,
          ...p.posix
              .split(inner)
              .where((part) => part != '/' && part.isNotEmpty),
        ]);
        if (_mountRoots.containsKey(mount)) _checkRoot(fs, root, target);
        return (fs: fs, path: target, mount: mount);
      }
    }
    return (fs: root, path: normalized, mount: '');
  }

  // Resolve the nearest existing ancestor before delegating so a symlink
  // cannot turn a selected host folder into access above its mount root.
  void _checkRoot(FileSystem fs, String root, String target) {
    final boundary = fs.directory(root).resolveSymbolicLinksSync();
    var ancestor = target;
    while (fs.typeSync(ancestor, followLinks: false) ==
        FileSystemEntityType.notFound) {
      final parent = fs.path.dirname(ancestor);
      if (parent == ancestor) break;
      ancestor = parent;
    }
    final resolved =
        fs.typeSync(ancestor, followLinks: false) ==
            FileSystemEntityType.directory
        ? fs.directory(ancestor).resolveSymbolicLinksSync()
        : fs.file(ancestor).resolveSymbolicLinksSync();
    if (!fs.path.equals(boundary, resolved) &&
        !fs.path.isWithin(boundary, resolved)) {
      throw FileSystemException('Path escapes the mounted host folder', target);
    }
  }

  /// The outer path for [inner] in the filesystem mounted at [mount].
  ///
  /// Joined rather than concatenated: what a delegate calls a path is its
  /// own business, and a listing of a filesystem's root hands back bare
  /// names as readily as absolute ones.
  String outerPath(String mount, String inner) {
    if (mount.isEmpty) return _normalize(inner);
    final context = _mounts[mount]!.path;
    final root = _mountRoots[mount] ?? context.rootPrefix(inner);
    final relative = root.isEmpty ? inner : context.relative(inner, from: root);
    return _normalize(p.posix.joinAll([mount, ...context.split(relative)]));
  }

  /// Which mount an entity from a delegate filesystem belongs to.
  String mountOf(FileSystem fs, {String? path}) {
    if (fs == root) return '';
    final candidates =
        _mounts.keys.where((mount) {
          if (_mounts[mount] != fs) return false;
          final boundary = _mountRoots[mount];
          return path == null ||
              boundary == null ||
              fs.path.equals(boundary, path) ||
              fs.path.isWithin(boundary, path);
        }).toList()..sort(
          (a, b) => (_mountRoots[b]?.length ?? 0).compareTo(
            _mountRoots[a]?.length ?? 0,
          ),
        );
    return candidates.isEmpty ? '' : candidates.first;
  }

  static String _normalize(String path) {
    final normalized = p.posix.normalize(path.isEmpty ? '/' : path);
    if (!normalized.startsWith('/')) return '/$normalized';
    return normalized == '/' ? '/' : normalized.replaceAll(RegExp(r'/+$'), '');
  }

  @override
  Directory directory(dynamic path) =>
      MountedDirectory(this, _normalize(getPath(path)));

  @override
  File file(dynamic path) => MountedFile(this, _normalize(getPath(path)));

  @override
  Link link(dynamic path) => MountedLink(this, _normalize(getPath(path)));

  @override
  p.Context get path => p.Context(style: p.Style.posix);

  @override
  Directory get systemTempDirectory => directory('/tmp');

  @override
  Directory get currentDirectory => directory('/');

  @override
  set currentDirectory(dynamic path) =>
      throw UnsupportedError('A mounted filesystem has no working directory.');

  @override
  Future<io.FileStat> stat(String path) {
    final at = resolve(path);
    return at.fs.stat(at.path);
  }

  @override
  io.FileStat statSync(String path) {
    final at = resolve(path);
    return at.fs.statSync(at.path);
  }

  @override
  Future<bool> identical(String path1, String path2) async =>
      identicalSync(path1, path2);

  @override
  bool identicalSync(String path1, String path2) {
    final first = resolve(path1);
    final second = resolve(path2);
    // Two paths in different mounts are never the same file. (Compared
    // with `==` rather than `identical`, which in here means this class's
    // own method - filesystems don't define equality, so it is the same
    // question.)
    if (first.fs != second.fs) return false;
    return first.fs.identicalSync(first.path, second.path);
  }

  @override
  bool get isWatchSupported => false;

  @override
  Future<FileSystemEntityType> type(String path, {bool followLinks = true}) {
    final at = resolve(path);
    return at.fs.type(at.path, followLinks: followLinks);
  }

  @override
  FileSystemEntityType typeSync(String path, {bool followLinks = true}) {
    final at = resolve(path);
    return at.fs.typeSync(at.path, followLinks: followLinks);
  }
}
