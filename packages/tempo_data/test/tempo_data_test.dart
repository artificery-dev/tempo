import 'dart:convert';
import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:tempo_data/tempo_data.dart';
import 'package:test/test.dart';

void main() {
  late MemoryFileSystem fs;
  const selector = '/home/u/.local/state/tempo/storage-selector.json';
  bool readOnly = false;
  TempoStorageManager manager({
    Future<void> Function(String)? checkpoint,
    String? card = '/card',
  }) => TempoStorageManager(
    fs: fs,
    devicePaths: TempoProfilePaths.device(
      fs,
      home: '/home/u',
      configHome: '/home/u/.config',
    ),
    selectorPath: selector,
    cardRoot: card,
    checkpoint: checkpoint,
  );
  void write(String path, String text) {
    fs.file(path).parent.createSync(recursive: true);
    fs.file(path).writeAsStringSync(text);
  }

  setUp(() {
    readOnly = false;
    fs = MemoryFileSystem.test(
      opHandle: (path, operation) {
        if (readOnly &&
            path.startsWith('/card/') &&
            operation == FileSystemOp.create)
          throw FileSystemException('Read-only filesystem', path);
      },
    );
    fs.directory('/card').createSync();
    write('/home/u/.tempo/library.db', 'closed sqlite');
    write('/home/u/.tempo/applets/foo/state.json', 'applet');
    write('/home/u/.config/tempo/settings.json', 'settings');
    write('/home/u/.config/tempo/wallpaper.jpg', 'wallpaper');
    write('/card/Music/song.mp3', 'media');
  });
  test(
    'ask default, No once unchanged, dont-ask no and existing SD adoption',
    () async {
      final m = manager();
      expect((await m.resolveStartup()).activePaths!.data, '/home/u/.tempo');
      expect((await m.resolveStartup()).needsPrompt, false);
      write('/card/.tempo/library.db', 'existing');
      expect((await m.resolveStartup()).needsPrompt, true);
      expect(m.readSelector(), TempoStoragePolicy.ask);
      await m.setPolicy(TempoStoragePolicy.no);
      expect((await m.resolveStartup()).needsPrompt, false);
      await m.acceptExistingSd();
      expect(
        (await m.resolveStartup()).activePaths!.config,
        '/card/.tempo/config',
      );
      expect(fs.file('/card/.tempo/library.db').readAsStringSync(), 'existing');
    },
  );
  test('selected absent SD never opens stale device profile', () async {
    await manager().setPolicy(TempoStoragePolicy.yes);
    final result = await manager(card: null).resolveStartup();
    expect(result.activePaths, isNull);
    expect(result.sdAvailable, false);
  });
  test(
    'roundtrip config, db, applets, wallpaper; media and selector excluded',
    () async {
      final m = manager();
      await m.switchToSd();
      expect(
        fs.file('/card/.tempo/applets/foo/state.json').readAsStringSync(),
        'applet',
      );
      expect(
        fs.file('/card/.tempo/config/wallpaper.jpg').readAsStringSync(),
        'wallpaper',
      );
      write('/card/.tempo/library.db', 'new');
      write('/card/.tempo/config/settings.json', 'new settings');
      await expectLater(
        m.switchToDevice(),
        throwsA(isA<TempoProfileConflict>()),
      );
      await m.switchToDevice(replaceExisting: true);
      expect(fs.file('/home/u/.tempo/library.db').readAsStringSync(), 'new');
      expect(
        fs.file('/home/u/.config/tempo/settings.json').readAsStringSync(),
        'new settings',
      );
      expect(fs.directory('/home/u/.tempo/config').existsSync(), false);
      expect(fs.file('/card/Music/song.mp3').readAsStringSync(), 'media');
      expect(
        fs
            .directory('/card/.tempo')
            .listSync(recursive: true)
            .any((p) => p.path.contains('selector')),
        false,
      );
      expect(m.readSelector(), TempoStoragePolicy.no);
    },
  );
  test('existing SD refuses implicit overwrite', () async {
    write('/card/.tempo/library.db', 'existing');
    await expectLater(
      manager().switchToSd(),
      throwsA(isA<TempoProfileConflict>()),
    );
    await manager().switchToSd(adoptExisting: true);
    expect(fs.file('/card/.tempo/library.db').readAsStringSync(), 'existing');
  });
  test('prepare only persists intent; failed restart clears it', () async {
    final m = manager();
    final r = await m.prepareRequest(
      const TempoStorageRequest(policy: TempoStoragePolicy.yes),
    );
    expect(r.id, isNotNull);
    expect(m.readSelector(), TempoStoragePolicy.ask);
    expect(fs.directory('/card/.tempo').existsSync(), false);
    await m.clearPendingRequest();
    expect(m.readPendingRequest(), isNull);
  });
  for (final phase in [
    'preparing',
    'prepared',
    'published:0',
    'selected',
    'request-applied',
  ]) {
    test('process interruption at $phase recovers once', () async {
      await manager().prepareRequest(
        const TempoStorageRequest(policy: TempoStoragePolicy.yes),
      );
      await expectLater(
        manager(
          checkpoint: (p) async {
            if (p == phase) throw StateError('crash');
          },
        ).applyPendingAtStartup(),
        throwsStateError,
      );
      final m = manager();
      expect(
        (await m.applyPendingAtStartup()).activePaths!.data,
        '/card/.tempo',
      );
      expect(m.readPendingRequest(), isNull);
      expect(fs.file('$selector.transaction').existsSync(), false);
      expect(
        fs.file('/card/.tempo/library.db').readAsStringSync(),
        'closed sqlite',
      );
      expect(
        fs.file('/home/u/.tempo/library.db').readAsStringSync(),
        'closed sqlite',
      );
    });
  }
  test('two-root replacement recovers after only data was published', () async {
    await manager().switchToSd();
    write('/card/.tempo/library.db', 'new');
    write('/card/.tempo/config/wallpaper.jpg', 'new wall');
    await manager().prepareRequest(
      const TempoStorageRequest(
        policy: TempoStoragePolicy.ask,
        replaceExisting: true,
      ),
    );
    await expectLater(
      manager(
        checkpoint: (p) async {
          if (p == 'published:0') throw StateError('crash');
        },
      ).applyPendingAtStartup(),
      throwsStateError,
    );
    expect(
      (await manager().applyPendingAtStartup()).policy,
      TempoStoragePolicy.ask,
    );
    expect(fs.file('/home/u/.tempo/library.db').readAsStringSync(), 'new');
    expect(
      fs.file('/home/u/.config/tempo/wallpaper.jpg').readAsStringSync(),
      'new wall',
    );
  });
  test('corrupt stage refuses selection and retains recovery', () async {
    await expectLater(
      manager(
        checkpoint: (p) async {
          if (p == 'prepared') throw StateError('crash');
        },
      ).switchToSd(),
      throwsStateError,
    );
    final j =
        jsonDecode(fs.file('$selector.transaction').readAsStringSync()) as Map;
    write('${j['entries'][0]['stage']}/library.db', 'corrupt');
    await expectLater(
      manager().recover(),
      throwsA(isA<TempoProfileConflict>()),
    );
    expect(manager().readSelector(), TempoStoragePolicy.ask);
    expect(fs.file('$selector.transaction').existsSync(), true);
  });
  test(
    'read-only card failure leaves source and selection; incomplete staging recovers',
    () async {
      readOnly = true;
      await expectLater(
        manager().switchToSd(),
        throwsA(isA<FileSystemException>()),
      );
      expect(manager().readSelector(), TempoStoragePolicy.ask);
      expect(
        fs.file('/home/u/.tempo/library.db').readAsStringSync(),
        'closed sqlite',
      );
      readOnly = false;
      await manager().recover();
      expect(fs.file('$selector.transaction').existsSync(), false);
    },
  );
  test('symlinks and overlapping selector are rejected', () async {
    fs.link('/home/u/.tempo/alias').createSync(selector);
    await expectLater(
      manager().switchToSd(),
      throwsA(isA<TempoProfileConflict>()),
    );
    expect(
      () => TempoStorageManager(
        fs: fs,
        devicePaths: TempoProfilePaths(data: '/data', config: '/config'),
        selectorPath: '/config/selector',
      ),
      throwsArgumentError,
    );
  });
  test('journal path tampering cannot delete media', () async {
    write(
      '$selector.transaction',
      jsonEncode({
        'version': 1,
        'phase': 'preparing',
        'policy': 'yes',
        'entries': [
          {
            'target': '/card/.tempo',
            'stage': '/card/Music',
            'backup': '/card/.tempo.backup-1',
          },
        ],
      }),
    );
    await expectLater(manager().recover(), throwsFormatException);
    expect(fs.file('/card/Music/song.mp3').existsSync(), true);
  });
  test(
    'pending can be replaced before migration but invalid replacement preserves it',
    () async {
      final m = manager();
      final r = await m.prepareRequest(
        const TempoStorageRequest(policy: TempoStoragePolicy.yes),
      );
      await expectLater(
        m.prepareRequest(
          const TempoStorageRequest(
            policy: TempoStoragePolicy.yes,
            adoptExisting: true,
          ),
          replacePending: true,
        ),
        throwsStateError,
      );
      expect(m.readPendingRequest()!.id, r.id);
      await m.prepareRequest(
        const TempoStorageRequest(policy: TempoStoragePolicy.no),
        replacePending: true,
      );
      expect((await m.applyPendingAtStartup()).policy, TempoStoragePolicy.no);
    },
  );
  test('replacement recovers after backup rename before publication', () async {
    await manager().switchToSd();
    write('/card/.tempo/library.db', 'new');
    await manager().prepareRequest(
      const TempoStorageRequest(
        policy: TempoStoragePolicy.no,
        replaceExisting: true,
      ),
    );
    await expectLater(
      manager(
        checkpoint: (p) async {
          if (p == 'backed-up:0') throw StateError('crash');
        },
      ).applyPendingAtStartup(),
      throwsStateError,
    );
    expect(fs.directory('/home/u/.tempo').existsSync(), false);
    await manager().applyPendingAtStartup();
    expect(fs.file('/home/u/.tempo/library.db').readAsStringSync(), 'new');
  });
  test(
    'Windows namespace copy and selector remain filesystem-independent',
    () async {
      final win = MemoryFileSystem.test(style: FileSystemStyle.windows);
      final paths = TempoProfilePaths.device(
        win,
        home: r'C:\Users\tempo',
        configHome: r'C:\Users\tempo\config',
      );
      win.directory(r'D:\').createSync(recursive: true);
      win.directory(paths.data).createSync(recursive: true);
      win
          .file(win.path.join(paths.data, 'library.db'))
          .writeAsStringSync('windows profile');
      win.directory(paths.config).createSync(recursive: true);
      win
          .file(win.path.join(paths.config, 'settings.json'))
          .writeAsStringSync('{}');
      final m = TempoStorageManager(
        fs: win,
        devicePaths: paths,
        selectorPath: TempoStorageManager.defaultSelectorPath(
          win,
          r'C:\Users\tempo',
        ),
        cardRoot: r'D:\',
      );
      await m.switchToSd();
      expect(
        win.file(r'D:\.tempo\library.db').readAsStringSync(),
        'windows profile',
      );
      expect((await m.resolveStartup()).location, TempoStorageLocation.sd);
    },
  );
}
