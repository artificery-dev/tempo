import 'package:file/memory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';

/// Where the player looks for wallpapers, and what it makes of what it
/// finds: a folder to walk, not a list to scroll.
void main() {
  late MemoryFileSystem machine;
  late Places places;

  setUp(() {
    machine = MemoryFileSystem();
    places = Places(fileSystem: machine, home: '/home/tempo');
  });

  void put(String path) => machine.file(path).createSync(recursive: true);

  List<String> namesOf(List<WallpaperCandidate> found) =>
      found.map((c) => c.name).toList();

  test('the three folders it looks in, in order', () {
    expect(WallpaperLibrary.rootsIn(places), [
      '/mnt/sd/Wallpapers',
      '/home/tempo/Wallpapers',
      '/home/tempo/Pictures/Wallpapers',
    ]);
  });

  group('the top', () {
    test('shows all three roots as one folder', () {
      put('/mnt/sd/Wallpapers/card.jpg');
      put('/home/tempo/Wallpapers/home.png');
      put('/home/tempo/Pictures/Wallpapers/pictures.webp');
      expect(namesOf(WallpaperLibrary.top(places)), [
        'card',
        'home',
        'pictures',
      ]);
    });

    test('ignores what is not a picture', () {
      put('/home/tempo/Wallpapers/notes.txt');
      put('/home/tempo/Wallpapers/song.mp3');
      put('/home/tempo/Wallpapers/real.jpeg');
      expect(namesOf(WallpaperLibrary.top(places)), ['real']);
    });

    test('and what is hidden', () {
      put('/home/tempo/Wallpapers/.hidden.png');
      put('/home/tempo/Wallpapers/.git/config');
      put('/home/tempo/Wallpapers/shown.png');
      expect(namesOf(WallpaperLibrary.top(places)), ['shown']);
    });

    test('a folder that is not there is simply fewer to choose from', () {
      put('/home/tempo/Wallpapers/only.png');
      expect(WallpaperLibrary.top(places), hasLength(1));
    });

    test('nothing anywhere is an empty list, not a failure', () {
      expect(WallpaperLibrary.top(places), isEmpty);
    });

    test('the card wins a name the home also has', () {
      put('/mnt/sd/Wallpapers/dawn.jpg');
      put('/home/tempo/Wallpapers/dawn.png');
      final found = WallpaperLibrary.top(places);
      expect(found, hasLength(1));
      expect(found.single.path, '/mnt/sd/Wallpapers/dawn.jpg');
    });
  });

  group('folders', () {
    setUp(() {
      put('/mnt/sd/Wallpapers/loose.jpg');
      put('/mnt/sd/Wallpapers/Unsplash/one.jpg');
      put('/mnt/sd/Wallpapers/Unsplash/two.png');
      put('/mnt/sd/Wallpapers/Personal/Trips/three.jpg');
    });

    test('are offered rather than flattened away', () {
      final top = WallpaperLibrary.top(places);
      expect(namesOf(top), ['Personal', 'Unsplash', 'loose']);
      // Folders first, then pictures - each alphabetical.
      expect(top.first.isFolder, isTrue);
      expect(top.last.isFolder, isFalse);
      // The pictures inside are not at the top.
      expect(namesOf(top), isNot(contains('one')));
    });

    test('open to what is inside them', () {
      final unsplash = WallpaperLibrary.top(
        places,
      ).firstWhere((c) => c.name == 'Unsplash');
      expect(namesOf(WallpaperLibrary.inside(places, unsplash.path)), [
        'one',
        'two',
      ]);
    });

    test('and nest as deep as they are nested', () {
      final personal = WallpaperLibrary.inside(
        places,
        '/mnt/sd/Wallpapers/Personal',
      );
      expect(namesOf(personal), ['Trips']);
      expect(namesOf(WallpaperLibrary.inside(places, personal.single.path)), [
        'three',
      ]);
    });

    test('a folder that is not there lists as nothing', () {
      expect(WallpaperLibrary.inside(places, '/nowhere'), isEmpty);
    });
  });

  group('every picture, for a caller that wants them flat', () {
    test('walks into the folders the picker browses', () {
      put('/mnt/sd/Wallpapers/loose.jpg');
      put('/mnt/sd/Wallpapers/Unsplash/one.jpg');
      put('/mnt/sd/Wallpapers/Personal/Trips/three.jpg');
      expect(namesOf(WallpaperLibrary.everyPicture(places))..sort(), [
        'loose',
        'one',
        'three',
      ]);
    });

    test('and does not walk forever', () {
      // A folder that contains itself would, without a floor on the depth.
      put('/mnt/sd/Wallpapers/a/b/c/d/e/f/g/h/i/j/deep.jpg');
      expect(WallpaperLibrary.everyPicture(places, depth: 2), isEmpty);
    });
  });
}
