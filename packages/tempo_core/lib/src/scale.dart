import 'package:tomeui/tomeui.dart';

import 'panel.dart';

/// The detents from one option to the next on every rail the wheel turns:
/// a settings row's segmented control, the power dialog's two commands,
/// and the dock's row of apps.
///
/// One number for all of them on purpose. A rail that turns at a different
/// rate from the rail on the row above it reads as a stiff one rather than
/// a considered one, and the wheel's whole grammar rests on every turn
/// costing what the last turn cost.
const int panelRailWeight = 1;

/// The scale the player's chrome is drawn at, whatever the UI size is set
/// to: the status bar, and the settings screens behind it.
///
/// Size is about the lists and grids a player *walks* - the menus, the
/// library, the file browser, home. The bar is a fixed strip of readings
/// that has to line up with itself at every depth, and settings is where
/// the size is chosen from: a screen that resized itself while you were
/// choosing how big things should be would be arguing with you.
const UiScale chromeScale = UiScale.regular;

/// How large the player's UI is drawn: the rows, the bar, the type.
///
/// The wheel is the only way around the screen, so nothing here has to be
/// big enough for a thumb. A 48dp target is a rule for a screen that is
/// touched, and this one never is: the selection bar moves with the wheel
/// and is the whole of the affordance, which is what lets the rows come
/// down to the proportions of the click-wheel players this one takes
/// after - a title bar and six rows to a screen.
///
/// [regular] is the default. [large] is the first UI, kept as it was:
/// Tome's desktop-sized type and spacing, three rows to a screen. The
/// player will offer the choice under Settings > General > Appearance;
/// until then [Appearance.scale] is what moves it.
enum UiScale {
  /// The same rhythm, tightened: 45-pixel rows put seven on a screen
  /// instead of six, for a library that is walked more than it is read.
  /// The type and the spacing come down with the rows - a row that is a
  /// seventh shorter with the same words in it is not a denser list, it is
  /// a cramped one.
  compact(
    label: 'Compact',
    rowExtent: 45 / Panel.devicePixelRatio,
    fileRowExtent: 45 / Panel.devicePixelRatio,
    barHeight: 40 / Panel.devicePixelRatio,
    // Three rows of three under the bar rather than two.
    gridColumns: 3,
    gridCellExtent: 106 / Panel.devicePixelRatio,
    titleExtent: 39 / Panel.devicePixelRatio,
    summaryExtent: 32 / Panel.devicePixelRatio,
    controlExtent: 29 / Panel.devicePixelRatio,
    cardGap: 12 / Panel.devicePixelRatio,
    typography: _compactType,
    space: Space(
      x1: 1.25,
      x2: 2.5,
      x3: 3.75,
      x4: 5,
      x5: 6.25,
      x6: 7.5,
      x8: 10,
      x10: 12.5,
      x12: 15,
      x16: 20,
    ),
    sizes: Sizes(
      iconSmall: 6,
      icon: 8,
      iconLarge: 9.5,
      iconExtraLarge: 12,
      controlCompact: 12,
      control: 15,
      touchTarget: 15,
      // The panel is the panel: what a dialog and a column of content are
      // allowed is a width, not a size that scales with the type.
      dialog: 160,
      contentNarrow: 175,
      content: 175,
    ),
    strokes: Strokes(
      hairline: 1 / Panel.devicePixelRatio,
      focus: 2 / Panel.devicePixelRatio,
    ),
  ),

  /// One rhythm across the panel: a 40-pixel bar over 53-pixel rows in
  /// every list - the menus and the file browser alike, which is getting
  /// icons and wants the room - comes to 358 of the panel's 360, the last
  /// two under the sixth row.
  regular(
    label: 'Regular',
    rowExtent: 53 / Panel.devicePixelRatio,
    fileRowExtent: 53 / Panel.devicePixelRatio,
    barHeight: 40 / Panel.devicePixelRatio,
    // Two rows of three under the bar: 320 panel pixels left over the
    // 480, each cell 160 tall and the width's third across.
    gridColumns: 3,
    gridCellExtent: 160 / Panel.devicePixelRatio,
    // A settings tile that carries more than a name gives its title a
    // tighter line than a menu row's - 46 panel pixels rather than 53 -
    // so the description sits close under the words it belongs to rather
    // than adrift between two rows. The line itself is 29 of that, and
    // the rest is the air over and under it; the description's 38 is the
    // same line with the same air below; the control's 34 is a track and
    // the room a set of options' words need.
    //
    // Half again as much air as the words strictly need, because a card
    // is what these sit in: the glyph at the leading edge gives the words
    // room from the side, and the top and bottom have to answer it.
    titleExtent: 46 / Panel.devicePixelRatio,
    summaryExtent: 38 / Panel.devicePixelRatio,
    controlExtent: 34 / Panel.devicePixelRatio,
    cardGap: 14 / Panel.devicePixelRatio,
    typography: _regularType,
    // Tome's 4dp ladder at three eighths: the same steps, closer together.
    space: Space(
      x1: 1.5,
      x2: 3,
      x3: 4.5,
      x4: 6,
      x5: 7.5,
      x6: 9,
      x8: 12,
      x10: 15,
      x12: 18,
      x16: 24,
    ),
    sizes: Sizes(
      iconSmall: 7,
      icon: 9,
      iconLarge: 11,
      iconExtraLarge: 14,
      controlCompact: 14,
      control: 18,
      touchTarget: 18,
      dialog: 160,
      contentNarrow: 175,
      content: 175,
    ),
    // One panel pixel: a hairline this fine is a line, not a bar.
    strokes: Strokes(
      hairline: 1 / Panel.devicePixelRatio,
      focus: 2 / Panel.devicePixelRatio,
    ),
  ),

  /// The first UI, unchanged: Tome's own scale, three 44dp rows to a
  /// screen.
  large(
    label: 'Large',
    // Four rows to a screen, exactly: 80 of the 320 panel pixels under the
    // bar, each. Tome's own type at 14dp needs 21 of that for its line, so
    // the rest is air the row can afford.
    rowExtent: 80 / Panel.devicePixelRatio,
    fileRowExtent: 80 / Panel.devicePixelRatio,
    barHeight: 40 / Panel.devicePixelRatio,
    // Two rows of three, as at the other sizes: the glyphs are bigger
    // here, so the same cell holds them.
    gridColumns: 3,
    gridCellExtent: 160 / Panel.devicePixelRatio,
    titleExtent: 70 / Panel.devicePixelRatio,
    summaryExtent: 58 / Panel.devicePixelRatio,
    controlExtent: 52 / Panel.devicePixelRatio,
    cardGap: 20 / Panel.devicePixelRatio,
    typography: Typography(),
    // Tome's 4dp ladder at five eighths. The type here is the desktop's,
    // but the panel is not: at the full ladder a row spends more of its
    // width on air than on words, and four big rows on a 175dp screen is
    // exactly where that shows.
    space: Space(
      x1: 2.5,
      x2: 5,
      x3: 7.5,
      x4: 10,
      x5: 12.5,
      x6: 15,
      x8: 20,
      x10: 25,
      x12: 30,
      x16: 40,
    ),
    // Tome's sizes, except the three that are a *width*: the panel is the
    // panel whatever the type is set to.
    sizes: Sizes(dialog: 160, contentNarrow: 175, content: 175),
    strokes: Strokes(),
  );

  const UiScale({
    required this.label,
    required this.rowExtent,
    required this.fileRowExtent,
    required this.barHeight,
    required this.gridColumns,
    required this.gridCellExtent,
    required this.titleExtent,
    required this.summaryExtent,
    required this.controlExtent,
    required this.cardGap,
    required this.typography,
    required this.space,
    required this.sizes,
    required this.strokes,
  });

  /// What a setting calls it.
  final String label;

  /// The height of a row in a wheel-driven list of menu entries.
  final double rowExtent;

  /// The height of a row in the file browser's columns, which are narrow
  /// and show a name and a glyph rather than a menu entry.
  final double fileRowExtent;

  /// The height of the [StatusBar] across the top of the panel.
  final double barHeight;

  /// A wheel-driven grid of glyphs (the Apps page): how many across, and
  /// how tall each cell is. The width is the panel's share.
  final int gridColumns;
  final double gridCellExtent;

  /// The title's own line on a settings tile that carries something under
  /// it - a description, a control, or both.
  ///
  /// Tighter than [rowExtent], which is the height of a row that is only a
  /// name. A tile's parts belong together, and the air that reads as
  /// "these words go with that row" is smaller than the air between two
  /// rows.
  final double titleExtent;

  /// What a line of description under a tile's title costs: one line of
  /// the caption face and the air above it. A tile with no description is
  /// a [rowExtent] row like any other.
  final double summaryExtent;

  /// What a control on a line of its own costs - a slider's track and the
  /// air around it. A control that rides the title's own line (a switch at
  /// the trailing end) costs nothing.
  final double controlExtent;

  /// The air around a card of settings: in from the panel's edges, and
  /// between one card and the next.
  ///
  /// The same number for both on purpose - it is what makes a column of
  /// cards read as a column rather than as a stack of unrelated slabs, and
  /// it is the wallpaper that shows through it.
  final double cardGap;

  final Typography typography;
  final Space space;
  final Sizes sizes;
  final Strokes strokes;

  /// Tome's theme at this scale, in [brightness], mixed from the three
  /// swatches the player is set to. Null takes Tome's own default for that
  /// role, which is what an unset - or unrecognised - name comes to.
  Theme theme(
    Brightness brightness, {
    Swatch? primary,
    Swatch? accent,
    Swatch? neutral,
  }) => Theme(
    palette: Palette(
      brightness: brightness,
      primary: primary ?? Swatch.sky,
      accent: accent ?? Swatch.blue,
      neutral: neutral ?? Swatch.zinc,
    ),
    typography: typography,
    space: space,
    sizes: sizes,
    strokes: strokes,
  );

  /// The scale the UI around [context] is drawn at: what [UiScaleScope]
  /// says, or [classic] outside one (a test that mounts a screen bare).
  static UiScale of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UiScaleScope>()?.scale ??
      UiScale.regular;
}

/// Tells the screens under it which [UiScale] they are drawn at. `TempoApp`
/// installs one above the navigator, so every route sees it.
class UiScaleScope extends InheritedWidget {
  const UiScaleScope({required this.scale, required super.child, super.key});

  final UiScale scale;

  @override
  bool updateShouldNotify(UiScaleScope oldWidget) => scale != oldWidget.scale;
}

/// Tome's type scale for the classic size.
///
/// The menu row is 8dp of type in a 19.3dp row - the proportion of the
/// click-wheel players', whose 14-pixel bold menus sat in 36-pixel rows -
/// and a little heavier than Tome's body weight, because at this size on
/// this panel the extra weight is what keeps a stroke a stroke. The bar's
/// type is well up from the rows': the title and the readings both at the
/// title face's 12dp, set solid on the 40-pixel bar, so that at life size
/// the name, the time and the battery can be read at a glance.
/// The same faces one step down, for [UiScale.compact]: a seventh off the
/// row is a seventh off the words in it.
const Typography _compactType = Typography(
  display: TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w600,
    height: 1.2,
    leadingDistribution: TextLeadingDistribution.even,
    letterSpacing: -0.2,
  ),
  headline: TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    height: 1.25,
    leadingDistribution: TextLeadingDistribution.even,
  ),
  title: TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    height: 1.3,
    leadingDistribution: TextLeadingDistribution.even,
  ),
  subtitle: TextStyle(
    fontSize: 10,
    fontWeight: FontWeight.w500,
    height: 1.3,
    leadingDistribution: TextLeadingDistribution.even,
  ),
  body: TextStyle(
    fontSize: 7,
    fontWeight: FontWeight.w500,
    height: 1.3,
    leadingDistribution: TextLeadingDistribution.even,
  ),
  bodySmall: TextStyle(
    fontSize: 6.5,
    fontWeight: FontWeight.w500,
    height: 1.3,
    leadingDistribution: TextLeadingDistribution.even,
  ),
  label: TextStyle(
    fontSize: 8,
    fontWeight: FontWeight.w600,
    height: 1.3,
    leadingDistribution: TextLeadingDistribution.even,
  ),
  caption: TextStyle(
    fontSize: 7,
    fontWeight: FontWeight.w400,
    height: 1.3,
    leadingDistribution: TextLeadingDistribution.even,
  ),
  code: TextStyle(
    fontSize: 7,
    fontWeight: FontWeight.w400,
    height: 1.3,
    leadingDistribution: TextLeadingDistribution.even,
    fontFamily: 'monospace',
    fontFamilyFallback: ['Menlo', 'Consolas', 'Roboto Mono'],
  ),
);

const Typography _regularType = Typography(
  display: TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w600,
    height: 1.2,
    leadingDistribution: TextLeadingDistribution.even,
    letterSpacing: -0.2,
  ),
  headline: TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    height: 1.25,
    leadingDistribution: TextLeadingDistribution.even,
  ),
  title: TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    height: 1.3,
    leadingDistribution: TextLeadingDistribution.even,
  ),
  subtitle: TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w500,
    height: 1.3,
    leadingDistribution: TextLeadingDistribution.even,
  ),
  body: TextStyle(
    fontSize: 8,
    fontWeight: FontWeight.w500,
    height: 1.3,
    leadingDistribution: TextLeadingDistribution.even,
  ),
  bodySmall: TextStyle(
    fontSize: 7.5,
    fontWeight: FontWeight.w500,
    height: 1.3,
    leadingDistribution: TextLeadingDistribution.even,
  ),
  label: TextStyle(
    fontSize: 9,
    fontWeight: FontWeight.w600,
    height: 1.3,
    leadingDistribution: TextLeadingDistribution.even,
  ),
  caption: TextStyle(
    fontSize: 8,
    fontWeight: FontWeight.w400,
    height: 1.3,
    leadingDistribution: TextLeadingDistribution.even,
  ),
  code: TextStyle(
    fontSize: 8,
    fontWeight: FontWeight.w400,
    height: 1.3,
    leadingDistribution: TextLeadingDistribution.even,
    fontFamily: 'monospace',
    fontFamilyFallback: ['Menlo', 'Consolas', 'Roboto Mono'],
  ),
);
