import '../power.dart';
import 'dart:async';

import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

import '../content_surface.dart';
import '../dock.dart';
import '../panel_bar.dart';
import '../routes.dart';
import '../scale.dart';
import '../wallpaper.dart';
import '../screens.dart';
import 'color_screen.dart';
import 'radio_screen.dart';
import '../services/services.dart';
import 'setting_bindings.dart';
import 'setting_node.dart';
import 'setting_tile.dart';
import 'settings.dart';

/// The pages a `screen:` item names, by key - the settings equivalent of
/// `MenuScreens`, and for the same reason: the tree names a page and this
/// is where that name becomes a widget, so a plugin can bring its own.
///
/// Empty to begin with. Every `screen:` item in the tree is a page that
/// has still to be written - the wallpaper picker, the Wi-Fi list, the
/// chord capture sheet - and until one is, its row opens the placeholder,
/// which says what the page will be and where it sits.
abstract final class SettingScreens {
  static final Map<String, Widget Function(SettingLocation)> _pages = {};

  static Iterable<String> get keys => _pages.keys;

  static bool knows(String key) => _pages.containsKey(key);

  static void register(String key, Widget Function(SettingLocation) page) =>
      _pages[key] = page;

  static Widget pageFor(SettingLocation entry) {
    final page = _pages[entry.node.screen];
    if (page != null) return page(entry);
    return PlaceholderScreen(title: entry.label, path: entry.path);
  }
}

/// One page of settings: a group's items, as tiles the wheel drives.
///
/// Every level of the settings tree is one of these, and the tree is what
/// says what is on it. A row's control is *in* the row - a switch is
/// thrown here, a slider is moved here - and only the items that genuinely
/// need a page of their own open one.
///
/// What a row can do is decided here, and honestly:
///
///  * an item whose `needs` this player cannot meet is not shown at all;
///  * an item whose `when` does not hold is shown, and disabled;
///  * an item whose `bind` key nobody has registered is shown, and
///    disabled - which is most of this tree today, and the truth about it.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({required this.entry, super.key});

  /// The group being shown.
  final SettingLocation entry;

  /// The root of the settings tree, for the dock's Settings app.
  static Widget root(Settings settings) =>
      SettingsScreen(entry: settings.tree.rootEntry);

  static Route<void> route(SettingLocation entry) => PanelRoute(
    settings: RouteSettings(name: entry.path),
    builder: (_) => SettingsScreen(entry: entry),
  );

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  /// The row that has the wheel, or null while the list has it.
  int? _captured;

  /// The hand on whichever track has the wheel. One is enough: a row that
  /// is not captured is not being turned.
  final WheelRailController _rail = WheelRailController();

  /// The page redraws when anything moves - not only when this screen was
  /// the one that moved it. A setting changed from the quick settings
  /// sheet, by a restored backup, or by the machine reporting a level back
  /// is the same setting, and the row showing it has to say so.
  StreamSubscription<SettingChange>? _changes;
  Settings? _store;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final store = SettingsScope.of(context);
    if (identical(store, _store)) return;
    _changes?.cancel();
    _store = store;
    _changes = store.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _changes?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (PlayerServicesScope.of(context).radios != null) {
      if (widget.entry.path == '/settings/connections/wifi') {
        return const RadioScreen();
      }
      if (widget.entry.path == '/settings/connections/bluetooth') {
        return const RadioScreen(bluetooth: true);
      }
    }
    final settings = SettingsScope.of(context);
    final scale = UiScale.of(context);
    final rows = _rows(settings);

    // No ground under the settings: the cards are the ground, and the
    // wallpaper runs between them.
    return PanelScreen(
      title: widget.entry.label,
      backdrop: Backdrop.clear,
      child: WheelList.builder(
        itemExtent: SettingTile.extentOf(scale),
        itemCount: rows.length,
        extentOf: (index) => _extentOf(settings, rows[index], scale),
        autofocus: true,
        onActivate: (index) =>
            _activate(context, settings, rows[index].entry, index),
        // Built rather than given whole: a row has to know whether the
        // wheel is on it, both to dress its card and to walk a
        // description too long for its line.
        itemBuilder: (context, index, selected) => WheelRowSelection(
          selected: selected,
          child: _row(settings, rows[index], index, selected: selected),
        ),
      ),
    );
  }

  /// One row, and - for the controls the wheel moves in place - the
  /// capture that takes the wheel while it is being moved.
  ///
  /// The list is driving until a row is activated; from then the capture
  /// has the jog, and the center or menu gives it back. Nothing else is
  /// taken: the volume keys still work with a slider open, because a
  /// player is a player before it is a settings screen.
  Widget _row(
    Settings store,
    _SettingRow row,
    int index, {
    required bool selected,
  }) {
    final entry = row.entry;
    Widget tile = SettingCard(
      first: row.first,
      last: row.last,
      lastOfPage: row.lastOfPage,
      selected: selected,
      child: _tile(store, entry, captured: _captured == index),
    );
    if (row.heading case final heading?) {
      tile = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingSectionHeading(heading),
          Expanded(child: tile),
        ],
      );
    }
    final node = store.tree.resolve(entry).node;
    if (!node.captures && !_movesInline(node)) return tile;
    return InputCapture(
      active: _captured == index,
      captures: const {WheelInput.wheel},
      debugLabel: 'setting:${entry.path}',
      onCapture: (intent) {
        if (intent is! JogIntent) return;
        // A track turns itself: the rail has the wheel's weight in it, and
        // the box has to travel between the options rather than hop. The
        // sliders and steppers are plain arithmetic.
        if (_movesInline(node)) {
          _rail.jog(intent);
        } else {
          _jog(store, entry, intent.amount * (intent.page ? 2 : 1));
        }
      },
      onRelease: (_) => setState(() => _captured = null),
      child: tile,
    );
  }

  /// Whether this item's answers are moved on the row itself.
  bool _movesInline(SettingNode node) =>
      (node.control == SettingControl.choice ||
          node.control == SettingControl.duration) &&
      node.layout.resolvesInline(node.optionLabels);

  /// A detent, while this row has the wheel.
  void _jog(Settings store, SettingLocation entry, int detents) {
    final target = store.tree.resolve(entry);
    final node = target.node;
    final value = store.value(target.path);

    switch (node.control) {
      case SettingControl.slider:
      case SettingControl.stepper:
        final step = (node.step ?? 1).toDouble();
        final min = (node.min ?? 0).toDouble();
        final max = (node.max ?? 100).toDouble();
        final now = (value as num?)?.toDouble() ?? min;
        final next = (now + detents * step).clamp(min, max);
        store.set(target.path, next.round());

      case SettingControl.choice:
      case SettingControl.duration:
        final options = node.options;
        if (options.isEmpty) return;
        final at = options.indexWhere((option) => option.value == value);
        final next = (at < 0 ? 0 : at + detents).clamp(0, options.length - 1);
        store.set(target.path, options[next].value);

      case _:
        return;
    }
  }

  /// The rows this page shows: everything the player can offer, in tree
  /// order, each knowing where it sits in its card.
  ///
  /// A divider is not a row and never was one to walk onto. It is where
  /// one card ends and the next begins - the rows between two of them are
  /// drawn as one card, and the gap between cards is the same air as at
  /// the panel's edges, so the wallpaper says what belongs with what
  /// without a single line being drawn.
  List<_SettingRow> _rows(Settings settings) {
    final shown = <SettingLocation>[];
    final breaks = <int>{};
    final headings = <int, String>{};
    for (final child in widget.entry.children) {
      if (child.node.kind == SettingKind.divider) {
        // A divider before anything, or two in a row, opens no card.
        if (shown.isNotEmpty) breaks.add(shown.length);
        headings.remove(shown.length);
        if (child.label.isNotEmpty) headings[shown.length] = child.label;
        continue;
      }
      if (!settings.visible(child.path, available: _capabilities)) continue;
      shown.add(child);
    }
    return [
      for (var index = 0; index < shown.length; index++)
        _SettingRow(
          entry: shown[index],
          heading: headings[index],
          first: index == 0 || breaks.contains(index),
          last: index == shown.length - 1 || breaks.contains(index + 1),
          lastOfPage: index == shown.length - 1,
        ),
    ];
  }

  /// What this player can do, for the items that name `needs`.
  Set<String> get _capabilities => SettingCapabilities.available.value;

  double _extentOf(Settings store, _SettingRow row, UiScale scale) {
    final node = store.tree.resolve(row.entry).node;
    final hasSummary = node.summary != null || row.entry.node.summary != null;
    final tile = switch (node.control) {
      SettingControl.slider => SettingSliderTile.extentOf(
        scale,
        summary: hasSummary,
      ),
      SettingControl.choice ||
      SettingControl.duration => SettingChoiceTile.extentOf(
        scale,
        inline: node.layout.resolvesInline(node.optionLabels),
        summary: hasSummary,
      ),
      _ => SettingTile.extentOf(scale, summary: hasSummary),
    };
    return tile +
        (row.heading == null ? 0 : SettingSectionHeading.extentOf(scale)) +
        SettingCard.extraOf(
          scale,
          first: row.first,
          lastOfPage: row.lastOfPage,
        );
  }

  Widget _tile(
    Settings store,
    SettingLocation entry, {
    required bool captured,
  }) {
    final shown = entry.node;
    final target = store.tree.resolve(entry);
    final node = target.node;
    final label = shown.label;
    final summary = shown.summary ?? node.summary;
    final enabled = store.enabled(target.path, bound: SettingBindings.keys);

    switch (node.kind) {
      // Never a row of its own - see [_rows].
      case SettingKind.divider:
        return const SizedBox.shrink();

      case SettingKind.group:
        return SettingTile(
          title: label,
          summary: summary,
          icon: MenuIcons.maybe(node.icon),
          trailing: _Chevron(),
        );

      case SettingKind.screen:
        return SettingPageTile(
          title: label,
          summary: summary,
          icon: MenuIcons.maybe(node.icon),
          enabled: enabled,
        );

      case SettingKind.info:
        return SettingInfoTile(
          title: label,
          summary: summary,
          icon: MenuIcons.maybe(node.icon),
          reading: '${store.value(target.path) ?? '-'}',
        );

      case SettingKind.action:
        return SettingActionTile(
          title: label,
          summary: summary,
          icon: MenuIcons.maybe(node.icon),
          danger: node.danger,
          enabled: node.bind != null && SettingBindings.knows(node.bind!),
        );

      case SettingKind.alias:
      case SettingKind.setting:
        return _control(store, target, label, summary, enabled, captured);
    }
  }

  Widget _control(
    Settings store,
    SettingLocation target,
    String label,
    String? summary,
    bool enabled,
    bool captured,
  ) {
    final node = target.node;
    final value = store.value(target.path);

    switch (node.control) {
      case SettingControl.toggle:
        return SettingSwitchTile(
          title: label,
          summary: summary,
          icon: MenuIcons.maybe(node.icon),
          value: value == true,
          enabled: enabled,
          onChanged: enabled ? (next) => store.set(target.path, next) : null,
        );

      case SettingControl.slider:
        return SettingSliderTile(
          title: label,
          icon: MenuIcons.maybe(node.icon),
          summary: summary,
          value: (value as num?)?.toDouble() ?? 0,
          min: (node.min ?? 0).toDouble(),
          max: (node.max ?? 100).toDouble(),
          step: node.step?.toDouble(),
          unit: node.unit,
          captured: captured,
          enabled: enabled,
          onChanged: enabled
              ? (next) => store.set(target.path, next.round())
              : null,
        );

      case SettingControl.stepper:
        return SettingStepperTile(
          title: label,
          summary: summary,
          value: (value as num?)?.round() ?? 0,
          min: (node.min ?? 0).round(),
          max: (node.max ?? 100).round(),
          step: (node.step ?? 1).round(),
          unit: node.unit,
          captured: captured,
          enabled: enabled,
        );

      case SettingControl.choice:
      case SettingControl.duration:
        return SettingChoiceTile(
          title: label,
          summary: summary,
          icon: MenuIcons.maybe(node.icon),
          value: value,
          options: node.options,
          layout: node.layout,
          enabled: enabled,
          captured: captured,
          controller: _movesInline(node) ? _rail : null,
          onChanged: enabled ? (next) => store.set(target.path, next) : null,
        );

      // The controls with nothing behind them yet: a keyboard, a swatch
      // grid, a clock, a chord capture. The row says what it is set to
      // and cannot be moved.
      case SettingControl.text:
        return SettingPageTile(
          title: label,
          summary: summary,
          reading: node.store == SettingStore.secret ? '••••' : '$value',
          enabled: false,
        );
      // A color opens the ramp itself: the row can say "Sky", but only
      // the color says what sky is.
      case SettingControl.color:
        return SettingPageTile(
          title: label,
          summary: summary,
          icon: MenuIcons.maybe(node.icon),
          reading: value == null ? null : SettingColorScreen.labelOf('$value'),
          enabled: enabled,
        );

      case SettingControl.time:
      case SettingControl.chord:
      case null:
        return SettingPageTile(
          title: label,
          summary: summary,
          reading: value == null ? null : '$value',
          enabled: false,
        );
    }
  }

  void _activate(
    BuildContext context,
    Settings store,
    SettingLocation entry,
    int index,
  ) {
    // One push per activation, however fast the button is pressed.
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;

    final target = store.tree.resolve(entry);
    final node = target.node;
    if (!store.enabled(target.path, bound: SettingBindings.keys) &&
        node.kind != SettingKind.group) {
      return;
    }

    switch (node.kind) {
      case SettingKind.divider:
      case SettingKind.info:
        return;

      case SettingKind.group:
        Navigator.of(context).push(SettingsScreen.route(entry));

      case SettingKind.screen:
        Navigator.of(context).push(
          PanelRoute(
            settings: RouteSettings(name: entry.path),
            builder: (_) => SettingScreens.pageFor(entry),
          ),
        );

      case SettingKind.action:
        _invoke(context, store, target);

      case SettingKind.alias:
      case SettingKind.setting:
        _move(context, store, target, index);
    }
  }

  /// A row that holds a value, activated: thrown where it stands, opened
  /// as a page of answers, or given the wheel.
  void _move(
    BuildContext context,
    Settings store,
    SettingLocation target,
    int index,
  ) {
    final node = target.node;
    switch (node.control) {
      case SettingControl.toggle:
        store.set(target.path, store.value(target.path) != true);

      case SettingControl.slider:
      case SettingControl.stepper:
        setState(() => _captured = index);

      case SettingControl.choice:
      case SettingControl.duration:
        if (node.layout.resolvesInline(node.optionLabels)) {
          setState(() => _captured = index);
        } else {
          Navigator.of(context).push(SettingOptionsScreen.route(target));
        }

      case SettingControl.color:
        Navigator.of(context).push(SettingColorScreen.route(target));

      // Nothing to move yet.
      case SettingControl.text:
      case SettingControl.time:
      case SettingControl.chord:
      case null:
        return;
    }
  }

  void _invoke(BuildContext context, Settings store, SettingLocation target) {
    final node = target.node;
    final bind = node.bind;
    if (bind == null) return;
    if (bind == 'power.restart' || bind == 'power.shutdown') {
      Navigator.of(context).push(
        PowerDialog.route(
          initialCommand: bind == 'power.restart'
              ? PowerCommand.restart
              : PowerCommand.shutDown,
        ),
      );
      return;
    }
    final confirm = node.confirm;
    if (confirm == null) {
      SettingBindings.invoke(bind, target.path);
      return;
    }
    Navigator.of(context).push(
      SettingConfirmScreen.route(
        entry: target,
        onConfirm: () => SettingBindings.invoke(bind, target.path),
      ),
    );
  }
}

/// One row of a settings page: the item, and where it sits in the card
/// its group is drawn as.
@immutable
class _SettingRow {
  const _SettingRow({
    this.heading,
    required this.entry,
    required this.first,
    required this.last,
    required this.lastOfPage,
  });

  final SettingLocation entry;
  final String? heading;

  /// Whether this row opens its card, closes it, or both - a group of one
  /// is both.
  final bool first;
  final bool last;

  /// The foot of the page, which is the only row with air under it.
  final bool lastOfPage;
}

class _Chevron extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    return Icon(theme.icons.chevronRight, size: theme.sizes.iconSmall);
  }
}

/// A setting's answers, one to a row, with the current one marked.
///
/// The page a `choice` opens when its answers are too many or too wordy to
/// ride the row - and where an answer's own line of explanation has room
/// to be read.
class SettingOptionsScreen extends StatelessWidget {
  const SettingOptionsScreen({required this.entry, super.key});

  final SettingLocation entry;

  static Route<void> route(SettingLocation entry) => PanelRoute(
    settings: RouteSettings(name: '${entry.path}/options'),
    builder: (_) => SettingOptionsScreen(entry: entry),
  );

  @override
  Widget build(BuildContext context) {
    final store = SettingsScope.of(context);
    final theme = ThemeProvider.of(context);
    final scale = UiScale.of(context);
    final options = entry.node.options;
    final current = store.value(entry.path);

    return PanelScreen(
      title: entry.label,
      child: PanelList(
        itemExtent: SettingTile.extentOf(scale),
        extentOf: (index) => SettingTile.extentOf(
          scale,
          summary: options[index].summary != null,
        ),
        autofocus: true,
        initialIndex: options
            .indexWhere((option) => option.value == current)
            .clamp(0, options.length - 1),
        onActivate: (index) {
          store.set(entry.path, options[index].value);
          Navigator.of(context).maybePop();
        },
        children: [
          for (final option in options)
            SettingTile(
              title: option.label,
              summary: option.summary,
              trailing: option.value == current
                  ? Icon(theme.icons.confirm, size: theme.sizes.iconSmall)
                  : null,
            ),
        ],
      ),
    );
  }
}

/// The question a destructive action asks first.
///
/// A screen rather than a dialog: the wheel is the only way around, and a
/// list of two rows is the shape it drives best. Backing out with menu is
/// the same as saying no, which is the answer a hand reaches for.
class SettingConfirmScreen extends StatelessWidget {
  const SettingConfirmScreen({
    required this.entry,
    required this.onConfirm,
    super.key,
  });

  final SettingLocation entry;
  final VoidCallback onConfirm;

  static Route<void> route({
    required SettingLocation entry,
    required VoidCallback onConfirm,
  }) => PanelRoute(
    settings: RouteSettings(name: '${entry.path}/confirm'),
    builder: (_) => SettingConfirmScreen(entry: entry, onConfirm: onConfirm),
  );

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final scale = UiScale.of(context);

    return PanelScreen(
      title: entry.label,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.all(theme.space.x4),
            child: BodyText(entry.node.confirm ?? 'Are you sure?'),
          ),
          Expanded(
            child: PanelList(
              itemExtent: SettingTile.extentOf(scale),
              autofocus: true,
              onActivate: (index) {
                final navigator = Navigator.of(context);
                if (index == 1) onConfirm();
                navigator.maybePop();
              },
              children: [
                const SettingTile(title: 'Cancel'),
                SettingTile(
                  title: entry.label,
                  trailing: entry.node.danger
                      ? Icon(
                          theme.icons.warning,
                          size: theme.sizes.iconSmall,
                          color: theme.palette.error.s500,
                        )
                      : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
