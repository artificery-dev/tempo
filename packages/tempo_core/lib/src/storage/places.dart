import 'package:file/file.dart';
import 'package:path/path.dart' as p;
import 'package:tomeui/tomeui.dart';

/// The places the player will let you into.
enum Place {
  /// Everything that is yours: the player's own storage, where its data and
  /// settings live.
  home,

  /// The card in the slot, when there is one.
  sdCard,

  /// The machine itself. Off by default, and on only because someone went
  /// looking for it in Settings.
  root,
}

/// The player's filesystem, and the places worth starting from in it.
///
/// One namespace, as the device has: a whole Linux filesystem with the card
/// mounted inside it. What changes between the device and the emulator is
/// what that namespace is made of, not its shape - so a browser written
/// against this works on both without knowing which it has.
@immutable
class Places {
  Places({
    required this.fileSystem,
    required this.home,
    String? config,
    String? data,
    this.sdCard = '/mnt/sd',
    this.root = '/',
  }) : config = config ?? p.posix.join(home, '.config', 'tempo'),
       data = data ?? p.posix.join(home, '.tempo');

  /// The whole machine.
  final FileSystem fileSystem;

  /// Where the player's own storage is. The device's XDG data directory,
  /// under whatever user it runs as.
  final String home;

  /// Tempo-owned state, separate from the home and media browsing roots.
  final String data;

  /// Where a card appears when one is in the slot. The device mounts it
  /// here; the emulator mounts its stand-in at the same path, so nothing
  /// above this line has to know the difference.
  final String sdCard;

  /// The top of the machine.
  final String root;

  /// Where the player keeps what it is set to: `$XDG_CONFIG_HOME/tempo`,
  /// or `.config/tempo` under [home] when the environment says nothing.
  /// The settings file and the wallpaper live here.
  ///
  /// Inside [home] by default, so what the player is set to travels with
  /// the player's own storage - and out of the way of someone browsing
  /// their music, which a dotfile in the home was not quite.
  final String config;

  String pathOf(Place place) => switch (place) {
    Place.home => home,
    Place.sdCard => sdCard,
    Place.root => root,
  };

  /// Which place a path is in - the most specific one that contains it.
  ///
  /// This is what a browser highlights: inside the card it is the card,
  /// inside home it is home, and anywhere else on the machine it is the
  /// root, which is the honest answer for a path that is neither.
  Place placeOf(String path) {
    final normalized = p.posix.normalize(path);
    // Home and the card first, and the longer of the two before the
    // shorter, in case one is ever nested inside the other.
    final candidates = [(Place.home, home), (Place.sdCard, sdCard)]
      ..sort((a, b) => b.$2.length.compareTo(a.$2.length));

    for (final (place, at) in candidates) {
      if (_contains(at, normalized)) return place;
    }
    return Place.root;
  }

  static bool _contains(String parent, String path) {
    final at = p.posix.normalize(parent);
    return path == at || path.startsWith(at.endsWith('/') ? at : '$at/');
  }
}

/// Whether the browser is allowed out of [Place.home] and [Place.sdCard].
///
/// A setting in the making, like [Appearance]: the Files app will offer
/// "Browse full filesystem", and this is what it will move. Off by default,
/// because a music player that opens on `/proc` has failed at being one.
abstract final class FullFilesystem {
  static final enabled = ValueNotifier<bool>(false);

  /// The places on offer, in the order a picker should show them.
  static List<Place> placesFor(bool card) => [
    Place.home,
    if (card) Place.sdCard,
    if (enabled.value) Place.root,
  ];
}
