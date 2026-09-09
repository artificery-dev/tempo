import 'dart:math' as math;

import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

import '../marquee_text.dart';
import '../scale.dart';
import '../wallpaper.dart';
import 'setting_node.dart';

/// Shared spacing and line boxes for every settings control tile.
/// Extent declarations and widget layout must use the same measurements.
class SettingTileMetrics {
  const SettingTileMetrics(this.scale);
  final UiScale scale;

  double get outer => scale.space.x4;
  double get inner => scale.space.x3 / 2;
  EdgeInsets get padding => EdgeInsets.all(outer);

  // A single line also accommodates the switch and leading glyph. Keeping
  // this slot consistent avoids different padding for different controls.
  double get title => math.max(
    math.max(_line(scale.typography.body), scale.sizes.iconLarge),
    (scale.typography.body.fontSize ?? 14) * 1.7,
  );
  double get summary => _line(scale.typography.caption);
  double get control => scale.controlExtent;

  static double _line(TextStyle style) =>
      (style.fontSize ?? 14) * (style.height ?? 1.0);

  double extent({bool hasSummary = false, bool hasBody = false}) =>
      outer * 2 +
      title +
      (hasBody ? inner + control : 0) +
      (hasSummary ? inner + summary : 0);
}

/// A row in a settings list: the setting's name, what it is set to, and a
/// line saying what it does.
///
/// Every settings row is one of these, and the control is *in* the tile
/// rather than behind it - a switch is thrown from the list, a slider is
/// moved from the list, and only the settings that genuinely need a page
/// of their own get one. Two places a control can sit:
///
/// ```
/// | Title                     [Off On] |   trailing: on the title's line
/// | What the setting does               |
///
/// | Title                               |   body: a line of its own
/// | [--------X                        ] |
/// | What the setting does               |
/// ```
///
/// The tile carries no color: the list dresses the selected row and the
/// words, the glyph and the control take that dress ([WheelList] does this
/// with a wash of the primary), which is why nothing here names a swatch.
///
/// Its height is not measured - it is declared, by [extentOf], because the
/// list has to know every row's height before it builds any of them. So a
/// description is one line, ellipsized: a settings screen where one tile
/// is two lines tall and the next is four cannot be walked with a wheel at
/// a steady rhythm.
class SettingTile extends StatelessWidget {
  const SettingTile({
    required this.title,
    this.summary,
    this.icon,
    this.leading,
    this.trailing,
    this.body,
    this.enabled = true,
    super.key,
  });

  /// The setting's name.
  final String title;

  /// One line under it, saying what the setting does. Null for the tiles
  /// whose name is the whole story.
  final String? summary;

  /// A glyph before the name.
  final IconData? icon;

  /// Something of its own before the name, in the glyph's place: a
  /// thumbnail, a swatch. Wins over [icon] where both are given.
  final Widget? leading;

  /// A control on the title's own line, at the trailing end: a switch, a
  /// value, a chevron.
  final Widget? trailing;

  /// A control on a line of its own, under the title and over the
  /// [summary]: a slider's track, a segmented control.
  final Widget? body;

  /// Whether the setting can be moved at all. A disabled tile is still
  /// shown, still selectable and still says what it does - a row that
  /// vanishes when another setting changes is a row a user goes looking
  /// for (see the settings tree's `when:`).
  final bool enabled;

  /// How tall a tile with these parts is, at [scale]. The list asks this,
  /// not the tile: `WheelList.extentOf` needs a height per row before a
  /// row exists to measure.
  static double extentOf(
    UiScale scale, {
    bool summary = false,
    bool body = false,
  }) => SettingTileMetrics(scale).extent(hasSummary: summary, hasBody: body);

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final scale = UiScale.of(context);
    final trailing = this.trailing;
    final body = this.body;
    final summary = this.summary;
    final metrics = SettingTileMetrics(scale);

    final header = SizedBox(
      height: metrics.title,
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          spacing: metrics.inner,
          children: [
            if (leading != null)
              leading!
            else if (icon != null)
              Icon(icon, size: theme.sizes.iconLarge),
            Expanded(
              child: BodyText(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (trailing != null)
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: constraints.maxWidth / 2),
                child: trailing,
              ),
          ],
        ),
      ),
    );

    final words = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      // Exactly the height it declared, whatever room it is given: the
      // list hands every row its extent, and a tile that stretched to
      // fill a taller box would put its words somewhere else than the
      // row above it did.
      mainAxisSize: MainAxisSize.min,
      spacing: metrics.inner,
      children: [
        header,
        // Body controls and descriptions span the full padded tile width.
        if (body != null) SizedBox(height: metrics.control, child: body),
        if (summary != null)
          SizedBox(
            height: metrics.summary,
            child: MarqueeText(
              summary,
              active: WheelRowSelection.of(context),
              style: theme.widgets.text.resolve(
                TextRole.caption,
                emphasis: TextEmphasis.secondary,
                on:
                    DefaultTextStyle.of(context).style.color ??
                    theme.palette.text,
              ),
            ),
          ),
      ],
    );

    return Opacity(
      opacity: enabled ? 1 : theme.opacities.disabled,
      child: Padding(padding: metrics.padding, child: words),
    );
  }
}

/// One row's share of the card its group is drawn as.
///
/// A section label attached to its first row, so the wheel skips the label.
class SettingSectionHeading extends StatelessWidget {
  const SettingSectionHeading(this.label, {super.key});

  final String label;

  static double extentOf(UiScale scale) =>
      scale.cardGap + SettingTileMetrics._line(scale.typography.label);

  @override
  Widget build(BuildContext context) {
    final scale = UiScale.of(context);
    return SizedBox(
      height: extentOf(scale),
      child: Padding(
        padding: EdgeInsets.only(
          top: scale.cardGap,
          left: scale.cardGap + SettingTileMetrics(scale).outer,
          right: scale.cardGap + SettingTileMetrics(scale).outer,
        ),
        child: Semantics(header: true, child: KickerText(label, maxLines: 1)),
      ),
    );
  }
}

/// A settings page is not a list on a page: it is a column of cards over
/// the wallpaper, each holding the settings between two dividers, with the
/// air between them the same as the air at the panel's edges - so the
/// wallpaper runs through the gaps and the grouping needs no lines to say
/// what belongs with what.
///
/// The card is drawn a row at a time, because the wheel walks rows: this
/// paints the ground under one of them, rounds whichever of its corners
/// are the card's own, dresses it when the wheel is on it, and puts a
/// hairline under it unless it is the last of its card.
class SettingCard extends StatelessWidget {
  const SettingCard({
    required this.child,
    required this.first,
    required this.last,
    this.selected = false,
    this.lastOfPage = false,
    this.verticalGap,
    super.key,
  });

  final Widget child;

  /// Whether this row opens its card, closes it, or both.
  final bool first;
  final bool last;

  /// Whether the wheel is on this row.
  final bool selected;

  /// Whether this is the last row of the page, which is the one row that
  /// carries air under it: the rest of the gaps belong to the card below.
  final bool lastOfPage;

  /// Optional tighter spacing for ordinary list rows.
  final double? verticalGap;

  /// What a row of a card costs beyond the tile inside it: the air over
  /// the card it opens, and - at the foot of the page - the air under the
  /// one it closes.
  ///
  /// Nothing inside the card's own edges. Every row of a card is the same
  /// height as every other, so three settings in one card are three equal
  /// rows rather than a tall one, a short one and a tall one - the air a
  /// row's words keep is the tile's, and the tile's is the same wherever
  /// it sits.
  static double extraOf(
    UiScale scale, {
    required bool first,
    required bool lastOfPage,
  }) => (first ? scale.cardGap : 0) + (lastOfPage ? scale.cardGap : 0);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    // Listened to rather than read: the slider that moves this is a row
    // on a card of exactly this kind, and it has to answer under the
    // hand that is moving it.
    listenable: Backdropped.changes,
    builder: (context, _) => _card(context),
  );

  Widget _card(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final scale = UiScale.of(context);
    final radius = theme.radii.medium;
    final corners = BorderRadius.vertical(
      top: first ? radius.topLeft : Radius.zero,
      bottom: last ? radius.bottomLeft : Radius.zero,
    );

    // The card's own ground: a wash rather than a slab, which is what a
    // card over a wallpaper wants, since the picture should still be
    // felt through it - as much of it as Page Tint says, and none of it
    // where Translucent Surfaces is off.
    //
    // It is the card, not the page, that the tint moves here: a settings
    // page has no ground of its own - the cards are the ground and the
    // wallpaper runs between them - so a tint applied to the page would
    // be a tint applied to nothing, on the one page where the slider
    // that sets it lives.
    final surfaces = theme.widgets.surface;
    // The ring it keeps around itself is the subtle surface's own, and
    // stays put whatever the wash inside it comes to: it is the ring
    // that says where a card ends, and a card thinned to nothing still
    // has to end somewhere.
    final ground = surfaces.resolve(
      SemanticSwatch.neutral,
      SurfaceVariant.subtle,
    );
    // And the dress the wheel puts on one of its rows: the primary's soft
    // wash, the same one every other wheel-driven list marks its cursor
    // with ([WheelList]'s own). Soft rather than subtle, whose wash is the
    // swatch's darkest stop in the dark and its lightest in the light, and
    // left the cursor barely a shade off the page it sits on.
    final dress = surfaces.resolve(SemanticSwatch.primary, SurfaceVariant.soft);

    return Padding(
      padding: EdgeInsets.only(
        left: scale.cardGap,
        right: scale.cardGap,
        top: first ? (verticalGap ?? scale.cardGap) : 0,
        bottom: lastOfPage ? (verticalGap ?? scale.cardGap) : 0,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          // The subtle surface's own fill, which is already a wash rather
          // than a slab: a card over a wallpaper is felt as a card *over*
          // something, and the picture still moves behind it - as much of
          // it as the tint says, which at the default is exactly this.
          // Out in the flow, a card on a cover beside the one in the
          // middle lets more of the picture through: the fade that used
          // to belong to the page's own wash, now that the page has
          // none, belongs to the things standing on it.
          color: Backdropped.surfaceOf(
            theme.palette,
            focus: CoverFocus.of(context),
          ),
          borderRadius: corners,
        ),
        child: ClipRRect(
          clipBehavior: Clip.antiAlias,
          borderRadius: corners,
          // The rule is painted over the row rather than laid out under
          // it: the list gave this row an exact height, and a hairline
          // taking a hairline of it would leave the tile that much short.
          child: Stack(
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: selected ? dress.fill : null,
                  ),
                  child: selected
                      ? IconTheme.merge(
                          data: IconThemeData(color: dress.foreground),
                          child: DefaultTextStyle.merge(
                            style: TextStyle(color: dress.foreground),
                            child: child,
                          ),
                        )
                      : child,
                ),
              ),
              // The line between two rows of one card. None under the last
              // row: what ends a card is the card ending.
              if (!last)
                const PositionedDirectional(
                  start: 0,
                  end: 0,
                  bottom: 0,
                  child: SettingRule(),
                ),
              // The quiet ring the subtle surface keeps around itself -
              // the card's, not the row's, so it runs down the sides of
              // every row and turns the corner only where the card does.
              if (ground.border != null)
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _CardRing(
                        color: ground.border!,
                        width: theme.strokes.hairline,
                        radius: radius.topLeft.x,
                        first: first,
                        last: last,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The card's ring, drawn a row at a time.
///
/// The trick is the rect rather than the arithmetic: a row in the middle
/// of a card strokes a rounded rectangle that starts a corner's radius
/// above it and ends one below, so the clip around the row keeps the two
/// straight sides and throws the corners away. A row that opens the card
/// keeps its own top, one that closes it keeps its own bottom, and a card
/// of one row keeps all four.
class _CardRing extends CustomPainter {
  const _CardRing({
    required this.color,
    required this.width,
    required this.radius,
    required this.first,
    required this.last,
  });

  final Color color;
  final double width;
  final double radius;
  final bool first;
  final bool last;

  @override
  void paint(Canvas canvas, Size size) {
    // Half a stroke in, so the whole line lands inside the clip rather
    // than half of it being shaved off by the edge it is drawing.
    final inset = width / 2;
    final rect = Rect.fromLTRB(
      inset,
      (first ? 0 : -radius) + inset,
      size.width - inset,
      (last ? size.height : size.height + radius) - inset,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(radius)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_CardRing old) =>
      old.color != color ||
      old.width != width ||
      old.radius != radius ||
      old.first != first ||
      old.last != last;
}

/// The hairline between two rows of one card.
///
/// Inset to where the words start, the way a grouped list has always done
/// it: the line separates the rows without cutting the card in half.
class SettingRule extends StatelessWidget {
  const SettingRule({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: SettingTileMetrics(UiScale.of(context)).outer,
      ),
      child: SizedBox(
        height: theme.strokes.hairline,
        child: ColoredBox(color: theme.palette.divider),
      ),
    );
  }
}

/// A setting that is a yes or a no: the switch rides the title's line, at
/// the trailing end, where the eye can run down a column of them and read
/// the state of a whole screen at once.
class SettingSwitchTile extends StatelessWidget {
  const SettingSwitchTile({
    required this.title,
    required this.value,
    this.onChanged,
    this.summary,
    this.icon,
    this.enabled = true,
    super.key,
  });

  final String title;
  final bool value;

  /// Called with the new value. The wheel throws the switch by activating
  /// the row, so this is what the list calls; a pointer on the switch
  /// itself (the emulator, a desk) calls it too.
  final ValueChanged<bool>? onChanged;

  final String? summary;
  final IconData? icon;
  final bool enabled;

  /// The height of one of these, at [scale].
  static double extentOf(UiScale scale, {bool summary = false}) =>
      SettingTile.extentOf(scale, summary: summary);

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    return SettingTile(
      title: title,
      summary: summary,
      icon: icon,
      enabled: enabled,
      trailing: Switch<bool>.custom(
        value: value,
        style: panelSwitchStyle(theme),
        onChanged: enabled ? onChanged : null,
      ),
    );
  }
}

/// A setting that is a number over a range: the track sits under the
/// title, full width, with the description under it.
///
/// The wheel moves it by capturing the list's jog while the tile is the
/// selected one (the settings tree's `wheel: capture`), which is the
/// screen's job rather than the tile's - the tile only says whether it
/// [captured] the wheel, and dresses the track to show it.
class SettingSliderTile extends StatelessWidget {
  const SettingSliderTile({
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    this.onChanged,
    this.step,
    this.unit,
    this.summary,
    this.icon,
    this.captured = false,
    this.enabled = true,
    super.key,
  });

  final String title;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double>? onChanged;

  /// The step one detent of the wheel moves, in the value's own units.
  /// Null is a continuous track.
  final double? step;

  /// What the number is in - `%`, `s` - shown after it on the title's
  /// line. Null shows the bare number.
  final String? unit;

  final String? summary;
  final IconData? icon;

  /// Whether this tile has the wheel: a turn moves the value rather than
  /// the selection. The track wears the primary at full voice while it
  /// does, and the reading beside the title is what the user is moving.
  final bool captured;

  final bool enabled;

  /// The height of one of these, at [scale]: a control on its own line.
  static double extentOf(UiScale scale, {bool summary = false}) =>
      SettingTile.extentOf(scale, summary: summary, body: true);

  /// The value as it reads on the tile: whole numbers, and the unit when
  /// there is one.
  String get reading {
    final rounded = value.round();
    return unit == null ? '$rounded' : '$rounded$unit';
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final step = this.step;
    // The dress the row is wearing, if the wheel is on it: a track in the
    // primary's own voice would vanish into a wash of the primary, so on
    // a selected row the line is drawn in the color the words are.
    final ink = WheelRowSelection.of(context)
        ? DefaultTextStyle.of(context).style.color
        : null;
    return SettingTile(
      title: title,
      icon: icon,
      summary: summary,
      enabled: enabled,
      // The number rides the title's line: the track shows roughly where
      // the value is, and this says exactly.
      trailing: BodyText(
        reading,
        emphasis: captured ? TextEmphasis.full : TextEmphasis.secondary,
      ),
      body: Slider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        divisions: step == null || step <= 0
            ? null
            : ((max - min) / step).round(),
        style: panelSliderStyle(
          theme,
          height: UiScale.of(context).controlExtent,
          captured: captured,
          ink: ink,
        ),
        onChanged: enabled ? onChanged : null,
      ),
    );
  }
}

/// A setting with a handful of named answers.
///
/// Two shapes, chosen by [layout]: the options as a segmented control on
/// the tile's own line, where they are few and short enough to read at a
/// glance, or the current answer at the trailing end with the options on a
/// page ([onOpen]) behind it. Everything else about the tile - the title's
/// line, the description under it - is the same either way, so a screen
/// that mixes the two still reads as one column.
class SettingChoiceTile extends StatelessWidget {
  const SettingChoiceTile({
    required this.title,
    required this.value,
    required this.options,
    this.onChanged,
    this.onOpen,
    this.controller,
    this.layout = SettingLayout.auto,
    this.summary,
    this.icon,
    this.enabled = true,
    this.captured = false,
    super.key,
  }) : assert(options.length > 0, 'A choice needs something to choose from.');

  final String title;

  /// The current answer. Null shows nothing chosen, which is honest for a
  /// setting whose stored value is no longer on offer - a network out of
  /// range, a swatch a theme has dropped - and is also a real answer for
  /// the settings whose "Never" is stored as nothing.
  final Object? value;

  /// The answers, in order, each with the words it wears.
  final List<SettingOption> options;

  /// Called with the answer chosen on the tile itself. Unused by the
  /// paged shape, where the page reports the choice.
  final ValueChanged<Object?>? onChanged;

  /// Open the page of options. The paged shape needs it; the inline shape
  /// ignores it.
  final VoidCallback? onOpen;

  /// A hand on the track, for the screen that has given this row the
  /// wheel. Null while the row is only being looked at.
  final WheelRailController? controller;

  /// Whether the wheel is on this row: the box is lit while it is.
  final bool captured;

  final SettingLayout layout;
  final String? summary;
  final IconData? icon;
  final bool enabled;

  /// Whether these options ride the tile.
  bool get inline =>
      layout.resolvesInline([for (final option in options) option.label]);

  /// The height of one of these: the inline shape carries a control on a
  /// line of its own, the paged shape does not.
  static double extentOf(
    UiScale scale, {
    required bool inline,
    bool summary = false,
  }) => SettingTile.extentOf(scale, summary: summary, body: inline);

  /// What the trailing end of the paged shape reads: the chosen option's
  /// words, or a dash where nothing is chosen.
  String get reading {
    for (final option in options) {
      if (option.value == value) return option.label;
    }
    return '-';
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final scale = UiScale.of(context);

    if (!inline) {
      return SettingTile(
        title: title,
        summary: summary,
        icon: icon,
        enabled: enabled,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: SettingTileMetrics(UiScale.of(context)).inner,
          children: [
            Flexible(
              child: BodyText(
                reading,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                emphasis: TextEmphasis.secondary,
              ),
            ),
            Icon(theme.icons.chevronRight, size: theme.sizes.iconLarge),
          ],
        ),
      );
    }

    // The same track the power dialog turns, at the panel's size: the box
    // slides with the wheel's own weight rather than hopping, and the
    // answer changes as its center crosses the line between two options.
    return SettingTile(
      title: title,
      summary: summary,
      icon: icon,
      enabled: enabled,
      body: WheelRail<Object?>(
        value: value,
        controller: controller,
        lit: captured,
        style: panelSegmentedStyle(theme, height: scale.controlExtent),
        // The weight every rail of options carries, the power dialog's
        // included: a row is walked, not guarded. No give - there is
        // nowhere to be let go to.
        physics: const WheelRailPhysics(weight: panelRailWeight, give: 0),
        segments: [
          for (final option in options)
            SegmentOption<Object?>(
              value: option.value,
              label: Text(option.label),
            ),
        ],
        onChanged: (next) => onChanged?.call(next),
      ),
    );
  }
}

/// A setting that is a number, stepped rather than swept: a port, a
/// number of seconds, a percent per detent.
///
/// The number rides the title's line and the wheel steps it while the tile
/// has it ([captured]), so a stepper costs no more height than a switch.
/// A number that is really a range - the brightness, a volume - wants
/// [SettingSliderTile] and its track instead; the tree says which by
/// naming `slider` or `stepper`.
class SettingStepperTile extends StatelessWidget {
  const SettingStepperTile({
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    this.onChanged,
    this.step = 1,
    this.unit,
    this.summary,
    this.captured = false,
    this.enabled = true,
    super.key,
  });

  final String title;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int>? onChanged;

  /// What one detent moves.
  final int step;

  /// What the number is in, shown after it.
  final String? unit;

  final String? summary;

  /// Whether this tile has the wheel. The reading comes up to full voice
  /// and wears the arrows that say a turn will move it.
  final bool captured;

  final bool enabled;

  /// The height of one of these: no line of its own.
  static double extentOf(UiScale scale, {bool summary = false}) =>
      SettingTile.extentOf(scale, summary: summary);

  String get reading => unit == null ? '$value' : '$value$unit';

  /// The value a detent away, clamped: what the list hands back after a
  /// jog while this tile has the wheel.
  int stepped(int detents) => (value + detents * step).clamp(min, max);

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final arrows = captured;
    return SettingTile(
      title: title,
      summary: summary,
      enabled: enabled,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: SettingTileMetrics(UiScale.of(context)).inner,
        children: [
          // The arrows only while the wheel is here: a row of them down a
          // settings screen would say every reading is being edited.
          if (arrows) Icon(theme.icons.chevronLeft, size: theme.sizes.icon),
          BodyText(
            reading,
            emphasis: captured ? TextEmphasis.full : TextEmphasis.secondary,
          ),
          if (arrows) Icon(theme.icons.chevronRight, size: theme.sizes.icon),
        ],
      ),
    );
  }
}

/// A setting that opens a page, and says on its own row what it is set to:
/// a chord, a wallpaper, a list of pins, a time zone. The row is the way
/// in and the reading is the answer.
class SettingPageTile extends StatelessWidget {
  const SettingPageTile({
    required this.title,
    this.reading,
    this.onOpen,
    this.summary,
    this.icon,
    this.enabled = true,
    super.key,
  });

  final String title;

  /// What it is set to, in words - `Hold Power`, `Classic`, `3 pinned`.
  /// Null for a page that is not a value at all.
  final String? reading;

  final VoidCallback? onOpen;
  final String? summary;
  final IconData? icon;
  final bool enabled;

  static double extentOf(UiScale scale, {bool summary = false}) =>
      SettingTile.extentOf(scale, summary: summary);

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final reading = this.reading;
    return SettingTile(
      title: title,
      summary: summary,
      icon: icon,
      enabled: enabled,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: SettingTileMetrics(UiScale.of(context)).inner,
        children: [
          if (reading != null)
            Flexible(
              child: BodyText(
                reading,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                emphasis: TextEmphasis.secondary,
              ),
            ),
          Icon(theme.icons.chevronRight, size: theme.sizes.iconLarge),
        ],
      ),
    );
  }
}

/// A setting that is only a reading: the build number, the free space, the
/// battery's voltage. Selectable, so the wheel can walk past it and a
/// user can see it is not broken, and it does nothing when activated.
class SettingInfoTile extends StatelessWidget {
  const SettingInfoTile({
    required this.title,
    required this.reading,
    this.summary,
    this.icon,
    super.key,
  });

  final String title;
  final String reading;
  final String? summary;
  final IconData? icon;

  static double extentOf(UiScale scale, {bool summary = false}) =>
      SettingTile.extentOf(scale, summary: summary);

  @override
  Widget build(BuildContext context) => SettingTile(
    title: title,
    summary: summary,
    icon: icon,
    trailing: BodyText(
      reading,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      emphasis: TextEmphasis.secondary,
    ),
  );
}

/// A setting that does a thing rather than holding a value: update the
/// library, reset the colors, power off.
///
/// [danger] is the destructive ones. It dresses the words rather than the
/// row - a red bar down a settings screen shouts, and what wants saying is
/// that *this* row is the one that erases something.
class SettingActionTile extends StatelessWidget {
  const SettingActionTile({
    required this.title,
    this.summary,
    this.icon,
    this.onInvoke,
    this.danger = false,
    this.enabled = true,
    this.busy,
    super.key,
  });

  final String title;
  final String? summary;
  final IconData? icon;
  final VoidCallback? onInvoke;

  /// Whether this one destroys something. The renderer confirms before
  /// calling [onInvoke]; the tile only says so.
  final bool danger;

  final bool enabled;

  /// What the action is doing right now, in words - `Scanning 412` - or
  /// null when it is not running. An action that takes time reports on its
  /// own row rather than behind a dialog.
  final String? busy;

  static double extentOf(UiScale scale, {bool summary = false}) =>
      SettingTile.extentOf(scale, summary: summary);

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final busy = this.busy;
    return SettingTile(
      title: title,
      summary: summary,
      icon: icon,
      enabled: enabled,
      trailing: busy == null
          ? (danger
                ? Icon(
                    theme.icons.warning,
                    size: theme.sizes.iconLarge,
                    color: theme.palette.error.s500,
                  )
                : null)
          : BodyText(busy, emphasis: TextEmphasis.secondary),
    );
  }
}

/// A switch, cut down to the panel.
///
/// Tome's own switch is 40 by 24 logical pixels - a desktop control, and
/// taller than the whole of a classic row (19.3dp). The shape is kept and
/// the size comes from the type instead, so it lands right at either
/// scale: a track a little taller than the words beside it.
SwitchStyle panelSwitchStyle(Theme theme) {
  final line = theme.typography.body.fontSize ?? 14;
  final height = line * 1.7;
  return theme.widgets.switch_.resolve().copyWith(
    height: height,
    width: height * 1.8,
    thumb: height - theme.space.x1 * 2,
    gap: theme.space.x2,
  );
}

/// A slider, cut down to the panel, and dressed for whether it has the
/// wheel.
///
/// [captured] is the only state a wheel-driven slider has - there is no
/// hover and no drag - so it is what the track shows: the thumb grows,
/// which is the "this is what the wheel is moving now" signal.
///
/// [height] is the line the tile gave it ([UiScale.controlExtent]), and
/// the thumb has to fit inside it: a grip taller than its line would be
/// clipped by the rows above and below.
SliderStyle panelSliderStyle(
  Theme theme, {
  required double height,
  bool captured = false,
  Color? ink,
}) {
  final track = theme.space.x2;
  final thumb = (captured ? track * 2.4 : track * 1.8).clamp(track, height);
  final style = theme.widgets.slider.resolve().copyWith(
    trackHeight: track,
    thumbSize: thumb,
    height: height,
    // No ticks: eighteen of them down a track this short is a dotted line
    // rather than a set of stops, and the reading beside the title says
    // exactly where the value is anyway.
    tick: const Color(0x00000000),
    // No minimum: a panel this narrow has no room for Tome's 160dp floor,
    // and the tile has already said how wide the line is.
    minWidth: 0,
  );
  if (ink == null) return style;
  // On a dressed row the whole track is redrawn in the row's own ink: the
  // travelled part and the grip at full voice, the rest of the line a
  // quarter of it, so the line reads as a line and the value as a value.
  return style.copyWith(
    active: style.active.copyWith(fill: ink),
    inactive: style.inactive.copyWith(fill: ink.withValues(alpha: 0.25)),
    thumb: style.thumb.copyWith(fill: ink, foreground: ink),
  );
}

/// A segmented control, cut down to the panel: the height the tile gave
/// it, and the inset and gap from the scale's own ladder rather than
/// Tome's desktop 3 and 8.
SegmentedControlStyle panelSegmentedStyle(
  Theme theme, {
  required double height,
}) {
  // Subtle: the box is the quietest wash the swatch has, inside its own
  // ring - and it is the ring's weight, not the wash, that says the wheel
  // is here. The track keeps the neutral soft trough the resolver gives
  // every rail.
  final style = theme.widgets.segmented.resolve(
    SemanticSwatch.primary,
    SurfaceVariant.subtle,
  );
  return style.copyWith(
    height: height,
    inset: theme.strokes.hairline,
    gap: theme.space.x2,
    // Room either side of the words: a segment whose label touches its own
    // edges reads as cramped however wide the track is.
    segmentPadding: EdgeInsets.symmetric(horizontal: theme.space.x3),
    // The panel's type at the resolver's colors: merged onto the resolved
    // styles rather than replacing them, because the rail hands these to
    // an AnimatedDefaultTextStyle, which *replaces* the surrounding style
    // rather than merging with it. A caption carries no color of its own,
    // so handing one over whole left the words at Flutter's default white
    // - which is why the segments were white on a light gray track.
    selectedStyle: style.selectedStyle.merge(theme.typography.caption),
    unselectedStyle: style.unselectedStyle.merge(theme.typography.caption),
  );
}
