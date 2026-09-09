import 'dart:io' show Platform;
import 'src/daemon_app.dart';
import 'package:flutterpi_gstreamer_video_player/flutterpi_gstreamer_video_player.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:flutter_pi_plymouth_handoff/flutter_pi_plymouth_handoff.dart';
import 'package:tomeui/tomeui.dart';

/// The player's own binary: the app on the panel it was drawn for.
///
/// Everything the screens do lives in `package:tempo_core`, which the
/// emulator runs too. This is only the way in - the app, on its panel,
/// filling the whole screen (the player has no window).
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.environment.containsKey('FLUTTER_TEST')) {
    FlutterpiVideoPlayer.registerWith();
  }
  // A home with no wallpaper gets the default written into it - but not
  // under the test harness, whose "home" is the machine the tests run on
  // and nobody's to write to.
  WallpaperSource.installDefault = !Platform.environment.containsKey(
    'FLUTTER_TEST',
  );
  runApp(
    PanelSurface(
      child: Platform.environment.containsKey('FLUTTER_TEST')
          ? const TempoApp()
          : const DaemonApp(),
    ),
  );
  // Take the panel over from the boot splash once our first frame is up, so
  // plymouth animates until then instead of freezing during startup. A no-op
  // off the device (a test host has no splash to hand off).
  PlymouthHandoff.armOnFirstFrame();
}
