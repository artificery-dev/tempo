import 'dart:io';

/// Where the emulator keeps things on this machine.
///
/// Under `tempo` rather than the app's own name: the player, its UI, and
/// this emulator are being renamed to that, and a folder full of a user's
/// music is the last thing that should have to move afterwards.
abstract final class Paths {
  static const app = 'tempo';
  static Directory? applicationDirectory;

  /// `$XDG_CONFIG_HOME/tempo`, where settings live.
  static Directory get config => _under('XDG_CONFIG_HOME', '.config');

  /// `$XDG_DATA_HOME/tempo`, where the emulated card's contents live.
  static Directory get data => _under('XDG_DATA_HOME', '.local/share');

  /// The folder handed to the player as its SD card until told otherwise.
  static Directory get card =>
      Directory('${data.path}${Platform.pathSeparator}sdcard');

  /// The folder mounted as the emulated player's own storage - what it
  /// writes to when it writes to its home.
  static Directory get home =>
      Directory('${data.path}${Platform.pathSeparator}home');

  /// The settings file: everything the rig and the window were left at.
  static File get settings =>
      File('${config.path}${Platform.pathSeparator}emulator.json');

  /// Make sure the default card folder is there, so the card that the rig
  /// offers out of the box is one that can actually be read and written.
  static Directory ensureCard() => _ensure(card);

  /// And the player's own storage, for the same reason.
  static Directory ensureHome() => _ensure(home);

  static Directory _ensure(Directory folder) {
    if (!folder.existsSync()) folder.createSync(recursive: true);
    return folder;
  }

  static Directory _under(String variable, String fallback) {
    if (applicationDirectory case final folder?) {
      return Directory('${folder.path}/$variable');
    }
    final base =
        Platform.environment[variable] ??
        '${Platform.environment['HOME'] ?? '.'}'
            '${Platform.pathSeparator}$fallback';
    return Directory('$base${Platform.pathSeparator}$app');
  }
}
