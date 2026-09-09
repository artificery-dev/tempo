import 'package:file/memory.dart';
import 'package:file/file.dart' show FileSystemException;
import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';

void main() {
  test('Windows host folders keep a POSIX emulated namespace', () {
    final host = MemoryFileSystem(style: FileSystemStyle.windows);
    host.directory(r'C:\users\player\Music').createSync(recursive: true);
    host.file(r'C:\users\player\Music\song.flac').writeAsStringSync('song');
    final machine = MountedFileSystem(
      root: MemoryFileSystem(),
      mounts: {'/mnt/sd': host},
      mountRoots: {'/mnt/sd': r'C:\users\player'},
    );
    expect(machine.file('/mnt/sd/Music/song.flac').readAsStringSync(), 'song');
    expect(
      machine.directory('/mnt/sd/Music').listSync().single.path,
      '/mnt/sd/Music/song.flac',
    );
    machine.file('/mnt/sd/Music/new.flac').writeAsStringSync('new');
    expect(
      host.file(r'C:\users\player\Music\new.flac').readAsStringSync(),
      'new',
    );
    expect(machine.directory('/mnt/sd/Music').parent.path, '/mnt/sd');
  });
  test('rooted mounts distinguish folders and reject escaping symlinks', () {
    final host = MemoryFileSystem();
    host.directory('/host/home').createSync(recursive: true);
    host.directory('/host/card').createSync(recursive: true);
    host.file('/host/home/settings').writeAsStringSync('settings');
    host.file('/host/card/song').writeAsStringSync('song');
    host.file('/outside').writeAsStringSync('private');
    host.link('/host/card/escape').createSync('/outside');
    final machine = MountedFileSystem(
      root: MemoryFileSystem(),
      mounts: {'/home/tempo': host, '/mnt/sd': host},
      mountRoots: {'/home/tempo': '/host/home', '/mnt/sd': '/host/card'},
    );
    expect(
      machine.directory('/home/tempo').listSync().single.path,
      '/home/tempo/settings',
    );
    expect(machine.file('/mnt/sd/song').readAsStringSync(), 'song');
    expect(
      () => machine.file('/mnt/sd/escape').readAsStringSync(),
      throwsA(isA<FileSystemException>()),
    );
  });
}
