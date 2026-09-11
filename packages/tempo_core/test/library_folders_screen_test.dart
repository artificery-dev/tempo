import 'dart:io';
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
      hostMediaService(MediaDatabase(NativeDatabase.memory())),
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
    // Browsing folders is real work in a real filesystem, so the screen waits
    // on input/output that no fixed delay covers on a machine with other jobs
    // to run. Give that work real time between pumps and carry on once the
    // screen has stopped changing, rather than assuming it already has.
    Future<void> settle() async {
      var previous = <String?>[];
      var quiet = 0;
      // A generous budget: the failure it guards against is a hang, and the
      // loop ends as soon as the screen is quiet.
      for (var attempt = 0; attempt < 2000; attempt++) {
        await tester.pump(const Duration(milliseconds: 20));
        final texts = tester
            .widgetList<Text>(find.byType(Text))
            .map((text) => text.data)
            .toList();
        final unchanged =
            texts.length == previous.length &&
            List.generate(
              texts.length,
              (index) => texts[index] == previous[index],
            ).every((same) => same);
        if (unchanged && !tester.binding.hasScheduledFrame) {
          if (++quiet == 5) return;
        } else {
          quiet = 0;
        }
        previous = texts;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      fail('the screen never stopped changing: $previous');
    }

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
    await settle();
    wheel.jog(3); // Podcasts, after Audiobooks, Movies, Music
    wheel.press(WheelButton.select);
    await settle();
    expect(find.text('Add Folder'), findsOneWidget);
    wheel.press(WheelButton.select);
    await settle();
    wheel.press(WheelButton.select); // location
    await settle();
    wheel.jog(2); // Custom, below Use This Folder and Parent Folder
    wheel.press(WheelButton.select);
    await settle();
    wheel.press(WheelButton.select); // Use This Folder
    await settle();
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
