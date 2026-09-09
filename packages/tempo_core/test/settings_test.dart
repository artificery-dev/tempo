import 'dart:async';
import 'package:file/memory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tomeui/tomeui.dart';

/// Settings are data with an announcement: the tree says what they are,
/// the store says what they are at, and every write goes out as a change
/// that something else - never the store - forwards to the machine.
void main() {
  const tree = SettingNode.group(
    id: 'settings',
    label: 'Settings',
    children: [
      SettingNode.toggle(
        id: 'switch',
        label: 'A Switch',
        bind: 'thing.switch',
        defaultValue: true,
      ),
      SettingNode.slider(
        id: 'level',
        label: 'A Level',
        bind: 'thing.level',
        defaultValue: 50,
        min: 0,
        max: 100,
        step: 5,
      ),
      SettingNode.toggle(
        id: 'unbound',
        label: 'Answered by Nobody',
        bind: 'thing.nobody',
        defaultValue: false,
      ),
      SettingNode.toggle(
        id: 'stored-only',
        label: 'Only Stored',
        defaultValue: false,
      ),
      SettingNode.toggle(
        id: 'gated',
        label: 'Gated',
        defaultValue: true,
        when: SettingCondition(path: '/settings/switch', value: true),
      ),
      SettingNode.aliasOf(
        id: 'same-switch',
        label: 'The Switch Again',
        alias: '/settings/switch',
      ),
      SettingNode.toggle(
        id: 'radio',
        label: 'Needs a Radio',
        defaultValue: false,
        needs: {'wifi'},
      ),
    ],
  );

  late Settings settings;

  setUp(() => settings = Settings(tree: SettingsTree(tree)));
  tearDown(() {
    settings.dispose();
    SettingBindings.clear();
  });

  test(
    'remote persistence serializes writes and never touches local settings',
    () async {
      final disk = MemoryFileSystem();
      final pending = Completer<void>();
      final writes = <Map<String, Object?>>[];
      final file = SettingsFile(
        settings: settings,
        file: disk.file('/settings.json'),
        readRemote: () async => {'/settings/level': 30},
        writeRemote: (snapshot) async {
          writes.add(snapshot);
          if (writes.length == 1) await pending.future;
        },
      );
      await file.load();
      expect(settings.readInt('/settings/level'), 30);
      settings.set('/settings/level', 35);
      final first = file.save();
      settings.set('/settings/level', 40);
      final second = file.save();
      await Future<void>.delayed(Duration.zero);
      expect(writes, [
        {'/settings/level': 35},
      ]);
      pending.complete();
      await Future.wait([first, second]);
      expect(writes.last, {'/settings/level': 40});
      expect(file.file.existsSync(), isFalse);
      file.dispose();
    },
  );

  group('what a setting is worth', () {
    test('a setting nobody has moved is its default', () {
      expect(settings.value('/settings/switch'), isTrue);
      expect(settings.value('/settings/level'), 50);
      expect(settings.stored, isEmpty, reason: 'nothing to write yet');
    });

    test('a value equal to the default is not stored: the file is what a '
        'user changed, not a copy of the tree', () {
      settings.set('/settings/switch', false);
      expect(settings.stored, {'/settings/switch': false});

      settings.set('/settings/switch', true);
      expect(settings.stored, isEmpty);
      expect(settings.value('/settings/switch'), isTrue);
    });

    test('a stored value of the wrong shape reads as the default rather '
        'than throwing into a screen', () {
      settings.restore({'/settings/level': 'not a number'});
      expect(settings.readInt('/settings/level'), 50);
    });

    test('an alias is the same value, under another name', () {
      settings.set('/settings/same-switch', false);
      expect(settings.value('/settings/switch'), isFalse);
      expect(settings.stored.keys, [
        '/settings/switch',
      ], reason: 'stored once, at the real path');
    });
  });

  group('the announcement', () {
    test('every move goes out as a change, with where it came from', () {
      final seen = <SettingChange>[];
      settings.changes.listen(seen.add);

      settings.set('/settings/switch', false);
      settings.set('/settings/level', 75, source: SettingSource.quick);

      expect(seen.map((change) => change.path), [
        '/settings/switch',
        '/settings/level',
      ]);
      expect(seen.first.from, isTrue);
      expect(seen.first.to, isFalse);
      expect(seen.first.source, SettingSource.settings);
      expect(seen.last.source, SettingSource.quick);
      expect(seen.last.bind, 'thing.level');
    });

    test('a move to where it already is says nothing', () {
      final seen = <SettingChange>[];
      settings.changes.listen(seen.add);
      settings.set('/settings/switch', true);
      expect(seen, isEmpty);
    });

    test('it is synchronous: a listener has seen it before set returns', () {
      Object? seen;
      settings.changes.listen((change) => seen = change.to);
      settings.set('/settings/switch', false);
      expect(seen, isFalse, reason: 'not a frame later');
    });

    test('one setting can be watched on its own', () {
      final watched = settings.listen('/settings/level');
      final seen = <Object?>[];
      watched.addListener(() => seen.add(watched.value));

      settings.set('/settings/level', 60);
      settings.set('/settings/switch', false);
      expect(seen, [60], reason: 'only its own');
    });
  });

  group('the bridge', () {
    test('forwards a change to whatever answers its bind key', () {
      final moved = <String, Object?>{};
      SettingBindings.register(
        'thing.switch',
        (change) => moved['switch'] = change.to,
      );
      SettingsBridge(settings: settings).attach();

      settings.set('/settings/switch', false);
      expect(moved, {'switch': false});
    });

    test('a bind key nobody answers is kept, not thrown', () {
      final bridge = SettingsBridge(settings: settings)..attach();
      settings.set('/settings/unbound', true);
      expect(bridge.unanswered.single.path, '/settings/unbound');
    });

    test('a setting with no bind at all is not unanswered: being stored '
        'is the whole of what it does', () {
      final bridge = SettingsBridge(settings: settings)..attach();
      settings.set('/settings/stored-only', true);
      expect(bridge.unanswered, isEmpty);
      expect(settings.value('/settings/stored-only'), isTrue);
    });

    test('applyAll pushes what the file said out to the machine, once '
        'each', () {
      final applied = <String, Object?>{};
      SettingBindings.registerAll({
        'thing.switch': (change) => applied[change.path] = change.to,
        'thing.level': (change) => applied[change.path] = change.to,
      });
      settings.restore({'/settings/level': 20});

      final bridge = SettingsBridge(settings: settings)..applyAll();
      expect(applied, {'/settings/switch': true, '/settings/level': 20});
      expect(bridge.unanswered, isEmpty);
    });

    test('detaching stops the forwarding', () {
      final moved = <Object?>[];
      SettingBindings.register(
        'thing.switch',
        (change) => moved.add(change.to),
      );
      final bridge = SettingsBridge(settings: settings)..attach();

      settings.set('/settings/switch', false);
      bridge.detach();
      settings.set('/settings/switch', true);
      expect(moved, [false]);
    });
  });

  group('what a row may do', () {
    test('a setting whose `when` does not hold is disabled', () {
      expect(settings.enabled('/settings/gated'), isTrue);
      settings.set('/settings/switch', false);
      expect(settings.enabled('/settings/gated'), isFalse);
    });

    test('a setting whose bind nobody answers is disabled', () {
      SettingBindings.register('thing.switch', (_) {});
      final bound = SettingBindings.keys;
      expect(settings.enabled('/settings/switch', bound: bound), isTrue);
      expect(settings.enabled('/settings/unbound', bound: bound), isFalse);
      expect(
        settings.enabled('/settings/stored-only', bound: bound),
        isTrue,
        reason: 'nothing to answer: storing it is what it does',
      );
    });

    test('a setting whose capability is missing is not shown at all', () {
      expect(settings.visible('/settings/radio'), isFalse);
      expect(settings.visible('/settings/radio', available: {'wifi'}), isTrue);
      expect(settings.visible('/settings/switch'), isTrue);
    });
  });

  group('the file', () {
    late MemoryFileSystem machine;
    late SettingsFile file;

    setUp(() {
      machine = MemoryFileSystem();
      file = SettingsFile(
        settings: settings,
        file: machine.file('/home/tempo/.config/tempo/settings.json'),
      );
    });

    test('writes only what was moved, sorted by path', () async {
      settings.set('/settings/level', 30);
      settings.set('/settings/switch', false);
      await file.save();

      expect(
        machine
            .file('/home/tempo/.config/tempo/settings.json')
            .readAsStringSync(),
        '{\n'
        '  "/settings/level": 30,\n'
        '  "/settings/switch": false\n'
        '}',
      );
    });

    test('reads what was saved and announces it, so the machine catches '
        'up with the file', () async {
      machine.file('/home/tempo/.config/tempo/settings.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{"/settings/level": 15}');

      final seen = <SettingChange>[];
      settings.changes.listen(seen.add);
      await file.load();

      expect(settings.value('/settings/level'), 15);
      expect(seen.single.source, SettingSource.restore);
    });

    test('a broken file is a convenience lost, not a broken player', () async {
      machine.file('/home/tempo/.config/tempo/settings.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{not json at all');

      await file.load();
      expect(settings.value('/settings/level'), 50, reason: 'the default');
    });

    test('a value for a path this tree does not have is kept, not thrown '
        'away', () async {
      machine.file('/home/tempo/.config/tempo/settings.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{"/settings/from-a-later-build": 7}');

      await file.load();
      await file.save();
      expect(
        machine
            .file('/home/tempo/.config/tempo/settings.json')
            .readAsStringSync(),
        contains('from-a-later-build'),
      );
    });

    test('a change still waiting is written on the way out', () {
      file.watch();
      settings.set('/settings/level', 40);
      // The settle timer has not fired; disposing writes anyway.
      file.dispose();
      expect(
        machine.file('/home/tempo/.config/tempo/settings.json').existsSync(),
        isTrue,
      );
    });
  });

  group('the shipped tree', () {
    test(
      'sections separate storage and power while grouping related controls',
      () {
        final tree = playerSettingsTree;
        expect(
          tree.root.children
              .where((node) => node.kind == SettingKind.group)
              .map((node) => node.label),
          [
            'Sound',
            'Playback',
            'Library',
            'Appearance',
            'Controls',
            'Display',
            'Power',
            'Connections',
            'Storage',
            'Apps & Extensions',
            'System',
          ],
        );
        for (final (path, binding) in [
          ('/settings/appearance/home/clock', 'home.clock'),
          ('/settings/controls/navigation/remember', 'menu.remember'),
          ('/settings/controls/navigation/dock/pins', 'dock.pins'),
          ('/settings/controls/navigation/quick/pins', 'quick.pins'),
          ('/settings/controls/feedback/level', 'feedback.level'),
          ('/settings/controls/feedback/follow', 'feedback.follow'),
          ('/settings/sound/gain', 'playback.gain'),
          ('/settings/connections/wifi/enabled', 'wifi.enabled'),
          ('/settings/connections/bluetooth/enabled', 'bluetooth.enabled'),
          ('/settings/connections/usb/mode', 'usb.mode'),
          ('/settings/connections/samba/enabled', 'samba.enabled'),
          ('/settings/connections/mpd/enabled', 'mpd.enabled'),
          ('/settings/system/time/zone', 'time.zone'),
          (
            '/settings/system/developer/full-filesystem',
            'files.fullFilesystem',
          ),
          ('/settings/system/developer/frame-counter', 'debug.frameCounter'),
          ('/settings/system/privacy/pin/enabled', 'pin.enabled'),
          ('/settings/controls/dark-wheel', 'dark.wheel'),
        ]) {
          expect(tree.at(path)?.node.bind, binding, reason: path);
        }
        expect(tree.at('/settings/system/about')?.node.screen, 'about');
        expect(tree.at('/settings/system/developer/dock'), isNull);
        expect(tree.at('/settings/storage/full-filesystem'), isNull);
      },
    );

    test('indexes without a collision, and every path is its ancestry', () {
      final tree = playerSettingsTree;
      expect(tree.entries.length, greaterThan(200));
      for (final entry in tree.entries) {
        expect(entry.path.endsWith('/${entry.id}'), isTrue);
      }
    });

    test('every `when` and every alias points at something real', () {
      final tree = playerSettingsTree;
      for (final entry in tree.entries) {
        final when = entry.node.when;
        if (when != null) {
          expect(tree.at(when.path), isNotNull, reason: '${entry.path} when');
        }
        final alias = entry.node.alias;
        if (alias != null) {
          expect(tree.at(alias), isNotNull, reason: '${entry.path} alias');
        }
      }
    });

    test('every setting has a default, and every choice its answers', () {
      for (final entry in playerSettingsTree.settings) {
        final node = entry.node;
        if (node.kind == SettingKind.screen) {
          expect(node.defaultValue, isNotNull, reason: entry.path);
          expect(node.screen, isNotNull, reason: entry.path);
        } else {
          expect(node.control, isNotNull, reason: entry.path);
        }
        if (node.control == SettingControl.toggle) {
          expect(node.defaultValue, isA<bool>(), reason: entry.path);
        }
        if (node.control == SettingControl.choice) {
          expect(node.options, isNotEmpty, reason: entry.path);
          expect(
            node.options.map((option) => option.value),
            contains(node.defaultValue),
            reason: '${entry.path}: the default is not on offer',
          );
        }
      }
    });

    test('round-trips through JSON: the shape a later source hands back', () {
      final json = settingsRoot.toJson();
      expect(json['id'], 'settings');
      expect(json['children'], isA<List<Object?>>());
    });

    test('the player answers the settings it can, and says so', () {
      final services = PlayerServices(
        battery: ValueNotifier(const BatteryReading(percent: 50)),
        wifi: ValueNotifier(WifiReading.off),
        bluetooth: ValueNotifier(BluetoothReading.off),
        storage: ValueNotifier(const StorageReading(present: false)),
        places: ValueNotifier(
          Places(fileSystem: MemoryFileSystem(), home: '/home/tempo'),
        ),
        screen: ScreenSwitch(),
        volume: VolumeSwitch(),
        output: OutputSwitch(),
        feedback: FeedbackSwitch(),
      );
      SettingBindings.registerAll(PlayerSettings.sinks(services));
      SettingBindings.registerActions(PlayerSettings.actions(services));

      // The ones that move something today.
      expect(SettingBindings.knows('appearance.mode'), isTrue);
      expect(SettingBindings.knows('screen.brightness'), isTrue);
      expect(SettingBindings.knows('sleep.after'), isTrue);
      expect(SettingBindings.knows('library.scan'), isTrue);
      expect(SettingBindings.knows('time.zone'), isTrue);
      expect(SettingBindings.knows('time.hour'), isTrue);
      // The wallpaper group. A page whose bind key nobody answers is drawn
      // disabled, so the picker not being reachable was exactly this.
      expect(SettingBindings.knows('wallpaper.image'), isTrue);
      expect(SettingBindings.knows('wallpaper.tint'), isTrue);
      expect(SettingBindings.knows('wallpaper.glass'), isTrue);
      expect(SettingBindings.knows('wallpaper.autoPalette'), isTrue);
      // And the ones that cannot yet.
      expect(SettingBindings.knows('wifi.enabled'), isFalse);
      expect(SettingBindings.knows('tone.eq'), isFalse);
      expect(SettingBindings.knows('update.check'), isFalse);
      // Nothing on the player shows a date, so there is nothing for these
      // to format: they stay disabled rather than moving a value nobody
      // reads.
      expect(SettingBindings.knows('time.date'), isFalse);
      expect(SettingBindings.knows('time.week'), isFalse);
    });

    test('the clock format setting reaches every clock', () {
      addTearDown(() => ClockFormat.hour24.value = true);
      final services = PlayerServices(
        battery: ValueNotifier(const BatteryReading(percent: 50)),
        wifi: ValueNotifier(WifiReading.off),
        bluetooth: ValueNotifier(BluetoothReading.off),
        storage: ValueNotifier(const StorageReading(present: false)),
        places: ValueNotifier(
          Places(fileSystem: MemoryFileSystem(), home: '/home/tempo'),
        ),
        screen: ScreenSwitch(),
        volume: VolumeSwitch(),
        output: OutputSwitch(),
        feedback: FeedbackSwitch(),
      );
      final settings = Settings(tree: playerSettingsTree);
      SettingBindings.registerAll(PlayerSettings.sinks(services));
      final bridge = SettingsBridge(settings: settings)..attach();
      addTearDown(bridge.detach);

      settings.set('/settings/system/time/hour', 12);
      expect(ClockFormat.hour24.value, isFalse);
      settings.set('/settings/system/time/hour', 24);
      expect(ClockFormat.hour24.value, isTrue);
    });
  });

  group('the player\'s far end', () {
    late PlayerServices services;
    late Settings store;

    setUp(() {
      services = PlayerServices(
        battery: ValueNotifier(const BatteryReading(percent: 50)),
        wifi: ValueNotifier(WifiReading.off),
        bluetooth: ValueNotifier(BluetoothReading.off),
        storage: ValueNotifier(const StorageReading(present: false)),
        places: ValueNotifier(
          Places(fileSystem: MemoryFileSystem(), home: '/home/tempo'),
        ),
        screen: ScreenSwitch(),
        volume: VolumeSwitch(),
        output: OutputSwitch(),
        feedback: FeedbackSwitch(),
      );
      store = Settings(tree: playerSettingsTree);
      PlayerSettings.install(store, services: services);
    });

    tearDown(() {
      store.dispose();
      Appearance.mode.value = AppearanceMode.dark;
      Appearance.scale.value = UiScale.regular;
      ScreenSleep.after.value = const Duration(seconds: 30);
      ScreenSleep.dimAfter.value = const Duration(seconds: 15);
    });

    test('the theme follows the setting', () {
      store.set('/settings/appearance/mode', 'light');
      expect(Appearance.mode.value, AppearanceMode.light);
      store.set('/settings/appearance/scale', 'large');
      expect(Appearance.scale.value, UiScale.large);
    });

    test('the sleep clock follows its two', () {
      store.set('/settings/display/sleep-after', 60000);
      expect(ScreenSleep.after.value, const Duration(minutes: 1));
      store.set('/settings/display/sleep-after', null);
      expect(ScreenSleep.after.value, isNull, reason: 'never');
      store.set('/settings/display/dim-after', 5000);
      expect(ScreenSleep.dimAfter.value, const Duration(seconds: 5));
      store.set('/settings/display/dim-after', null);
      expect(ScreenSleep.dimAfter.value, isNull, reason: 'never dims');
    });

    test('the backlight follows the brightness', () async {
      store.set('/settings/display/brightness', 35);
      await Future<void>.delayed(Duration.zero);
      expect(services.screen.brightness.value, 35);
    });

    test('the wheel\'s own noise follows its switches', () {
      store.set('/settings/controls/feedback/sounds', false);
      expect(services.feedback.sounds.value, isFalse);
    });

    test('a value the machine reported is not sent back to it', () async {
      store.set('/settings/sound/volume', 70, source: SettingSource.system);
      await Future<void>.delayed(Duration.zero);
      expect(
        services.volume.value.level,
        50,
        reason: 'the mixer already knows; sending it back would loop',
      );

      store.set('/settings/sound/volume', 30);
      await Future<void>.delayed(Duration.zero);
      expect(services.volume.value.level, 30);
    });
  });

  group('the wallpaper rows', () {
    test('the picker and the palette page are pages that exist', () {
      PlayerSettingScreens.install();
      for (final (path, key) in [
        ('/settings/appearance/wallpaper/image', 'wallpaper-picker'),
        ('/settings/appearance/wallpaper/auto-palette', 'wallpaper-palette'),
      ]) {
        final entry = playerSettingsTree.at(path);
        expect(entry, isNotNull, reason: '$path is not in the tree');
        expect(entry!.node.screen, key);
        expect(
          SettingScreens.knows(key),
          isTrue,
          reason: '$key is named by the tree but nobody registered it',
        );
      }
    });

    test('the tint and the glass sit under Size, not under Wallpaper', () {
      final appearance = playerSettingsTree.at('/settings/appearance')!;
      final ids = appearance.children.map((child) => child.node.id).toList();
      expect(ids, containsAllInOrder(['mode', 'scale', 'tint', 'glass']));
      expect(playerSettingsTree.at('/settings/appearance/tint'), isNotNull);
      expect(playerSettingsTree.at('/settings/appearance/glass'), isNotNull);
      expect(
        playerSettingsTree.at('/settings/appearance/wallpaper/tint'),
        isNull,
      );
    });
  });
}
