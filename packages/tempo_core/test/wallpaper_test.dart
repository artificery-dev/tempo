import 'dart:io' as io;

import 'package:file/memory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tomeui/tomeui.dart';

/// The wallpaper is a file in the player's config folder, beside the rest
/// of what it is set to, and the swirl this package bundles is only the
/// default: found, it is shown; missing, the default is shown and - where
/// the player says so - written there as `wallpaper.jpg`, so from then on
/// it is a file like any the user might put in its place. One left in the
/// home by an older build is moved in on the first look.
void main() {
  late MemoryFileSystem machine;
  late PlayerServices services;

  /// Real image bytes, since what is written is decoded and painted: the
  /// default itself, off this package's disk.
  final swirl = io.File('assets/wallpaper.jpg').readAsBytesSync();

  setUp(() {
    machine = MemoryFileSystem();
    machine.directory('/home/tempo').createSync(recursive: true);
    // The player makes this itself when it writes; a test that starts by
    // putting a file there needs it already.
    machine.directory('/home/tempo/.config/tempo').createSync(recursive: true);
    services = PlayerServices(
      battery: ValueNotifier(const BatteryReading(percent: 50)),
      wifi: ValueNotifier(WifiReading.off),
      bluetooth: ValueNotifier(BluetoothReading.off),
      storage: ValueNotifier(const StorageReading(present: false)),
      places: ValueNotifier(Places(fileSystem: machine, home: '/home/tempo')),
      screen: ScreenSwitch(),
      volume: VolumeSwitch(),
      output: OutputSwitch(),
      feedback: FeedbackSwitch(),
    );
  });

  tearDown(() {
    WallpaperSource.installDefault = false;
    WallpaperSource.image.value = WallpaperSource.asset;
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      PlayerServicesScope(
        services: services,
        child: TomeApp(
          debugShowCheckedModeBanner: false,
          home: const Wallpaper(),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('the file in the config folder is the wallpaper', (tester) async {
    machine
        .file('/home/tempo/.config/tempo/wallpaper.jpg')
        .writeAsBytesSync(swirl);
    await pump(tester);

    final image = WallpaperSource.image.value;
    expect(image, isA<MemoryImage>());
    expect((image as MemoryImage).bytes, swirl);
    expect(
      tester.widget<Image>(find.byType(Image)).image,
      image,
      reason: 'and it is what is painted',
    );
  });

  testWidgets('the first kind found wins, in a fixed order', (tester) async {
    machine.file('/home/tempo/.config/tempo/wallpaper.bmp').writeAsBytesSync([
      1,
    ]);
    machine
        .file('/home/tempo/.config/tempo/wallpaper.png')
        .writeAsBytesSync(swirl);
    await pump(tester);
    expect((WallpaperSource.image.value as MemoryImage).bytes, swirl);
  });

  testWidgets('with none, the default shows and is left alone unless told', (
    tester,
  ) async {
    await pump(tester);
    expect(WallpaperSource.image.value, WallpaperSource.asset);
    expect(
      machine.file('/home/tempo/.config/tempo/wallpaper.jpg').existsSync(),
      isFalse,
    );
  });

  testWidgets('with none, the player writes the default into the config '
      'folder', (tester) async {
    WallpaperSource.installDefault = true;
    // The wallpaper's own look, which finds nothing, shows the default,
    // and writes it.
    final written = machine.file('/home/tempo/.config/tempo/wallpaper.jpg');
    await tester.runAsync(() async {
      await pump(tester);
      // Loading the packaged asset and writing it out is real work; wait for
      // the file rather than for a moment.
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (!written.existsSync()) {
        if (DateTime.now().isAfter(deadline)) {
          fail('the default was never written');
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    expect(WallpaperSource.image.value, WallpaperSource.asset);
    expect(written.existsSync(), isTrue);
    expect(written.readAsBytesSync(), swirl);

    // From then on it is a file, found like any other.
    await tester.runAsync(() => WallpaperSource.load(services.places.value));
    expect(WallpaperSource.image.value, isA<MemoryImage>());
  });
}
