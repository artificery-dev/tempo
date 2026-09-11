import 'dart:convert';

import 'package:tempo_core/tempo_core.dart';
import 'package:file/memory.dart';
import 'package:flutter_test/flutter_test.dart';

/// An applet's state is a small JSON file in the player's home: what is
/// set is read back by the next applet of the same name, a damaged file is
/// a fresh start, and a store with no home keeps nothing past the session.
void main() {
  late MemoryFileSystem machine;
  late Places places;

  setUp(() {
    machine = MemoryFileSystem();
    machine.directory('/home/tempo').createSync(recursive: true);
    places = Places(fileSystem: machine, home: '/home/tempo');
  });

  test('state round-trips through the file after it settles', () async {
    final store = AppletStore(places);
    final files = systemMenu.at('/apps/files')!;
    final first = Applet(entry: files, store: store);
    expect(first.id, '/apps/files');
    expect(first.state.get<List<Object?>>('open'), isNull);

    first.state.set('open', ['/home/tempo/Music']);
    first.state.set('showHidden', true);
    expect(first.state.get<bool>('showHidden'), isTrue);
    // Not yet written: a run of changes writes once.
    final file = store.fileFor(files.path)!;
    expect(file.existsSync(), isFalse);
    // The write is debounced; asking for it is how to know it happened.
    first.state.flush();
    expect(file.existsSync(), isTrue);
    expect(file.path, '/home/tempo/.local/share/tempo/applets/apps.files.json');
    expect(jsonDecode(file.readAsStringSync()), {
      'open': ['/home/tempo/Music'],
      'showHidden': true,
    });

    // The next applet of the same name picks it up.
    final second = Applet(entry: files, store: store);
    expect(second.state.get<List<Object?>>('open'), ['/home/tempo/Music']);
    expect(second.state.get<bool>('showHidden'), isTrue);
    // Forgetting is a write too, and a wrong type is a null.
    second.state.set('showHidden', null);
    second.state.flush();
    expect(
      Applet(entry: files, store: store).state.get<bool>('showHidden'),
      isNull,
    );
    expect(second.state.get<int>('open'), isNull);
    first.dispose();
    second.dispose();
  });

  test('profile switching flushes pending applet changes immediately', () {
    final store = AppletStore(places);
    final state = store.open('/apps/files');
    state.set('open', ['/mnt/sd/Music']);
    expect(store.fileFor('/apps/files')!.existsSync(), isFalse);
    AppletState.flushForStorageChange();
    expect(store.open('/apps/files').get<List<Object?>>('open'), [
      '/mnt/sd/Music',
    ]);
  });

  test('a damaged file is a fresh start, and no home keeps nothing', () {
    final store = AppletStore(places);
    final file = store.fileFor('/apps')!;
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('{not json');
    final applet = Applet(entry: systemMenu.at('/apps')!, store: store);
    expect(applet.state.values, isEmpty);

    const nowhere = AppletStore.ephemeral();
    expect(nowhere.fileFor('/apps'), isNull);
    final ephemeral = Applet(entry: systemMenu.at('/apps')!, store: nowhere);
    ephemeral.state.set('x', 1);
    ephemeral.state.flush();
    expect(ephemeral.state.get<int>('x'), 1);
    expect(
      Applet(entry: systemMenu.at('/apps')!, store: nowhere).state.values,
      isEmpty,
    );
  });
}
