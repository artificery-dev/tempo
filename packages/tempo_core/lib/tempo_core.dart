/// The Y2's home experience, whatever is showing it.
///
/// The player runs this under flutter-pi on its own panel; the emulator
/// runs the same widgets inside a drawn body on a desktop. Both mount
/// [TempoApp] inside a [PanelSurface], which is what makes the second one
/// worth trusting: the layout is pinned to [Panel] and cannot drift toward
/// the window it happens to be in.
library;

export 'src/app.dart';
export 'src/first_run/first_run_flow.dart';
export 'src/first_run/first_run_state.dart';
export 'src/text_entry/keyboard_screen.dart';
export 'src/applet.dart';
export 'src/appearance.dart';
export 'src/battery_gauge.dart';
export 'src/debug_menu.dart';
export 'src/dock.dart';
export 'src/list_row.dart';
export 'src/marquee_text.dart';
export 'src/menu/menu.dart';
export 'src/osd.dart';
export 'src/routes.dart';
export 'src/panel.dart';
export 'src/panel_bar.dart';
export 'src/power.dart';
export 'src/scale.dart';
export 'src/solar.dart';
export 'src/screens.dart';
export 'src/screens/files.dart';
export 'src/screens/fm_radio.dart';
export 'src/screens/music.dart';
export 'src/services/services.dart';
export 'src/settings/data_storage_screen.dart';
export 'src/services/video_playback.dart';
export 'src/settings/color_screen.dart';
export 'src/settings/setting_bindings.dart';
export 'src/settings/setting_node.dart';
export 'src/settings/setting_tile.dart';
export 'src/settings/settings.dart';
export 'src/settings/settings_app.dart';
export 'src/settings/settings_screen.dart';
export 'src/settings/settings_file.dart';
export 'src/settings/settings_tree.dart';
export 'src/settings/time_zone_screen.dart';
export 'src/settings/wallpaper_screen.dart';
export 'src/shade.dart';
export 'src/storage/mounted_file_system.dart';
export 'src/storage/places.dart';
export 'src/status.dart';
export 'src/theme_fade.dart';
export 'src/time_zones.dart';
export 'src/wallpaper.dart';
export 'src/wallpaper_import.dart';
export 'src/wallpaper_library.dart';
export 'src/wallpaper_palette.dart';

export 'src/wheel_settings.dart';
