import 'dart:io';

/// Where the emulator keeps things on this machine.
///
/// Under `tempo-toolbox`: the emulator is part of the Toolbox, and its card
/// is a folder full of a user's music, so it lives where the XDG layout
/// puts an application's data rather than in a bundle-id folder.
abstract final class Paths {
  static const app = 'tempo-toolbox';
  static Directory? applicationDirectory;

  /// `$XDG_CONFIG_HOME/tempo-toolbox`, where settings live.
  static Directory get config => _under('XDG_CONFIG_HOME', '.config', 'config');

  /// `$XDG_DATA_HOME/tempo-toolbox`, where the emulated card's contents live.
  static Directory get data => _under('XDG_DATA_HOME', '.local/share', 'data');

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

  /// Linux keeps the XDG layout the player itself uses, so the card and
  /// the settings sit where a person expects them. Elsewhere there is no
  /// such convention, and the app's own support directory stands in for
  /// the dotfolders, with [kind] naming the subfolder.
  static Directory _under(String variable, String fallback, String kind) {
    final folder = applicationDirectory;
    if (folder != null && !Platform.isLinux) {
      return Directory('${folder.path}${Platform.pathSeparator}$kind');
    }
    final base =
        Platform.environment[variable] ??
        '${Platform.environment['HOME'] ?? '.'}'
            '${Platform.pathSeparator}$fallback';
    return Directory('$base${Platform.pathSeparator}$app');
  }
}
