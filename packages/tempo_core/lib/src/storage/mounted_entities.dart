import 'dart:io' as io;

import 'package:file/file.dart';

import 'mounted_file_system.dart';

/// The shared half of a mounted entity: it knows its *outer* path, and
/// finds the delegate that path lands on whenever it is asked to do
/// anything.
abstract class _Mounted<
  T extends FileSystemEntity,
  D extends io.FileSystemEntity
>
    extends ForwardingFileSystemEntity<T, D> {
  _Mounted(this.fileSystem, this.path);

  @override
  final MountedFileSystem fileSystem;

  @override
  final String path;

  @override
  String get dirname => fileSystem.path.dirname(path);

  @override
  String get basename => fileSystem.path.basename(path);

  @override
  Uri get uri => Uri.file(path);

  @override
  bool get isAbsolute => true;

  @override
  T get absolute => wrap(delegate);

  /// The entity one level up, resolved afresh - which is what carries a
  /// walk up out of a mount and into the filesystem the mount sits in.
  @override
  Directory get parent => fileSystem.directory(dirname);

  /// Where a delegate's path comes back to in the outer namespace.
  String _outer(io.FileSystemEntity delegate) {
    final fs = delegate is FileSystemEntity ? delegate.fileSystem : null;
    final mount = fs == null ? '' : fileSystem.mountOf(fs, path: delegate.path);
    return fileSystem.outerPath(mount, delegate.path);
  }

  @override
  Directory wrapDirectory(io.Directory delegate) =>
      MountedDirectory(fileSystem, _outer(delegate));

  @override
  File wrapFile(io.File delegate) => MountedFile(fileSystem, _outer(delegate));

  @override
  Link wrapLink(io.Link delegate) => MountedLink(fileSystem, _outer(delegate));

  String renameTarget(String target) {
    final source = fileSystem.resolve(path);
    final destination = fileSystem.resolve(target);
    if (source.mount != destination.mount ||
        !identical(source.fs, destination.fs)) {
      throw FileSystemException('Rename crosses a mounted filesystem', target);
    }
    return destination.path;
  }

  @override
  Future<String> resolveSymbolicLinks() async => path;

  @override
  String resolveSymbolicLinksSync() => path;
}

/// A directory somewhere in a [MountedFileSystem].
class MountedDirectory extends _Mounted<Directory, io.Directory>
    with ForwardingDirectory<Directory> {
  MountedDirectory(super.fileSystem, super.path);

  @override
  Future<Directory> rename(String newPath) async =>
      wrapDirectory(await delegate.rename(renameTarget(newPath)));
  @override
  Directory renameSync(String newPath) =>
      wrapDirectory(delegate.renameSync(renameTarget(newPath)));

  @override
  io.Directory get delegate {
    final at = fileSystem.resolve(path);
    return at.fs.directory(at.path);
  }

  @override
  Directory childDirectory(String basename) =>
      fileSystem.directory(fileSystem.path.join(path, basename));

  @override
  File childFile(String basename) =>
      fileSystem.file(fileSystem.path.join(path, basename));

  @override
  Link childLink(String basename) =>
      fileSystem.link(fileSystem.path.join(path, basename));
}

/// A file somewhere in a [MountedFileSystem].
class MountedFile extends _Mounted<File, io.File> with ForwardingFile {
  MountedFile(super.fileSystem, super.path);

  @override
  Future<File> rename(String newPath) async =>
      wrapFile(await delegate.rename(renameTarget(newPath)));
  @override
  File renameSync(String newPath) =>
      wrapFile(delegate.renameSync(renameTarget(newPath)));

  @override
  io.File get delegate {
    final at = fileSystem.resolve(path);
    return at.fs.file(at.path);
  }
}

/// A link somewhere in a [MountedFileSystem].
class MountedLink extends _Mounted<Link, io.Link> with ForwardingLink {
  MountedLink(super.fileSystem, super.path);

  @override
  Future<Link> rename(String newPath) async =>
      wrapLink(await delegate.rename(renameTarget(newPath)));
  @override
  Link renameSync(String newPath) =>
      wrapLink(delegate.renameSync(renameTarget(newPath)));

  @override
  io.Link get delegate {
    final at = fileSystem.resolve(path);
    return at.fs.link(at.path);
  }
}
