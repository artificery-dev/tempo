import 'dart:convert' show base64Decode;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show RotationTransition, Text;
import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

/// A library with whatever tracks a test hands it, and a scan that
/// counts.
class _FakeLibrary implements LibraryService {
  _FakeLibrary(List<TrackSummary> tracks)
    : tracks = ValueNotifier(tracks),
      status = ValueNotifier(LibraryStatus.idle);

  @override
  final ValueNotifier<List<TrackSummary>> tracks;

  @override
  final ValueNotifier<LibraryStatus> status;

  int scans = 0;

  /// Every prefetch asked for, in order.
  final prefetched = <List<int>>[];

  /// The files that have a picture: a one-pixel PNG each.
  final art = <int>{};

  @override
  Future<void> scan() async => scans++;

  @override
  Future<Uint8List?> artwork(int fileId) async =>
      art.contains(fileId) ? _onePixelPng : null;

  @override
  Future<void> prefetch(List<int> fileIds) async => prefetched.add(fileIds);

  @override
  Future<void> dispose() async {}
}

/// The smallest PNG there is: one transparent pixel.
final Uint8List _onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

const _tracks = [
  TrackSummary(
    id: 1,
    fileId: 1,
    path: '/m/1',
    title: 'Hometown Glory',
    artist: 'Adele',
    album: '19',
    trackNumber: 3,
    duration: Duration(minutes: 4, seconds: 31),
  ),
  TrackSummary(
    id: 2,
    fileId: 2,
    path: '/m/2',
    title: 'Chasing Pavements',
    artist: 'Adele',
    album: '19',
    trackNumber: 2,
    duration: Duration(minutes: 3, seconds: 30),
  ),
  TrackSummary(
    id: 3,
    fileId: 3,
    path: '/m/3',
    title: 'Devils Haircut',
    artist: 'Beck',
    album: 'Odelay',
    trackNumber: 1,
    duration: Duration(minutes: 3, seconds: 14),
  ),
];

void main() {
  late _FakeLibrary library;
  late SilentPlayback playback;

  setUp(() {
    MenuDock.reset();
    Playback.state.value = PlaybackState.stopped;
  });

  Future<ClickWheelController> pumpApp(
    WidgetTester tester, {
    List<TrackSummary> tracks = _tracks,
  }) async {
    final wheel = ClickWheelController();
    library = _FakeLibrary(tracks);
    playback = SilentPlayback();
    final services = PlayerServices(
      battery: ValueNotifier(const BatteryReading(percent: 50)),
      wifi: ValueNotifier(WifiReading.off),
      bluetooth: ValueNotifier(BluetoothReading.off),
      storage: ValueNotifier(StorageReading.empty),
      places: PlayerServices.fallback.places,
      screen: ScreenSwitch(),
      volume: VolumeSwitch(),
      output: OutputSwitch(),
      feedback: FeedbackSwitch(),
      library: library,
      playback: playback,
    );
    await tester.pumpWidget(
      PanelSurface(
        child: TempoApp(wheel: wheel, services: services),
      ),
    );
    await tester.pumpAndSettle();
    return wheel;
  }

  Future<void> jogTo(
    WidgetTester tester,
    ClickWheelController wheel,
    int index,
  ) async {
    if (index != 0) wheel.jog(index);
    await tester.pumpAndSettle();
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
  }

  /// Home > dock > Library > Music.
  Future<void> toMusic(WidgetTester tester, ClickWheelController wheel) async {
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    wheel.jog(2 * MenuDock.physics.weight);
    await tester.pumpAndSettle();
    wheel.press(WheelButton.select);
    await tester.pumpAndSettle();
    await jogTo(tester, wheel, 0);
    expect(find.text('Songs'), findsOneWidget);
  }

  testWidgets('Songs lists every track by title, and the center button '
      'plays from there and goes home', (tester) async {
    final wheel = await pumpApp(tester);
    await toMusic(tester, wheel);

    await jogTo(tester, wheel, 1);
    expect(find.byKey(const Key('SongsScreen')), findsOneWidget);
    final rows = tester
        .widgetList<TrackRow>(find.byType(TrackRow))
        .map((row) => row.track.title)
        .toList();
    expect(rows, ['Chasing Pavements', 'Devils Haircut', 'Hometown Glory']);

    // Down one to Devils Haircut, and in.
    library.art.add(3);
    await jogTo(tester, wheel, 1);
    // The wheel moving asked the library for the pictures around it: the
    // selection first, the rows below, then the rows above.
    expect(library.prefetched.last, [3, 1, 2]);
    expect(playback.value.track?.title, 'Devils Haircut');
    expect(playback.value.index, 1);
    expect(playback.value.count, 3);
    expect(Playback.state.value, PlaybackState.playing);
    // Home is on stage, and what is playing is on it.
    expect(MenuDock.selected.value?.path, '/home');
    expect(find.byKey(NowPlayingCard.cardKey), findsOneWidget);
    expect(find.text('Devils Haircut'), findsOneWidget);
    expect(find.text('Beck - Odelay'), findsOneWidget);
    expect(find.text('3:14'), findsOneWidget);
    // And its cover, once the library answered - over the top of the
    // page, above the card, with the bar keeping even "Home" off.
    await tester.pump();
    expect(find.byKey(NowPlayingArt.artKey), findsOneWidget);
    expect(
      tester.getRect(find.byKey(NowPlayingArt.artKey)).bottom,
      lessThanOrEqualTo(tester.getRect(find.byKey(NowPlayingCard.cardKey)).top),
    );
    // The bar's title slot has the clock now, not "Home".
    expect(find.text('Home'), findsNothing);
    expect(
      find.descendant(of: find.byType(ClockText), matching: find.byType(Text)),
      findsWidgets,
    );
    // The progress bar's fill is as tall as the bar, not a line of zero
    // (at the very start there is no fill to measure).
    await playback.seekBy(const Duration(seconds: 30));
    await tester.pump();
    final fill = tester.getSize(find.byKey(NowPlayingCard.barKey));
    expect(fill.height, 4);
  });

  testWidgets('Albums opens onto the album, and plays it in order', (
    tester,
  ) async {
    final wheel = await pumpApp(tester);
    await toMusic(tester, wheel);

    await jogTo(tester, wheel, 2);
    expect(find.byKey(const Key('AlbumsScreen')), findsOneWidget);
    expect(find.text('19'), findsOneWidget);
    expect(find.text('Odelay'), findsOneWidget);

    await jogTo(tester, wheel, 0);
    expect(find.byType(AlbumScreen), findsOneWidget);
    final rows = tester
        .widgetList<TrackRow>(find.byType(TrackRow))
        .map((row) => row.track.title)
        .toList();
    expect(rows, ['Chasing Pavements', 'Hometown Glory']);

    await jogTo(tester, wheel, 0);
    expect(playback.value.track?.title, 'Chasing Pavements');
    expect(playback.value.count, 2);
  });

  testWidgets('Artists opens onto the albums, All Songs first', (tester) async {
    final wheel = await pumpApp(tester);
    await toMusic(tester, wheel);

    await jogTo(tester, wheel, 3);
    expect(find.byKey(const Key('ArtistsScreen')), findsOneWidget);
    expect(find.text('Adele'), findsOneWidget);
    expect(find.text('Beck'), findsOneWidget);

    await jogTo(tester, wheel, 0);
    expect(find.byType(ArtistScreen), findsOneWidget);
    expect(find.text('All Songs'), findsOneWidget);
    expect(find.text('19'), findsOneWidget);

    await jogTo(tester, wheel, 0);
    expect(playback.value.track?.title, 'Chasing Pavements');
    expect(playback.value.count, 2);
  });

  testWidgets(
    'empty shelves point to Settings and Music has no update action',
    (tester) async {
      final wheel = await pumpApp(tester, tracks: const []);
      await toMusic(tester, wheel);
      expect(find.text('Update Library'), findsNothing);

      await jogTo(tester, wheel, 1);
      expect(find.byType(EmptyShelf), findsOneWidget);
      expect(find.text('no songs yet'), findsOneWidget);
      expect(find.text('Manage folders in Settings → Library'), findsOneWidget);
      expect(library.scans, 0);
    },
  );

  testWidgets('new music being taken in shows as a line under home, the '
      'clock stepping up for it; an unchanged card says nothing', (
    tester,
  ) async {
    await pumpApp(tester);
    expect(find.byKey(LibraryFooter.footerKey), findsNothing);
    final clockBefore = tester.getRect(find.byType(HomeClock));

    // Looking over a card that has not changed: quiet.
    library.status.value = const LibraryStatus(
      phase: LibraryPhase.scanning,
      scan: ScanStatus(state: ScanState.extracting, seen: 6000),
    );
    await tester.pump();
    expect(find.byKey(LibraryFooter.footerKey), findsNothing);

    library.status.value = const LibraryStatus(
      phase: LibraryPhase.scanning,
      scan: ScanStatus(
        state: ScanState.extracting,
        seen: 6000,
        changed: 40,
        added: 12,
      ),
    );
    await tester.pump();
    expect(find.byKey(LibraryFooter.footerKey), findsOneWidget);
    expect(find.byType(Spinner), findsOneWidget);
    expect(find.text('Updating Library: 12 / 40'), findsOneWidget);
    // Along the bottom edge, the whole width, and the page above it
    // stepped up rather than covered.
    final footer = tester.getRect(find.byKey(LibraryFooter.footerKey));
    final panel = tester.getRect(find.byType(TempoApp));
    expect(footer.bottom, panel.bottom);
    expect(footer.width, panel.width);
    expect(
      tester.getRect(find.byType(HomeClock)).bottom,
      lessThan(clockBefore.bottom),
    );
    // It turns.
    double turns() => tester
        .widget<RotationTransition>(find.byType(RotationTransition))
        .turns
        .value;
    final before = turns();
    await tester.pump(const Duration(milliseconds: 250));
    expect(turns(), isNot(before));

    // A folder that would not list is an error but not a file: the count
    // never reads past the total.
    library.status.value = const LibraryStatus(
      phase: LibraryPhase.scanning,
      scan: ScanStatus(
        state: ScanState.finishing,
        seen: 6000,
        changed: 40,
        added: 40,
        errorCount: 1,
      ),
    );
    await tester.pump();
    expect(find.text('Updating Library: 40 / 40'), findsOneWidget);

    library.status.value = const LibraryStatus(
      phase: LibraryPhase.idle,
      scan: ScanStatus(
        state: ScanState.done,
        seen: 6000,
        changed: 40,
        added: 40,
      ),
    );
    await tester.pump();
    expect(find.byKey(LibraryFooter.footerKey), findsNothing);
    expect(find.byType(Spinner), findsNothing);
  });
}
