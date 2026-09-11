import 'package:tempo_core/tempo_core.dart';
import 'package:file/memory.dart';
import 'package:flutter_test/flutter_test.dart';

/// Where the browser thinks it is has to follow the path, not the button
/// that was pressed: a namespace with mounts in it is exactly where that
/// distinction bites.
void main() {
  final machine = MemoryFileSystem();
  final places = Places(fileSystem: machine, home: '/root');

  setUpAll(() {
    for (final folder in const ['/root/Music', '/mnt/sd/Podcasts', '/etc']) {
      machine.directory(folder).createSync(recursive: true);
    }
  });

  tearDown(() => FullFilesystem.enabled.value = false);

  test('a path belongs to the most specific place that holds it', () {
    expect(places.placeOf('/root'), Place.home);
    expect(places.placeOf('/root/Music'), Place.home);
    expect(places.placeOf('/mnt/sd'), Place.sdCard);
    expect(places.placeOf('/mnt/sd/Podcasts'), Place.sdCard);

    // Neither: the machine itself, which is what root means.
    expect(places.placeOf('/etc'), Place.root);
    expect(places.placeOf('/'), Place.root);
    expect(places.placeOf('/mnt'), Place.root);

    // And a path that only looks like one of them.
    expect(places.placeOf('/rootless'), Place.root);
  });

  test('owned data can move without moving home or media roots', () {
    final cardData = Places(
      fileSystem: machine,
      home: '/root',
      data: '/mnt/sd/.tempo',
      config: '/mnt/sd/.tempo/config',
    );
    expect(cardData.pathOf(Place.home), '/root');
    expect(cardData.pathOf(Place.sdCard), '/mnt/sd');
    expect(cardData.placeOf('/mnt/sd/Music'), Place.sdCard);
    expect(cardData.config, '/mnt/sd/.tempo/config');
    expect(
      AppletStore(cardData).fileFor('/apps/files')!.path,
      '/mnt/sd/.tempo/applets/apps.files.json',
    );
    expect(places.data, '/root/.local/share/tempo');
  });

  test('the root is offered only when it has been asked for', () {
    expect(FullFilesystem.placesFor(true), [Place.home, Place.sdCard]);
    expect(FullFilesystem.placesFor(false), [Place.home]);

    FullFilesystem.enabled.value = true;
    expect(FullFilesystem.placesFor(true), [
      Place.home,
      Place.sdCard,
      Place.root,
    ]);
  });
}
