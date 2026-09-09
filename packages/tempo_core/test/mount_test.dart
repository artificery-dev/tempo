import 'package:tempo_core/tempo_core.dart';
import 'package:file/memory.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a listing across a mount wears the outer path', () {
    final tree = MemoryFileSystem();
    tree.directory('/mnt').createSync(recursive: true);
    final card = MemoryFileSystem();
    for (final folder in const ['/Music', '/Podcasts']) {
      card.directory(folder).createSync();
    }

    final machine = MountedFileSystem(root: tree, mounts: {'/mnt/sd': card});

    expect(
      machine.directory('/mnt/sd').listSync().map((e) => e.path).toList()
        ..sort(),
      ['/mnt/sd/Music', '/mnt/sd/Podcasts'],
    );
    expect(machine.directory('/mnt/sd/Music').existsSync(), isTrue);
  });
}
