import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

import '../content_surface.dart';
import '../appearance.dart';
import '../dock.dart';
import '../panel_bar.dart';
import '../routes.dart';
import '../scale.dart';
import 'setting_node.dart';
import 'settings.dart';

/// Picking one of Tome's swatches, as a grid of the colors themselves.
///
/// A color is the one setting whose answer cannot be written in words: the
/// row can say "Sky", but only the color says what sky is. So the page is
/// the ramp itself, read the way the Apps page is read - left to right,
/// then down - with the chosen one ringed.
///
/// The colors come first and the grays after, because that is the order
/// they are reached for; but any of them is a legal answer to any of the
/// three roles, and the page does not pretend otherwise.
class SettingColorScreen extends StatelessWidget {
  const SettingColorScreen({required this.entry, super.key});

  /// The setting being picked: where the chosen name is written.
  final SettingLocation entry;

  /// The names on offer, in the order they are shown: the wallpaper first,
  /// then the colors, then the grays.
  ///
  /// The wallpaper leads because it is the only answer that is not a color
  /// at all - it is a *rule*, and the rest of the page is what that rule
  /// might pick.
  static const names = [
    Appearance.fromWallpaper,
    ...Swatch.colorNames,
    ...Swatch.grayNames,
  ];

  static Route<void> route(SettingLocation entry) => PanelRoute(
    settings: RouteSettings(name: '${entry.path}/colors'),
    builder: (_) => SettingColorScreen(entry: entry),
  );

  /// A swatch name as the row above it reads: `sky` is stored, `Sky` is
  /// shown.
  static String labelOf(String name) => name == Appearance.fromWallpaper
      ? 'Auto'
      : name[0].toUpperCase() + name.substring(1);

  /// What a name shows as a disc: the swatch it names, or - for the
  /// wallpaper - what the picture on screen currently suggests for [role].
  static Swatch? swatchOf(String name, String role) =>
      Appearance.swatchFor(name, role);

  /// The role this page is picking for: the last part of its path.
  String get role => entry.path.split('/').last;

  @override
  Widget build(BuildContext context) {
    final scale = UiScale.of(context);
    final store = SettingsScope.of(context);
    final current = '${store.value(entry.path) ?? ''}';

    return PanelScreen(
      title: entry.label,
      child: WheelGrid(
        columns: scale.gridColumns,
        // Not the Apps page's cell: that one is sized for an app's glyph
        // and holds six to a screen, and six colors to a screen makes
        // twenty-six of them nine screens of wheel. A disc and its name
        // want half of it, which puts twelve in front of the eye at once.
        cellExtent: scale.rowExtent * 1.5,
        autofocus: true,
        initialIndex: names.indexOf(current).clamp(0, names.length - 1),
        onActivate: (index) {
          store.set(entry.path, names[index]);
          Navigator.of(context).maybePop();
        },
        children: [
          for (final name in names)
            GridCard(
              child: _SwatchTile(
                name: name,
                role: role,
                chosen: name == current,
              ),
            ),
        ],
      ),
    );
  }
}

/// One swatch in the grid: the color, and what it is called.
class _SwatchTile extends StatelessWidget {
  const _SwatchTile({
    required this.name,
    required this.role,
    required this.chosen,
  });

  final String name;

  /// Which slot is being picked - the wallpaper's answer differs by role.
  final String role;

  final bool chosen;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final swatch = SettingColorScreen.swatchOf(name, role);
    // The stop that reads as "the color" in either light: the one a solid
    // surface in this swatch is filled with.
    final light = theme.palette.brightness == Brightness.light;
    final fill = swatch == null ? null : (light ? swatch.s600 : swatch.s400);
    final disc = theme.sizes.iconExtraLarge;

    return Padding(
      padding: EdgeInsets.all(theme.space.x2),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: theme.space.x2,
          children: [
            Container(
              width: disc,
              height: disc,
              decoration: BoxDecoration(
                color: fill,
                shape: BoxShape.circle,
                // The chosen one wears a ring in the page's own ink, off
                // the disc rather than on it, so the color is not altered
                // by the mark that says it was picked.
                border: chosen
                    ? Border.all(
                        color: theme.palette.text,
                        width: theme.strokes.focus,
                      )
                    : null,
              ),
              // The wallpaper with no picture behind it yet has no color
              // to show, so it shows what it is instead.
              child: fill == null
                  ? Icon(
                      MenuIcons.of('image'),
                      size: disc * 0.7,
                      color: theme.palette.text,
                    )
                  : null,
            ),
            CaptionText(
              SettingColorScreen.labelOf(name),
              maxLines: 1,
              textAlign: TextAlign.center,
              emphasis: TextEmphasis.full,
            ),
          ],
        ),
      ),
    );
  }
}
