import 'package:tomeui/tomeui.dart';

/// Runtime values controlled by Settings > System > Developer.
abstract final class DebugSettings {
  /// Whether developer options are available in Settings.
  static final enabled = ValueNotifier<bool>(true);

  /// Whether the frame counter appears above every screen.
  static final frameCounter = ValueNotifier<bool>(true);
}
