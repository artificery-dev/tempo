import 'package:tomeui/tomeui.dart';

import 'settings.dart';
import 'settings_screen.dart';

/// The Settings app: the root of the settings tree, as the dock's fourth
/// entry opens it.
///
/// A widget of its own, and a thin one, because the dock builds this
/// before anything has been chosen - it is the cover the flow shows - and
/// because what it shows depends on the [Settings] above it rather than on
/// anything passed down through the menu.
class SettingsApp extends StatelessWidget {
  const SettingsApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = SettingsScope.maybeOf(context);
    // No store above us: a test that mounted a screen bare, or a build
    // that has not installed one yet. An empty page is better than a
    // crash, and says so.
    if (settings == null) {
      return const PlaceholderSettings();
    }
    return SettingsScreen(entry: settings.tree.rootEntry);
  }
}

/// What Settings is without a store behind it.
class PlaceholderSettings extends StatelessWidget {
  const PlaceholderSettings({super.key});

  @override
  Widget build(BuildContext context) =>
      const Center(child: BodyText('Settings are not available.'));
}
