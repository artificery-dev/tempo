import 'dart:io';
import 'package:cadence_media/cadence_media.dart'
    show MediaClient, MediaDatabase;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tempo_core/src/settings/library_folders_screen.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

void main() {
  testWidgets('wheel chooses a podcast folder and settings remember it', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('tempo-folder-picker');
    Directory('${root.path}/Custom').createSync();
    final library = MediaLibrary.over(
      Future.value(MediaClient.direct(MediaDatabase(NativeDatabase.memory()))),
      roots: () => [],
      sectionRoots: (section) => [],
      locations: () => [root.path],
    );
    final settings = Settings(tree: playerSettingsTree);
    final base = PlayerServices.fallback;
    final services = PlayerServices(
      battery: base.battery,
      wifi: base.wifi,
      bluetooth: base.bluetooth,
      storage: base.storage,
      places: base.places,
      screen: base.screen,
      volume: base.volume,
      output: base.output,
      feedback: base.feedback,
      library: library,
    );
    final wheel = ClickWheelController();
    await tester.runAsync(() async {
      await library.libraryId;
    });
    await tester.pumpWidget(
      PlayerServicesScope(
        services: services,
        child: SettingsScope(
          settings: settings,
          child: TomeApp(
            builder: (context, child) =>
                ClickWheelInput(controller: wheel, child: child!),
            home: const LibraryFoldersScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    wheel.jog(3); // Podcasts, after Audiobooks, Movies, Music
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    expect(find.text('Add Folder'), findsOneWidget);
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      wheel.press(WheelButton.select); // location
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    wheel.jog(2); // Custom, below Use This Folder and Parent Folder
    await tester.runAsync(() async {
      wheel.press(WheelButton.select);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    wheel.press(WheelButton.select); // Use This Folder
    await tester.pumpAndSettle();
    expect(library.rootsFor(LibrarySection.podcasts), ['${root.path}/Custom']);
    final saved = settings.value(libraryFoldersPath);
    expect(saved, {
      'podcasts': ['${root.path}/Custom'],
    });
    library.configureFolders(null);
    library.configureFolders(saved);
    expect(library.rootsFor(LibrarySection.podcasts), ['${root.path}/Custom']);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(library.dispose);
    root.deleteSync(recursive: true);
  });
}
