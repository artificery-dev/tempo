import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

import 'scale.dart';
import 'settings/setting_tile.dart';
import 'wallpaper.dart';

/// A wheel list with a separate settings-style card and gap for each row.
class PanelList extends StatelessWidget {
  PanelList({
    required List<Widget> children,
    required this.itemExtent,
    this.extentOf,
    this.sectionOf,
    this.onActivate,
    this.onSelectionChanged,
    this.initialIndex = 0,
    this.initialTopRow = 0,
    this.autofocus = false,
    this.wrap = false,
    this.leadingGroupCount = 0,
    super.key,
  }) : itemCount = children.length,
       itemBuilder = ((context, index, selected) => children[index]);

  const PanelList.builder({
    required this.itemCount,
    required this.itemBuilder,
    required this.itemExtent,
    this.extentOf,
    this.sectionOf,
    this.onActivate,
    this.onSelectionChanged,
    this.initialIndex = 0,
    this.initialTopRow = 0,
    this.autofocus = false,
    this.wrap = false,
    this.leadingGroupCount = 0,
    super.key,
  });

  /// Alphabetical section labels; omit for track order, dates, and custom lists.
  final String? Function(int index)? sectionOf;

  final int itemCount;
  final WheelRowBuilder itemBuilder;
  final double itemExtent;
  final WheelExtentBuilder? extentOf;
  final ValueChanged<int>? onActivate;
  final ValueChanged<int>? onSelectionChanged;
  final int initialIndex;
  final int initialTopRow;
  final bool autofocus;
  final bool wrap;

  /// Navigation rows sharing a card before the separate item cards.
  final int leadingGroupCount;

  @override
  Widget build(BuildContext context) {
    final scale = UiScale.of(context);
    final gap = scale.cardGap / 2;
    bool first(int index) => index == 0 || index >= leadingGroupCount;
    bool startsItems(int index) =>
        leadingGroupCount > 0 && index == leadingGroupCount;
    return WheelList.builder(
      itemCount: itemCount,
      sectionOf: sectionOf,
      itemExtent: itemExtent,
      extentOf: (index) =>
          (extentOf?.call(index) ?? itemExtent) +
          (first(index) ? gap : 0) +
          (index == itemCount - 1 ? gap : 0) +
          (startsItems(index) ? gap * 2 : 0),
      initialIndex: initialIndex,
      initialTopRow: initialTopRow,
      autofocus: autofocus,
      wrap: wrap,
      onActivate: onActivate,
      onSelectionChanged: onSelectionChanged,
      itemBuilder: (context, index, selected) {
        final card = WheelRowSelection(
          selected: selected,
          child: SettingCard(
            first: first(index),
            last: index >= leadingGroupCount - 1 || index == itemCount - 1,
            lastOfPage: index == itemCount - 1,
            verticalGap: gap,
            selected: selected,
            child: itemBuilder(context, index, selected),
          ),
        );
        if (!startsItems(index)) return card;
        final theme = ThemeProvider.of(context);
        return Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: EdgeInsets.only(top: gap * 2),
                child: card,
              ),
            ),
            Positioned(
              top: gap,
              left: scale.cardGap,
              right: scale.cardGap,
              child: SizedBox(
                height: theme.strokes.hairline,
                child: ColoredBox(color: theme.palette.divider),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A separate card beneath each grid item's selection ring.
class GridCard extends StatelessWidget {
  const GridCard({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Backdropped.changes,
    builder: (context, _) {
      final theme = ThemeProvider.of(context);
      final surface = theme.widgets.surface.resolve(
        SemanticSwatch.neutral,
        SurfaceVariant.subtle,
      );
      return Padding(
        padding: EdgeInsets.all(theme.space.x2),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Backdropped.surfaceOf(
              theme.palette,
              focus: CoverFocus.of(context),
            ),
            borderRadius: theme.radii.medium,
            border: surface.border == null
                ? null
                : Border.all(
                    color: surface.border!,
                    width: theme.strokes.hairline,
                  ),
          ),
          child: child,
        ),
      );
    },
  );
}

/// A readable card for empty states and other centered page messages.
class ContentMessage extends StatelessWidget {
  const ContentMessage({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => Center(
    child: GridCard(
      child: Padding(
        padding: EdgeInsets.all(ThemeProvider.of(context).space.x4),
        child: child,
      ),
    ),
  );
}
