import 'package:tomeui/tomeui.dart';

import '../content_surface.dart';
import '../menu/menu.dart';
import '../panel_bar.dart';
import '../routes.dart';
import '../scale.dart';
import '../time_zones.dart';
import '../services/library.dart';
import 'setting_node.dart';
import 'radio_screen.dart';
import 'library_folders_screen.dart';
import 'setting_tile.dart';
import 'settings.dart';
import 'settings_screen.dart';
import 'wallpaper_screen.dart';
import 'data_storage_screen.dart';

/// The `screen:` pages the player ships, registered before anything can
/// open one.
///
/// [SettingScreens] starts empty so that a plugin can bring its own; these
/// are the player's own, and this is where the tree's keys become widgets.
abstract final class PlayerSettingScreens {
  static void install() {
    SettingScreens.register('data-storage', (_) => const DataStorageScreen());
    SettingScreens.register(
      'library-roots',
      (_) => const LibraryFoldersScreen(),
    );
    SettingScreens.register(
      'library-order',
      (_) => MenuScreens.branchPage(systemMenu.at('/library')!),
    );
    SettingScreens.register('wifi-picker', (_) => const RadioScreen());
    SettingScreens.register(
      'wifi-known',
      (_) => const RadioScreen(known: true),
    );
    SettingScreens.register(
      'bluetooth-devices',
      (_) => const RadioScreen(bluetooth: true),
    );
    SettingScreens.register(
      'time-zone',
      (entry) => TimeZoneScreen(entry: entry),
    );
    SettingScreens.register(
      'wallpaper-picker',
      (entry) => WallpaperPickerScreen(entry: entry),
    );
    SettingScreens.register(
      'wallpaper-palette',
      (entry) => WallpaperPaletteScreen(entry: entry),
    );
  }
}

/// Picking a time zone, in the two steps the list is worth walking in.
///
/// Three hundred zones is not a list anyone walks with a wheel, so the
/// areas come first - Africa, America, Europe - and the places within one
/// after. The same two steps every desktop uses, for the same reason.
///
/// The zone is more than the clock: it is the only thing on the player
/// that says where it is, and so it is where [AppearanceMode.auto] gets
/// the sunrise and sunset it turns the theme over on.
class TimeZoneScreen extends StatelessWidget {
  const TimeZoneScreen({required this.entry, super.key});

  /// The setting being picked: where the chosen zone is written.
  final SettingLocation entry;

  @override
  Widget build(BuildContext context) {
    final scale = UiScale.of(context);
    final store = SettingsScope.of(context);
    final theme = ThemeProvider.of(context);
    final current = '${store.value(entry.path) ?? TimeZones.utc}';
    final areas = TimeZones.areas;

    // A rootfs with no zone table: say so, rather than showing an empty
    // list that looks like a screen that failed to load.
    if (areas.isEmpty) {
      return PanelScreen(
        title: entry.label,
        child: ContentMessage(
          child: Padding(
            padding: EdgeInsets.all(theme.space.x4),
            child: const BodyText(
              'Time zone data is unavailable. The clock uses UTC.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    // UTC leads: it is the one zone that is not a place, it is what the
    // player starts on, and it is the way back to "nowhere in particular".
    final rows = [TimeZones.utc, ...areas];
    final currentArea = TimeZones.at(current)?.area;

    return PanelScreen(
      title: entry.label,
      child: PanelList(
        itemExtent: SettingTile.extentOf(scale),
        // UTC is the one row here that carries a line under its name, so
        // it is the one row that is taller: a list told a single extent
        // draws the rest of them over it.
        extentOf: (index) => SettingTile.extentOf(scale, summary: index == 0),
        autofocus: true,
        initialIndex: currentArea == null
            ? 0
            : rows.indexOf(currentArea).clamp(0, rows.length - 1),
        onActivate: (index) {
          if (index == 0) {
            store.set(entry.path, TimeZones.utc);
            Navigator.of(context).maybePop();
            return;
          }
          Navigator.of(
            context,
          ).push(_TimeZoneAreaScreen.route(entry: entry, area: rows[index]));
        },
        children: [
          for (final (index, row) in rows.indexed)
            SettingTile(
              title: index == 0 ? 'UTC' : row,
              summary: index == 0
                  ? 'Coordinated Universal Time; no daylight saving adjustment'
                  : null,
              trailing: index == 0
                  ? (current == TimeZones.utc
                        ? Icon(theme.icons.confirm, size: theme.sizes.iconSmall)
                        : null)
                  : Icon(theme.icons.chevronRight, size: theme.sizes.iconLarge),
            ),
        ],
      ),
    );
  }
}

/// The places within one area, and the one of them the player is set to.
class _TimeZoneAreaScreen extends StatelessWidget {
  const _TimeZoneAreaScreen({required this.entry, required this.area});

  final SettingLocation entry;
  final String area;

  static Route<void> route({
    required SettingLocation entry,
    required String area,
  }) => PanelRoute(
    settings: RouteSettings(name: '${entry.path}/$area'),
    builder: (_) => _TimeZoneAreaScreen(entry: entry, area: area),
  );

  @override
  Widget build(BuildContext context) {
    final scale = UiScale.of(context);
    final store = SettingsScope.of(context);
    final theme = ThemeProvider.of(context);
    final current = '${store.value(entry.path) ?? TimeZones.utc}';
    final zones = TimeZones.inArea(area);

    return PanelScreen(
      title: area,
      child: PanelList(
        itemExtent: SettingTile.extentOf(scale),
        sectionOf: (index) =>
            MusicShelf.sectionOf(zones[index].location, ignoreArticles: false),
        extentOf: (index) =>
            SettingTile.extentOf(scale, summary: zones[index].comment != null),
        autofocus: true,
        initialIndex: zones
            .indexWhere((zone) => zone.id == current)
            .clamp(0, zones.length - 1),
        onActivate: (index) {
          final navigator = Navigator.of(context);
          store.set(entry.path, zones[index].id);
          // Back past this list and the areas above it, to the settings
          // page that sent us: a zone is chosen once, and being left on
          // the list you chose it from is being left mid-task.
          navigator.pop();
          navigator.pop();
        },
        children: [
          for (final zone in zones)
            SettingTile(
              title: zone.location,
              summary: zone.comment,
              trailing: zone.id == current
                  ? Icon(theme.icons.confirm, size: theme.sizes.iconSmall)
                  : null,
            ),
        ],
      ),
    );
  }
}
