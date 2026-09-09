import 'dialog_list.dart';
import 'dart:ui' show lerpDouble;

import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

import 'appearance.dart';
import 'panel_bar.dart';
import 'settings/settings.dart';
import 'list_row.dart';
import 'applet.dart';
import 'services/services.dart';
import 'menu/menu.dart';
import 'routes.dart';
import 'scale.dart';
import 'status.dart';
import 'wallpaper.dart';

/// How the switcher behaves. Settings > Home & Menus > Dock moves these.
abstract final class DockOptions {
  /// Whether the apps turn past like covers, or slide flat like pages.
  static final flow = ValueNotifier<bool>(true);

  /// Whether back, with nothing left to back out of, brings the dock up.
  ///
  /// On, an app's root has a way out through the same key that got you
  /// there. Off, the root is the end of the road and the dock is the
  /// Power button's double-tap - which is what someone who reaches for that hold
  /// anyway would rather have, since it stops a stray back from throwing
  /// the app away.
  static final atRoot = ValueNotifier<bool>(true);
}

/// The dock: the top of the system menu as a row of icons along the
/// bottom of the screen, brought up over any screen by double-tapping Power - and
/// the switcher between the apps behind them.
///
/// Its entries are data, like the menu they come from: [required] is
/// always there; [pins] are the apps the user has put
/// beside them, Files to begin with. What is shown is [entries], resolved
/// against the menu tree, so a pin that names nothing is simply absent.
///
/// Every entry is an app with a navigator of its own, kept alive whether
/// or not it is on stage, so switching between them never loses anyone's
/// place. [selected] is the one on stage; while the dock is up the screens
/// step back to fit between the status bar and the dock - [bandExtent] and
/// [dockExtent] say how much of the panel each takes - and flow past like
/// covers as the box moves, the app under it flat in the middle, its
/// neighbors turned away on either side.
abstract final class MenuDock {
  /// Whether the dock is up. Double-tapping Power flips it; choosing an item puts
  /// it away; back at the root of any app brings it up.
  static final shown = ValueNotifier<bool>(false);

  /// The app on stage, whose navigator is the live one. Null before the
  /// shell has said, which means the first entry: home.
  static final selected = ValueNotifier<MenuLocation?>(null);

  /// Where the box is along the dock, in items from the first: a whole
  /// number on an item, and the way between two as it slides. Set while
  /// the dock is up, and null while it is not. What the stage's cover
  /// flow follows.
  static final position = ValueNotifier<double?>(null);

  /// The dock's items, in order, as the shell has resolved them.
  static final current = ValueNotifier<List<MenuLocation>>(const []);

  /// The item under the box while the dock is up, and null while it is
  /// not: what the status bar names while the covers are out.
  static final preview = ValueNotifier<MenuLocation?>(null);

  /// The four that are always there, in order.
  static const required = ['/home', '/apps', '/library', '/settings'];

  /// The apps the user has pinned beside them, by menu path.
  static final pins = ValueNotifier<List<String>>(const ['/apps/files']);
  static const pinsPath = '/settings/controls/navigation/dock/pins';
  static const orderPath = '/settings/controls/navigation/order';

  /// Saved ordering includes the built-in entries as well as app pins.
  static final order = ValueNotifier<List<String>>(const []);

  /// Unpinned apps opened from Apps keep their own stage for this session.
  static final opened = ValueNotifier<List<String>>(const []);

  static final _closeRequest = ValueNotifier<MenuLocation?>(null);

  /// End an app's navigation session while retaining its pin, if any.
  static void close(MenuLocation entry) {
    if (required.contains(entry.path)) return;
    _closeRequest.value = null;
    _closeRequest.value = entry;
  }

  static void open(MenuLocation entry) {
    if (!pinned(entry) && !opened.value.contains(entry.path)) {
      opened.value = [...opened.value, entry.path];
    }
    select(entry);
  }

  /// The dock's weight: every rail's, [panelRailWeight]. No give - the
  /// ends are the ends.
  static const physics = WheelRailPhysics(weight: panelRailWeight, give: 0);

  /// Whether the dock went away on a choice, in which case the stage keeps
  /// the flow until it has grown back to full size, rather than on a plain
  /// dismissal, where the app on stage comes back at once.
  static bool _chosen = false;

  static void toggle() => shown.value = !shown.value;

  /// Everything back to the start: the dock away, home on stage, no flow.
  /// For a test, which shares these with every other test in its file.
  static void reset() {
    shown.value = false;
    selected.value = null;
    opened.value = const [];
    order.value = const [];
    _clearFlow();
  }

  /// Put [entry]'s app on stage and the dock away.
  static void select(MenuLocation entry) {
    selected.value = entry;
    if (!shown.value) {
      _clearFlow();
      return;
    }
    _chosen = true;
    // The flow closes on the chosen cover, exactly: wherever the box was
    // resting - a hair off its notch, or still settling - the cover under
    // it is the middle from here on, or it would be carried off with the
    // neighbors as the stage grows back.
    final index = current.value.indexOf(entry);
    if (index >= 0) position.value = index.toDouble();
    shown.value = false;
  }

  static void _clearFlow() {
    _chosen = false;
    position.value = null;
    preview.value = null;
  }

  /// The margin the bar and the dock keep from the panel's edges while
  /// the dock is up.
  static double margin(Theme theme) => theme.space.x2;

  /// The gap the page keeps from the bar and the dock: a few pixels, on a
  /// panel this small.
  static double gap(Theme theme) => theme.space.x1;

  /// How much of the panel's height the status bar takes while the dock
  /// is up: itself - it keeps to the top edge - and the gap below.
  ///
  /// Measured at the chrome scale, because that is what the band is drawn
  /// at: the page below it is the only part of this that grows.
  static double bandExtent(Theme theme) =>
      chromeScale.barHeight + gap(Appearance.chromeOf(theme));

  /// How much of the panel's height the dock takes: the rail in its
  /// padding, the margin below and the gap above - at the chrome scale,
  /// for the same reason.
  static double dockExtent(Theme theme) {
    final chrome = Appearance.chromeOf(theme);
    return margin(chrome) +
        2 * chrome.space.x1 +
        chrome.widgets.segmented.resolve().height +
        gap(chrome);
  }

  /// Whether [entry] has a place in the dock of its own - one of the four
  /// that are always there, or a pinned app - and so a stage and a stack
  /// of its own that a menu should hand over to rather than open a copy.
  static bool pinned(MenuLocation entry) =>
      required.contains(entry.path) || pins.value.contains(entry.path);

  /// What the dock shows, in order, out of [tree].
  static List<MenuLocation> entries(MenuTree tree) {
    final available = <String, MenuLocation>{
      for (final path in {...required, ...pins.value, ...opened.value})
        path: ?tree.at(path),
    };
    return [
      for (final path in order.value) ?available.remove(path),
      ...available.values,
    ];
  }
}

/// The glyphs the built-in menu items wear, by their hint: Lucide's for
/// now, until there is art.
abstract final class MenuIcons {
  static const _byHint = <String, IconData>{
    'house': LucideIcons.house,
    'layout-grid': LucideIcons.layoutGrid,
    'library': LucideIcons.library,
    'settings': LucideIcons.settings,
    'bug': LucideIcons.bug,
    'info': LucideIcons.info,
    'folder': LucideIcons.folder,
    'shopping-bag': LucideIcons.shoppingBag,
    'music': LucideIcons.music,
    'list-music': LucideIcons.listMusic,
    'disc': LucideIcons.disc3,
    'mic-vocal': LucideIcons.micVocal,
    'refresh-cw': LucideIcons.refreshCw,
    'headphones': LucideIcons.headphones,
    'podcast': LucideIcons.podcast,
    'mic': LucideIcons.mic,
    'book-audio': LucideIcons.bookAudio,
    'tv': LucideIcons.tv,
    'film': LucideIcons.film,
    'clapperboard': LucideIcons.clapperboard,
    'power': LucideIcons.power,
    // The settings tree's own.
    'palette': LucideIcons.palette,
    'paintbrush': LucideIcons.paintbrush,
    'swatch-book': LucideIcons.swatchBook,
    'image': LucideIcons.image,
    'panel-top': LucideIcons.panelTop,
    'contrast': LucideIcons.contrast,
    'text': LucideIcons.type,
    'sun': LucideIcons.sun,
    'moon': LucideIcons.moon,
    'circle-dot': LucideIcons.circleDot,
    'circle': LucideIcons.circle,
    'vibrate': LucideIcons.vibrate,
    'command': LucideIcons.command,
    'sliders-horizontal': LucideIcons.slidersHorizontal,
    'sliders-vertical': LucideIcons.slidersVertical,
    'list': LucideIcons.list,
    'volume-2': LucideIcons.volume2,
    'volume-1': LucideIcons.volume1,
    'play': LucideIcons.play,
    'wifi': LucideIcons.wifi,
    'bluetooth': LucideIcons.bluetooth,
    'usb': LucideIcons.usb,
    'share-2': LucideIcons.share2,
    'folder-open': LucideIcons.folderOpen,
    'radio': LucideIcons.radio,
    'terminal': LucideIcons.terminal,
    'battery-charging': LucideIcons.batteryCharging,
    'hard-drive': LucideIcons.hardDrive,
    'archive': LucideIcons.archive,
    'eject': LucideIcons.eject,
    'rotate-cw': LucideIcons.rotateCw,
    'puzzle': LucideIcons.puzzle,
    'clock': LucideIcons.clock,
    'lock': LucideIcons.lock,
    'lock-keyhole': LucideIcons.lockKeyhole,
    'shield': LucideIcons.shield,
    'cpu': LucideIcons.cpu,
    'search': LucideIcons.search,
    'trash-2': LucideIcons.trash2,
  };

  /// The glyph for [hint], or a placeholder for one nobody has drawn.
  static IconData of(String? hint) => _byHint[hint] ?? LucideIcons.circleDashed;

  /// The glyph for [hint], or nothing at all where a row names none.
  ///
  /// The placeholder is for a row that *should* have a glyph and has not
  /// been given one yet. A settings row that names none wants no leading
  /// column at all, and a dashed circle beside every switch on a screen
  /// is noise pretending to be information.
  static IconData? maybe(String? hint) =>
      hint == null ? null : (_byHint[hint] ?? LucideIcons.circleDashed);
}

// -- the bar's chrome --------------------------------------------------------

/// What a page tells the shell about itself: its name for the status bar,
/// whether the bar paints a ground over it - home's does not, and the
/// bar's readings sit on the wallpaper there - and what the page is made
/// of.
@immutable
class BarChrome {
  const BarChrome({
    this.title = '',
    this.ground = true,
    this.backdrop = Backdrop.clear,
    this.untitled = false,
    this.clock = false,
    this.visible = true,
  });

  final String title;
  final bool ground;
  final Backdrop backdrop;

  /// Whether the bar shows no name at all for this page - not even the
  /// app's, which an empty [title] would otherwise fall back to. Now
  /// playing on home: the cover says what this is.
  final bool untitled;

  /// Whether the title slot shows the time of day instead of a name.
  /// Home while something plays: the clock that stood in the middle of
  /// the page moves up here, where the page's name would be.
  final bool clock;

  /// Immersive video can hide the bar while keeping it available in the dock.
  final bool visible;

  @override
  bool operator ==(Object other) =>
      other is BarChrome &&
      other.title == title &&
      other.ground == ground &&
      other.backdrop == backdrop &&
      other.untitled == untitled &&
      other.clock == clock &&
      other.visible == visible;

  @override
  int get hashCode =>
      Object.hash(title, ground, backdrop, untitled, clock, visible);

  /// What the title slot reads for a page: nothing, the page's own name,
  /// or [fallback] (the app's) when it gave none.
  String titleOr(String fallback) =>
      untitled || clock ? '' : (title.isEmpty ? fallback : title);
}

/// The app a page belongs to: the chrome its top page has published, and
/// the observer its navigator reports to, so a page can know when it is
/// the top of that app. The shell puts one around each app's navigator.
class DockItemScope extends InheritedWidget {
  const DockItemScope({
    required this.entry,
    required this.chrome,
    required this.observer,
    required super.child,
    super.key,
  });

  final MenuLocation entry;
  final ValueNotifier<BarChrome> chrome;
  final RouteObserver<PageRoute<dynamic>> observer;

  static DockItemScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DockItemScope>();

  @override
  bool updateShouldNotify(DockItemScope oldWidget) =>
      entry != oldWidget.entry ||
      chrome != oldWidget.chrome ||
      observer != oldWidget.observer;
}

/// The chrome of each app's top page, by the app's path, kept across
/// rebuilds so a bar that has just come up knows what it is over.
abstract final class DockChrome {
  static final _byItem = <String, ValueNotifier<BarChrome>>{};

  static ValueNotifier<BarChrome> of(String path) =>
      _byItem.putIfAbsent(path, () => ValueNotifier(const BarChrome()));
}

/// Publishes [chrome] to the app this page is in whenever the page is the
/// top of that app's navigator - on push, when what was over it pops, and
/// when the chrome itself changes. A page shown outside an app (a test, a
/// cover of nothing) publishes nowhere.
class PublishChrome extends StatefulWidget {
  const PublishChrome({required this.chrome, required this.child, super.key});

  final BarChrome chrome;
  final Widget child;

  @override
  State<PublishChrome> createState() => _PublishChromeState();
}

class _PublishChromeState extends State<PublishChrome> with RouteAware {
  PageRoute<dynamic>? _route;
  RouteObserver<PageRoute<dynamic>>? _observer;
  ValueNotifier<BarChrome>? _target;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = DockItemScope.maybeOf(context);
    _target = scope?.chrome;
    final observer = scope?.observer;
    final route = ModalRoute.of(context);
    if (observer != null &&
        route is PageRoute<dynamic> &&
        (!identical(route, _route) || !identical(observer, _observer))) {
      _observer?.unsubscribe(this);
      _route = route;
      _observer = observer;
      observer.subscribe(this, route);
    }
    _publishIfTop();
  }

  @override
  void didUpdateWidget(PublishChrome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.chrome != oldWidget.chrome) _publishIfTop();
  }

  @override
  void dispose() {
    _observer?.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPush() => _publish();

  @override
  void didPopNext() => _publish();

  void _publishIfTop() {
    if (_route?.isCurrent ?? false) _publish();
  }

  void _publish() {
    final target = _target;
    if (target == null) return;
    // After the frame: this may be the middle of a build, and the bar
    // rebuilds on it.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) target.value = widget.chrome;
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

// -- the shell ---------------------------------------------------------------

/// Everything on the panel: the wallpaper, the apps on their stage, the
/// status bar over them, and the dock. `TempoApp`'s home.
class DockShell extends StatefulWidget {
  const DockShell({super.key});

  @override
  State<DockShell> createState() => _DockShellState();
}

class _DockShellState extends State<DockShell> {
  late List<MenuLocation> _entries;

  /// One [Applet] per entry, kept for as long as the app is on the dock:
  /// its navigator, focus scope and route observer, and its state.
  final _applets = <String, Applet>{};
  late AppletStore _store;

  /// Which app was on stage before this one, so it can be put back to its
  /// own root when the menu is not set to remember places.
  MenuLocation? _left;

  @override
  void initState() {
    super.initState();
    _entries = _resolve();
    MenuDock.pins.addListener(_refresh);
    MenuDock.order.addListener(_refresh);
    MenuDock.opened.addListener(_refresh);
    MenuDock._closeRequest.addListener(_closeApp);
    MenuDock.selected.addListener(_selectedChanged);
    MenuDock.shown.addListener(_shownChanged);
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      MenuDock.current.value = _entries;
      MenuDock.selected.value ??= systemMenu.at('/home')!;
      _focusSelected();
    });
  }

  /// The dock put away: the wheel goes back to the app on stage after the
  /// frame - to what its scope last had, or the first thing in it.
  void _shownChanged() {
    if (MenuDock.shown.value) return;
    SchedulerBinding.instance.addPostFrameCallback((_) => _focusSelected());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Where the applets keep what they remember: wherever the machine's
    // services say, which off the device is nowhere.
    _store = PlayerServicesScope.of(context).applets;
  }

  @override
  void dispose() {
    MenuDock.pins.removeListener(_refresh);
    MenuDock.order.removeListener(_refresh);
    MenuDock.opened.removeListener(_refresh);
    MenuDock._closeRequest.removeListener(_closeApp);
    MenuDock.selected.removeListener(_selectedChanged);
    MenuDock.shown.removeListener(_shownChanged);
    for (final applet in _applets.values) {
      applet.dispose();
    }
    super.dispose();
  }

  List<MenuLocation> _resolve() => MenuDock.entries(systemMenu);

  void _refresh() {
    setState(() => _entries = _resolve());
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) MenuDock.current.value = _entries;
    });
  }

  void _closeApp() {
    final entry = MenuDock._closeRequest.value;
    if (entry == null) return;
    final applet = _applets.remove(entry.path);
    MenuDock.opened.value = [...MenuDock.opened.value]..remove(entry.path);
    if (MenuDock.selected.value == entry) {
      MenuDock.selected.value = systemMenu.at('/home');
    }
    setState(() {});
    // Release the old scope only after its navigator has unmounted.
    SchedulerBinding.instance.addPostFrameCallback((_) => applet?.dispose());
  }

  MenuLocation get _selected =>
      MenuDock.selected.value ??
      (_entries.isEmpty ? systemMenu.rootEntry : _entries.first);

  void _selectedChanged() {
    _forget(_left);
    _left = MenuDock.selected.value;
    setState(() {});
    SchedulerBinding.instance.addPostFrameCallback((_) => _focusSelected());
  }

  /// The app just left, back at its own root.
  ///
  /// Only where the menu is set not to remember: an applet's navigator
  /// lives as long as the app is on the dock, so remembering is what
  /// happens by *itself* and forgetting is the work. Popped on the way
  /// out rather than on the way back in, so nothing is seen unwinding.
  void _forget(MenuLocation? entry) {
    if (entry == null || MenuOptions.remember.value) return;
    final navigator = _applets[entry.path]?.navigator.currentState;
    navigator?.popUntil((route) => route.isFirst);
  }

  /// The wheel to the app on stage: its scope's last focus, or the first
  /// thing in it that takes focus if it has never had any.
  void _focusSelected() {
    if (!mounted || MenuDock.shown.value) return;
    final scope = _applets[_selected.path]?.scope;
    if (scope == null) return;
    scope.requestFocus();
    if (scope.focusedChild == null) scope.nextFocus();
  }

  Applet _appletFor(MenuLocation entry) => _applets.putIfAbsent(
    entry.path,
    () => Applet(entry: entry, store: _store),
  );

  /// Back, at the root of an app, is the switcher: there is nothing to
  /// back out of but the app itself.
  void _back(Applet applet) {
    final navigator = applet.navigator.currentState;
    if (navigator != null && navigator.canPop()) {
      navigator.pop();
    } else if (DockOptions.atRoot.value) {
      MenuDock.shown.value = true;
    }
  }

  /// [child], pinned to the chrome scale or left at the chosen one.
  static Widget _scaled({required bool pinned, required Widget child}) =>
      pinned ? FixedScale(scale: chromeScale, child: child) : child;

  Widget _app(MenuLocation entry) {
    final applet = _appletFor(entry);
    // Settings draws at the chrome scale, not the chosen one: it is where
    // the size is chosen from. Wrapped outside the app's navigator, so
    // every page it pushes is pinned with it.
    final pinned = entry.node.screen == MenuScreens.settings;
    return AppletScope(
      applet: applet,
      child: DockItemScope(
        entry: entry,
        chrome: DockChrome.of(entry.path),
        observer: applet.observer,
        child: Actions(
          actions: {
            WheelBackIntent: CallbackAction<WheelBackIntent>(
              onInvoke: (_) {
                _back(applet);
                return null;
              },
            ),
          },
          child: FocusScope(
            node: applet.scope,
            child: _scaled(
              pinned: pinned,
              child: Navigator(
                key: applet.navigator,
                observers: [applet.observer],
                onGenerateRoute: (settings) => PanelRoute<void>(
                  settings: settings,
                  builder: (_) =>
                      MenuScreens.pageFor(entry) ??
                      PanelScreen(
                        title: entry.label,
                        child: Center(
                          child: Icon(MenuIcons.of(entry.node.hint), size: 48),
                        ),
                      ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final apps = [
      for (final entry in _entries)
        if (MenuScreens.pageFor(entry) != null || MenuScreens.isAction(entry))
          entry,
    ];
    return Stack(
      fit: StackFit.expand,
      children: [
        const Wallpaper(),
        // The bar, and the pills that hero into it, are the stage's: in
        // the panel's coordinates, over the frame the apps are fitted to.
        _Stage(apps: apps, selected: _selected, app: _app),
        const DockBar(),
      ],
    );
  }
}

// -- the stage and the flow -------------------------------------------------

/// The apps, on a stage that steps back while the dock is up: shrunk to
/// fit whole between the status bar and the dock, and flowing past like
/// covers as the box moves along the dock - the app under it flat in the
/// middle, its neighbors turned away on either side. Forward again to
/// full size when something is chosen or the dock is put away. Every app
/// stays mounted throughout, in one unchanging tree, so nothing in any of
/// them is ever rebuilt by the stage.
class _Stage extends StatelessWidget {
  const _Stage({required this.apps, required this.selected, required this.app});

  final List<MenuLocation> apps;
  final MenuLocation selected;
  final Widget Function(MenuLocation entry) app;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final above = MenuDock.bandExtent(theme);
    final below = MenuDock.dockExtent(theme);

    return LayoutBuilder(
      builder: (context, constraints) {
        final panel = constraints.biggest;
        return _EasedFlowPosition(
          resting: apps.indexOf(selected).toDouble(),
          child: ValueListenableBuilder(
            valueListenable: MenuDock.shown,
            // 0 is the app filling the panel, 1 is the flow between the bar
            // and the dock; the frame it is fitted into moves between the
            // two, and the apps scale to it.
            builder: (context, shown, _) => TweenAnimationBuilder<double>(
              tween: Tween(end: shown ? 1.0 : 0.0),
              duration: theme.motion.standard,
              curve: theme.motion.move,
              // Grown back after a choice: the chosen app is on stage now,
              // and the flow it grew out of can go.
              onEnd: () {
                if (!MenuDock.shown.value) MenuDock._clearFlow();
              },
              // The stage is always the whole panel, whatever the frame
              // inside it comes to: fitted loosely it would shrink to the
              // page and sit in the corner.
              builder: (context, t, _) => SizedBox.fromSize(
                size: panel,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Padding(
                      padding: EdgeInsets.only(
                        top: t * above,
                        bottom: t * below,
                      ),
                      child: FittedBox(
                        key: DockStage.stageKey,
                        fit: BoxFit.contain,
                        child: SizedBox.fromSize(
                          size: panel,
                          child: _Flow(
                            apps: apps,
                            selected: selected,
                            app: app,
                            t: t,
                            panel: panel,
                          ),
                        ),
                      ),
                    ),
                    // The bar and the pills that hero into its title slot are
                    // one piece of chrome: pinned together, or a cover's name
                    // arrives at the bar in a size the bar is not.
                    FixedScale(
                      scale: chromeScale,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          const StatusBar(),
                          _Pills(
                            apps: apps,
                            t: t,
                            panel: panel,
                            above: above,
                            below: below,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// One animated position shared by the page bodies and their title pills.
/// New detents retarget from the current frame, so rapid turns stay continuous.
class _EasedFlowPosition extends StatelessWidget {
  const _EasedFlowPosition({required this.resting, required this.child});
  final double resting;
  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: MenuDock.position,
    builder: (context, target, _) => TweenAnimationBuilder<double>(
      tween: Tween(begin: target ?? resting, end: target ?? resting),
      duration: DockStage.catchUpDuration,
      curve: Curves.easeOutCubic,
      child: child,
      builder: (context, at, child) =>
          _FlowPosition(position: target == null ? null : at, child: child!),
    ),
  );
}

class _FlowPosition extends InheritedWidget {
  const _FlowPosition({required this.position, required super.child});
  final double? position;

  static double? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_FlowPosition>()?.position;

  @override
  bool updateShouldNotify(_FlowPosition oldWidget) =>
      position != oldWidget.position;
}

/// The stage's names, for tests.
abstract final class DockStage {
  static const catchUpDuration = Duration(milliseconds: 180);

  /// The frame the apps are fitted into.
  static const stageKey = Key('DockStage');
}

class _Flow extends StatelessWidget {
  const _Flow({
    required this.apps,
    required this.selected,
    required this.app,
    required this.t,
    required this.panel,
  });

  final List<MenuLocation> apps;
  final MenuLocation selected;
  final Widget Function(MenuLocation entry) app;

  /// How far into the flow: 0 is the app on stage filling the frame
  /// alone, 1 is the covers.
  final double t;

  /// The frame's full size, which every app is laid out at.
  final Size panel;

  /// How far a neighbor stands from the middle, as a share of the width:
  /// clear of the middle cover's edge, since a cover no longer shows what
  /// is behind it. The middle cover fills the frame's height, and being
  /// the panel's shape is narrower than the panel: the room either side is
  /// where its neighbors show.
  static const double spread = 0.78;

  /// And when the covers do not turn: a whole width apart, so the apps sit
  /// edge to edge like pages rather than overlapping where the turn would
  /// have carried them clear.
  static const double flatSpread = 1.0;

  /// How far a neighbor is turned away, in radians: about sixty degrees.
  static const double turn = 1.05;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: DockOptions.flow,
      builder: (context, _, _) => Builder(
        builder: (context) {
          final position = _FlowPosition.of(context);
          // Where the middle is: the box while the covers are out, the
          // app on stage otherwise.
          final at = position ?? apps.indexOf(selected).toDouble();
          final flowing = position != null;
          final turning = DockOptions.flow.value;

          // Every app is always in the stack, in the same place, under the
          // same wrappers - only their arguments change - so an app is
          // never rebuilt by coming on or going off stage. Painted far to
          // near, so the middle cover is on top.
          final order = [for (var i = 0; i < apps.length; i++) i]
            ..sort((a, b) => (b - at).abs().compareTo((a - at).abs()));

          // Every app is always in the stack, in the same place, under the
          // same wrappers - only their arguments change - so an app is
          // never rebuilt by coming on or going off stage.
          return Stack(
            fit: StackFit.expand,
            children: [
              for (final i in order)
                KeyedSubtree(
                  key: ValueKey(apps[i].path),
                  child: _placed(context, i, at, flowing, turning),
                ),
            ],
          );
        },
      ),
    );
  }

  /// App [i] where its cover is: flat and whole in the middle; turned,
  /// smaller and dimmer to the sides - turned the cover-flow way, the
  /// edge beside the middle the far one, so a cover sliding into the
  /// middle turns to face you about its own upright. All of it eased in
  /// and out with the flow, so at rest the app on stage is simply the
  /// page. Only the app on stage has the wheel; the covers are seen and
  /// not touched.
  Widget _placed(
    BuildContext context,
    int i,
    double at,
    bool flowing,
    bool turning,
  ) {
    final entry = apps[i];
    final cover = CoverGeometry(
      index: i,
      at: at,
      t: t,
      panel: panel,
      turning: turning,
    );
    final onStage = entry == selected;
    // In reach: the one under the box, the one either side, and the one
    // beyond in the direction of travel.
    final inReach = flowing ? cover.d.abs() < 2 : onStage;

    return Offstage(
      offstage: !inReach,
      child: ExcludeFocus(
        excluding: !onStage,
        child: IgnorePointer(
          ignoring: !onStage || flowing,
          child: Opacity(
            opacity: cover.opacity,
            child: Transform(
              transform: cover.transform,
              alignment: Alignment.center,
              child: ClipRRect(
                borderRadius: cover.corners(chromeScale.barHeight / 4),
                child: CoverFocus(focus: cover.focus, child: app(entry)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Where cover [index] is in the flow, at [at] with the flow [t] of the
/// way out: the one geometry the apps are drawn with.
class CoverGeometry {
  CoverGeometry({
    required this.index,
    required this.at,
    required this.t,
    required this.panel,
    this.turning = true,
  });

  final int index;
  final double at;
  final double t;
  final Size panel;

  /// Whether the covers turn and shrink to the sides, or simply slide
  /// past flat. Off, the switcher is a row of pages: still the same
  /// travel, the same middle, and the same reach - only nothing is drawn
  /// at an angle it was not laid out at.
  final bool turning;

  double get d => index - at;
  double get side => d.clamp(-1.0, 1.0);
  double get away => side.abs();

  /// How far the cover stands from the middle, along the panel. A
  /// neighbor comes in from off the panel on its own side as the flow
  /// opens - a whole width out at 0 - and settles at its spread by 1;
  /// going back, it leaves the way it came. The middle never moves, and
  /// a cover a hair off the middle moves a hair: the off-panel start is
  /// by [side], so nothing near the box is thrown a whole width.
  double get shift => lerpDouble(
    side * panel.width,
    d * panel.width * (turning ? _Flow.spread : _Flow.flatSpread),
    t,
  )!;

  /// Flat and whole in the middle; turned, smaller and dimmer to the
  /// sides. Applied about the cover's center.
  Matrix4 get transform {
    if (!turning) return Matrix4.translationValues(shift, 0, 0);
    final scale = lerpDouble(1, 1 - 0.28 * away, t)!;
    return ((Matrix4.identity()..setEntry(3, 2, 0.0015)) *
            Matrix4.translationValues(shift, 0, 0) *
            Matrix4.rotationY(side * _Flow.turn * t) *
            Matrix4.diagonal3Values(scale, scale, 1))
        as Matrix4;
  }

  /// Dimmer to the sides while the covers turn - depth, of a piece with
  /// the angle. Flat, nothing dims: a page beside the page is a page.
  double get opacity =>
      turning ? (1 - away * (1 - 0.6 * t)).clamp(0.0, 1.0) : 1.0;

  /// How much the cover is the one in focus: whole in the middle and at
  /// rest, none once it stands fully beside the middle, and between as
  /// the wheel carries it - what a translucent page's wash follows.
  double get focus => (1 - away * t).clamp(0.0, 1.0);

  /// The cover's corners: square at rest, so the page is the panel, and
  /// slightly rounded as a card in the flow.
  BorderRadius corners(double radius) =>
      BorderRadius.circular(lerpDouble(0, radius, t)!);

  /// The cover's outline on the panel: its four corners through
  /// [transform] about its center, then through the frame the apps are
  /// fitted to - [fit] of full size, [offset] from the panel's corner.
  /// What the name pills stand on to find a cover's edge.
  Path outline({required double fit, required Offset offset}) {
    final center = Offset(panel.width / 2, panel.height / 2);
    final about =
        (Matrix4.translationValues(center.dx, center.dy, 0) *
                transform *
                Matrix4.translationValues(-center.dx, -center.dy, 0))
            as Matrix4;
    final corners = [
      Offset.zero,
      Offset(panel.width, 0),
      Offset(panel.width, panel.height),
      Offset(0, panel.height),
    ];
    final path = Path();
    for (final (i, corner) in corners.indexed) {
      final on = offset + MatrixUtils.transformPoint(about, corner) * fit;
      if (i == 0) {
        path.moveTo(on.dx, on.dy);
      } else {
        path.lineTo(on.dx, on.dy);
      }
    }
    return path..close();
  }
}

/// The covers' names, floating over the stage: a pill at the top of each
/// neighbor, and for the cover coming to the middle the same pill on its
/// way up into the bar's title slot, its ground fading as it arrives - so
/// what reads as the bar's title at the middle is the name that rode in
/// on the cover, and the name that rides out is the one the bar had. In
/// the panel's coordinates, above the bar, where the covers' turns and
/// the frame's fit cannot bend them. A cover that has slid off the panel
/// keeps its name on it: as the cover goes, its pill moves from the
/// cover's center to the cover's inner edge - the end of the name at the
/// edge for a cover before the middle, the start for one after.
class _Pills extends StatelessWidget {
  const _Pills({
    required this.apps,
    required this.t,
    required this.panel,
    required this.above,
    required this.below,
  });

  final List<MenuLocation> apps;
  final double t;
  final Size panel;

  /// What the frame is inset by, top and bottom, at full flow.
  final double above;
  final double below;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final scale = UiScale.of(context);

    return Builder(
      builder: (context) {
        final position = _FlowPosition.of(context);
        if (position == null || t == 0) return const SizedBox.shrink();
        // The frame the apps are fitted to, and how much it shrinks them.
        final frameHeight = panel.height - t * (above + below);
        final fit = frameHeight / panel.height;
        final pageWidth = panel.width * fit;

        return Stack(
          clipBehavior: Clip.none,
          children: [
            for (var i = 0; i < apps.length; i++)
              if ((i - position).abs() < 2)
                _pill(
                  context,
                  theme,
                  scale,
                  i,
                  position,
                  fit,
                  frameHeight,
                  pageWidth,
                ),
          ],
        );
      },
    );
  }

  /// What a cover's pill says: the page it is showing, or the app itself
  /// when the page has no name to give.
  static String chromeTitle(MenuLocation entry) {
    final title = DockChrome.of(entry.path).value.title;
    return title.isEmpty ? entry.label : title;
  }

  /// How wide a pill saying [title] is, at full size: the name in the
  /// label face, and the pill's padding either side.
  static double _width(BuildContext context, Theme theme, String title) {
    final style = theme.widgets.text
        .resolve(TextRole.label, on: theme.palette.text)
        .merge(barTitleStyle(theme));
    final painter = TextPainter(
      text: TextSpan(text: title, style: style),
      textDirection: Directionality.of(context),
      maxLines: 1,
    )..layout();
    final width = painter.width + 2 * theme.space.x3;
    painter.dispose();
    return width;
  }

  Widget _pill(
    BuildContext context,
    Theme theme,
    UiScale scale,
    int i,
    double position,
    double fit,
    double frameHeight,
    double pageWidth,
  ) {
    final d = i - position;
    final away = d.abs().clamp(0.0, 1.0);
    final entry = apps[i];
    // The pill's text starts at the same inset as the status-bar title.
    // Account for its padding; the rendered width is handled below.
    final slot = Offset(
      theme.space.x2 - theme.space.x3,
      chromeScale.barHeight / 2,
    );
    final cover = CoverGeometry(index: i, at: position, t: t, panel: panel);
    // Where the cover's top center is: the turn is about that very line,
    // and the shrink is about the cover's center.
    final s = lerpDouble(1, 1 - 0.28 * away, t)!;
    final coverTop = t * above + (1 - s) * frameHeight / 2;
    final pillScale = fit * s;
    var anchor = Offset(
      panel.width / 2 + cover.shift * fit,
      coverTop + chromeScale.barHeight * pillScale / 2,
    );
    final size = lerpDouble(1, pillScale, away)!;

    // Off the panel, the name moves to the cover's inner edge - by the
    // share of the cover that is off, so it slides there rather than
    // jumps - and no further off than the edge itself.
    if (t > 0 && d != 0) {
      final bounds = cover
          .outline(
            fit: fit,
            offset: Offset((panel.width - pageWidth) / 2, t * above),
          )
          .getBounds();
      final off = (d < 0 ? -bounds.left : bounds.right - panel.width).clamp(
        0.0,
        bounds.width,
      );
      final gone = bounds.width == 0 ? 0.0 : off / bounds.width;
      final half = _width(context, theme, chromeTitle(entry)) * size / 2;
      final atEdge = d < 0
          ? bounds.right - half - theme.space.x1
          : bounds.left + half + theme.space.x1;
      // And never off the panel itself, whatever the cover's edge is
      // doing: the name is there to be read.
      final x = lerpDouble(
        anchor.dx,
        atEdge,
        gone,
      )!.clamp(half + theme.space.x1, panel.width - half - theme.space.x1);
      anchor = Offset(x, anchor.dy);
    }
    // From the bar's slot at the middle to the cover's top beside it.
    final center = Offset.lerp(slot, anchor, away)!;

    return Positioned(
      left: 0,
      right: 0,
      top: center.dy - chromeScale.barHeight / 2,
      height: chromeScale.barHeight,
      child: IgnorePointer(
        child: Opacity(
          opacity: (2 - d.abs()).clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(center.dx - panel.width / 2, 0),
            child: Transform.scale(
              scale: size,
              child: Center(
                child: ValueListenableBuilder(
                  valueListenable: DockChrome.of(entry.path),
                  builder: (context, chrome, _) => ListenableBuilder(
                    listenable: Backdropped.changes,
                    builder: (context, _) => FractionalTranslation(
                      translation: Offset((1 - away) / 2, 0),
                      child: Container(
                        height: chromeScale.barHeight,
                        padding: EdgeInsets.symmetric(
                          horizontal: theme.space.x3,
                        ),
                        decoration: BoxDecoration(
                          // A pill is a surface, so it wears the tone the tint
                          // sets and the opacity the surfaces are set to - and
                          // its ground still comes with distance from the bar's
                          // slot, because in the slot the name is the bar's
                          // title and nothing more.
                          color: Backdropped.tone(
                            theme.palette,
                          ).withValues(alpha: away * Backdropped.opacity()),
                          borderRadius: BorderRadius.circular(
                            chromeScale.barHeight / 2,
                          ),
                        ),
                        child: Center(
                          widthFactor: 1,
                          child: _Dressed(
                            theme: theme,
                            child: chrome.clock
                                ? ClockText(style: barTitleStyle(theme))
                                : LabelText(
                                    chrome.titleOr(entry.label),
                                    maxLines: 1,
                                    style: barTitleStyle(theme),
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// -- the status bar ----------------------------------------------------------

/// The one bar across the top of the panel, always: the play state at the
/// left, the readings and then the clock at the right, and between them
/// the name of the page on stage. While the dock is up it is glass, its
/// bottom corners rounded; over a page it is the page's own bar, with a
/// hairline under it; over home it paints nothing at all, and the
/// readings sit on the wallpaper. Always the panel's full width. Only the
/// ground moves between those: what is on the bar is one set of widgets,
/// never rebuilt, that stays exactly where it is.
class StatusBar extends StatelessWidget {
  const StatusBar({super.key});

  /// The bar, for tests.
  static const barKey = Key('StatusBar');

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final scale = UiScale.of(context);

    return ValueListenableBuilder(
      valueListenable: MenuDock.shown,
      child: const _BarContent(),
      builder: (context, shown, content) => TweenAnimationBuilder<double>(
        tween: Tween(end: shown ? 1.0 : 0.0),
        duration: theme.motion.standard,
        curve: theme.motion.move,
        child: content,
        builder: (context, t, content) => Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: scale.barHeight,
          child: _OnSelectedChrome(
            builder: (context, chrome) => IgnorePointer(
              ignoring: !shown && !chrome.visible,
              child: AnimatedOpacity(
                duration: theme.motion.standard,
                curve: theme.motion.move,
                opacity: shown || chrome.visible ? 1 : 0,
                child: AnimatedSlide(
                  key: const Key('StatusBar.visibilitySlide'),
                  duration: theme.motion.standard,
                  curve: theme.motion.move,
                  offset: shown || chrome.visible
                      ? Offset.zero
                      : const Offset(0, -1),
                  child: _BarGround(t: t, child: content!),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The bar's ground at [t] between the page's bar (0) and the glass band
/// (1), for the page on stage - which may want no ground at all.
class _BarGround extends StatelessWidget {
  const _BarGround({required this.t, required this.child});

  final double t;
  final Widget child;

  @override
  Widget build(BuildContext context) => _OnSelectedChrome(
    builder: (context, chrome) => ListenableBuilder(
      listenable: Backdropped.changes,
      builder: (context, _) => _ground(context, chrome),
    ),
  );

  Widget _ground(BuildContext context, BarChrome chrome) {
    final theme = ThemeProvider.of(context);
    final scale = UiScale.of(context);
    final bare = t == 0 && !chrome.ground;
    // The bar is a surface - one of the few things on the panel that is -
    // so it wears what every other surface wears: the tone Page Tint sets
    // it, at the opacity Translucent Surfaces does. Off, the picture
    // stops at the bar; on, it comes through it. Before, only the band
    // over the flow was ever glass, so the setting moved nothing a page
    // could see.
    final dress = Backdropped.surfaceOf(theme.palette);
    final rest = chrome.ground ? dress : dress.withValues(alpha: 0);
    final glass = dress;
    // Square along the top edge it sits on; rounded below, as far as
    // it is glass, and only a little: a quarter of its own height.
    final radius = BorderRadius.vertical(
      bottom: Radius.circular(t * scale.barHeight / 4),
    );
    return ClipRRect(
      borderRadius: radius,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Color.lerp(rest, glass, t),
          borderRadius: radius,
          border: Border(
            bottom: BorderSide(
              color: theme.palette.divider.withValues(
                alpha: chrome.ground ? 1 - t : 0,
              ),
              width: theme.strokes.hairline,
            ),
          ),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: theme.space.x2),
          // Over the wallpaper the bar's words must read on black,
          // whatever light the rest of the UI is in: the dark
          // palette then, the page's otherwise - through the same
          // two widgets either way, so what is under them is
          // dressed and never rebuilt.
          child: _Dressed(
            theme: bare ? Appearance.themeFor(Brightness.dark) : theme,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// [child] in [theme]: the theme the words resolve from, and the color
/// they grade against.
class _Dressed extends StatelessWidget {
  const _Dressed({required this.theme, required this.child});

  final Theme theme;
  final Widget child;

  @override
  Widget build(BuildContext context) => ThemeProvider(
    theme: theme,
    child: DefaultTextStyle.merge(
      style: TextStyle(color: theme.palette.text),
      child: child,
    ),
  );
}

/// Builds on the chrome of the app on stage, following the app as it
/// changes and its chrome as its pages come and go.
class _OnSelectedChrome extends StatelessWidget {
  const _OnSelectedChrome({required this.builder});

  final Widget Function(BuildContext context, BarChrome chrome) builder;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: MenuDock.selected,
    builder: (context, selected, _) {
      final entries = MenuDock.current.value;
      final entry = selected ?? (entries.isEmpty ? null : entries.first);
      if (entry == null) return builder(context, const BarChrome());
      return ValueListenableBuilder(
        valueListenable: DockChrome.of(entry.path),
        builder: (context, chrome, _) => builder(context, chrome),
      );
    },
  );
}

/// A left-aligned title with the status cluster at the trailing edge.
class _BarContent extends StatelessWidget {
  const _BarContent();

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    return CustomMultiChildLayout(
      delegate: _BarLayout(gap: theme.space.x3),
      children: [
        LayoutId(id: _BarSlot.title, child: const _BarTitle()),
        LayoutId(
          id: _BarSlot.right,
          child: const _End(
            alignment: Alignment.centerRight,
            child: StatusGlyphs(),
          ),
        ),
      ],
    );
  }
}

enum _BarSlot { title, right }

class _BarLayout extends MultiChildLayoutDelegate {
  _BarLayout({required this.gap});
  final double gap;

  @override
  void performLayout(Size size) {
    final right = layoutChild(
      _BarSlot.right,
      BoxConstraints(maxWidth: size.width * 0.6, maxHeight: size.height),
    );
    final title = layoutChild(
      _BarSlot.title,
      BoxConstraints(
        maxWidth: (size.width - right.width - (right.width > 0 ? gap : 0))
            .clamp(0.0, size.width),
        maxHeight: size.height,
      ),
    );
    positionChild(_BarSlot.title, Offset(0, (size.height - title.height) / 2));
    positionChild(
      _BarSlot.right,
      Offset(size.width - right.width, (size.height - right.height) / 2),
    );
  }

  @override
  bool shouldRelayout(_BarLayout oldDelegate) => gap != oldDelegate.gap;
}

/// One end of the bar: whatever it holds, scaled down to fit if it must -
/// so nothing runs off the bar.
class _End extends StatelessWidget {
  const _End({required this.alignment, required this.child});

  final Alignment alignment;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      FittedBox(fit: BoxFit.scaleDown, alignment: alignment, child: child);
}

/// The name at the left of the bar: the page on stage - or, while the
/// covers are out, the app under the box, said but unseen, because the
/// cover's own pill is in the slot saying it. A name too long for its
/// third of the bar shrinks to fit rather than being cut.
class _BarTitle extends StatelessWidget {
  const _BarTitle();

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: MenuDock.preview,
    builder: (context, preview, _) => preview != null
        ? ValueListenableBuilder(
            valueListenable: DockChrome.of(preview.path),
            builder: (context, chrome, _) => Opacity(
              opacity: 0,
              child: _title(
                chrome.title.isEmpty ? preview.label : chrome.title,
              ),
            ),
          )
        : _OnSelectedChrome(
            builder: (context, chrome) => chrome.clock
                ? Builder(
                    builder: (context) => ClockText(
                      style: barTitleStyle(ThemeProvider.of(context)),
                    ),
                  )
                : _title(chrome.titleOr('')),
          ),
  );

  /// How far the title may shrink before it is cut instead.
  ///
  /// It used to shrink to fit with no floor at all, which made an album
  /// called "Hazbin Hotel: Season Two (Original Soundtrack)" a third the
  /// height of the readings beside it - whole, and no more readable for
  /// it. Cutting at full size instead went too far the other way: a plain
  /// screen name like "Appearance" came out "Appear...". So it gives up a
  /// quarter of its size to fit, and ellipsizes past that.
  static const _titleFloor = 0.6;

  Widget _title(String title) => Builder(
    builder: (context) {
      final style = barTitleStyle(ThemeProvider.of(context));
      return LayoutBuilder(
        builder: (context, constraints) {
          final size = style.fontSize ?? 12;
          final painter = TextPainter(
            text: TextSpan(text: title, style: style),
            maxLines: 1,
            textDirection: Directionality.of(context),
          )..layout();
          final fit = constraints.maxWidth.isFinite && painter.width > 0
              ? (constraints.maxWidth / painter.width).clamp(_titleFloor, 1.0)
              : 1.0;
          return LabelText(
            title,
            textAlign: TextAlign.left,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style.copyWith(fontSize: size * fit),
          );
        },
      );
    },
  );
}

/// The bar's title, and the name on a cover's pill that becomes it: the
/// label face at the bar's type size, set solid so it sits within the bar.
TextStyle barTitleStyle(Theme theme) =>
    TextStyle(fontSize: barTypeSize(theme), height: 1);

// -- the dock ----------------------------------------------------------------

/// The dock on the screen: nothing while [MenuDock.shown] is off, and the
/// bar of icons along the bottom, holding the wheel, while it is on. It
/// comes in from the bottom edge and goes out the same way.
class DockBar extends StatelessWidget {
  const DockBar({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final extent = MenuDock.dockExtent(theme);

    // The dock is chrome: the switcher is the same strip of apps whatever
    // the lists behind it are set to.
    return FixedScale(
      scale: chromeScale,
      child: ValueListenableBuilder(
        valueListenable: MenuDock.shown,
        builder: (context, shown, _) => _Presence(
          shown: shown,
          builder: (context, t) => Positioned(
            left: 0,
            right: 0,
            bottom: -(1 - t) * extent,
            child: const _DockPanel(),
          ),
        ),
      ),
    );
  }
}

/// Keeps [builder]'s widget on screen while it eases in and out of
/// [shown]: 0 is away, 1 is there, and only at 0 with [shown] off is it
/// gone from the tree.
class _Presence extends StatefulWidget {
  const _Presence({required this.shown, required this.builder});

  final bool shown;
  final Widget Function(BuildContext context, double t) builder;

  @override
  State<_Presence> createState() => _PresenceState();
}

class _PresenceState extends State<_Presence> {
  late bool _present = widget.shown;

  @override
  void didUpdateWidget(_Presence oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.shown) _present = true;
  }

  @override
  Widget build(BuildContext context) {
    if (!_present) return const SizedBox.shrink();
    final theme = ThemeProvider.of(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: widget.shown ? 1.0 : 0.0),
      duration: theme.motion.standard,
      curve: theme.motion.move,
      onEnd: () {
        if (!widget.shown && mounted) setState(() => _present = false);
      },
      builder: (context, t, _) => widget.builder(context, t),
    );
  }
}

class _DockPanel extends StatefulWidget {
  const _DockPanel();

  @override
  State<_DockPanel> createState() => _DockPanelState();
}

class _DockPanelState extends State<_DockPanel> {
  final _focus = FocusNode(debugLabel: 'Dock');
  late List<MenuLocation> _entries;
  late int _index;
  bool _moving = false;
  Route<_DockAction>? _menu;

  @override
  void initState() {
    super.initState();
    _entries = MenuDock.current.value;
    // Open on the app that is on stage: the switcher starts where you are.
    final selected = MenuDock.selected.value;
    _index = selected == null ? 0 : _entries.indexOf(selected).clamp(0, 99);
    if (_index >= _entries.length) _index = 0;
    MenuDock.current.addListener(_refresh);
    MenuDock.shown.addListener(_shownChanged);
    FocusManager.instance.addListener(_guardFocus);
    // After the frame: the stage follows what is set here, and this is
    // the middle of a build; and the focus that was on the screen
    // underneath is the one that gets it back when the dock goes away.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _entries.isEmpty) return;
      MenuDock.preview.value = _entries[_index];
      _moved(_index.toDouble());
      _focus.requestFocus();
    });
  }

  /// While the dock is up, the wheel is the dock's. A screen under it that
  /// takes focus meanwhile - a list born with autofocus as a folder is
  /// re-listed, a route that settles - would pull the wheel off the
  /// switcher and leave the user unable to get back to it; so any focus
  /// that leaves the dock while it is showing comes straight back. The
  /// apps' own scopes are left alone, and keep their memory of what had
  /// the wheel for when the dock goes away.
  void _guardFocus() {
    if (!mounted || !MenuDock.shown.value || _menu != null || _focus.hasFocus) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          MenuDock.shown.value &&
          _menu == null &&
          !_focus.hasFocus) {
        _focus.requestFocus();
      }
    });
  }

  /// Put away: the wheel goes back to whatever had it before the dock took
  /// it, at once, while the dock is still sliding out - and so does the
  /// screen itself, unless something was chosen, when the flow stays
  /// until it has grown.
  void _shownChanged() {
    if (MenuDock.shown.value) return;
    final menu = _menu;
    if (menu != null && menu.isActive) menu.navigator?.removeRoute(menu);
    _focus.unfocus(disposition: UnfocusDisposition.previouslyFocusedChild);
    if (!MenuDock._chosen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!MenuDock.shown.value && !MenuDock._chosen) MenuDock._clearFlow();
      });
    }
  }

  @override
  void dispose() {
    MenuDock.shown.removeListener(_shownChanged);
    FocusManager.instance.removeListener(_guardFocus);
    MenuDock.current.removeListener(_refresh);
    _focus.dispose();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!MenuDock._chosen) MenuDock._clearFlow();
    });
    super.dispose();
  }

  void _refresh() => setState(() {
    final highlighted = _entries.isEmpty ? null : _entries[_index];
    _entries = MenuDock.current.value;
    final next = highlighted == null ? -1 : _entries.indexOf(highlighted);
    _index = next >= 0 ? next : 0;
    if (_entries.isNotEmpty) {
      MenuDock.preview.value = _entries[_index];
      _moved(_index.toDouble());
    }
  });

  /// Tell the stage where the box is. Straight away between frames, and
  /// after the frame from inside one: the stage rebuilds on it, and a
  /// rebuild asked for mid-build is refused.
  void _moved(double position) {
    // Once something is chosen the box has no more to say: the flow is
    // closing on the choice, and the rail's last settling is its own.
    if (MenuDock._chosen) return;
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle) {
      MenuDock.position.value = position;
    } else {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) MenuDock.position.value = position;
      });
    }
  }

  Future<void> _openMenu() async {
    if (_menu != null || _entries.isEmpty) return;
    final entry = _entries[_index];
    final route = DialogRoute<_DockAction>(
      theme: UiScale.regular.theme(Appearance.brightness.value),
      builder: (_) => _DockActionsDialog(entry: entry),
    );
    _menu = route;
    final action = await Navigator.of(context).push(route);
    await route.completed;
    _menu = null;
    if (!mounted || !MenuDock.shown.value) return;
    _focus.requestFocus();
    switch (action) {
      case _DockAction.open:
        if (!MenuScreens.activate(context, entry)) MenuDock.select(entry);
      case _DockAction.pin:
        final pins = [...MenuDock.pins.value];
        if (!pins.remove(entry.path)) pins.add(entry.path);
        // Unpinning is separate from closing the running app.
        if (!pins.contains(entry.path) &&
            !MenuDock.opened.value.contains(entry.path)) {
          MenuDock.opened.value = [...MenuDock.opened.value, entry.path];
        }
        MenuDock.pins.value = pins;
        SettingsScope.maybeOf(context)?.set(MenuDock.pinsPath, pins);
      case _DockAction.move:
        setState(() => _moving = true);
      case _DockAction.close:
        setState(() => _moving = false);
        if (entry.node.screen == MenuScreens.fmRadio) {
          await FmRadioSession.stopActive();
          if (!mounted) return;
        }
        MenuDock.close(entry);
      case _DockAction.cancel:
      case null:
        break;
    }
  }

  void _select(int index) {
    if (index == _index) return;
    setState(() {
      if (_moving) {
        _entries = [..._entries];
        _entries.insert(index, _entries.removeAt(_index));
      }
      _index = index;
    });
    if (_moving) {
      final paths = [for (final entry in _entries) entry.path];
      MenuDock.order.value = paths;
      SettingsScope.maybeOf(context)?.set(MenuDock.orderPath, paths);
    }
    MenuDock.preview.value = _entries[index];
    _moved(index.toDouble());
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    if (_entries.isEmpty) return const SizedBox.shrink();
    final entry = _entries[_index];

    return Actions(
      actions: {
        WheelMenuIntent: CallbackAction<WheelMenuIntent>(
          onInvoke: (_) {
            _openMenu();
            return null;
          },
        ),
        ActivateHoldIntent: CallbackAction<ActivateHoldIntent>(
          onInvoke: (_) {
            setState(() => _moving = !_moving);
            return null;
          },
        ),
        // Menu finishes placement before dismissing the switcher.
        WheelBackIntent: CallbackAction<WheelBackIntent>(
          onInvoke: (_) {
            if (_moving) {
              setState(() => _moving = false);
            } else {
              MenuDock.shown.value = false;
            }
            return null;
          },
        ),
        // Left and right step the box without the wheel's weight.
        MediaIntent: CallbackAction<MediaIntent>(
          onInvoke: (intent) {
            switch (intent.command) {
              case MediaCommand.previous:
                _select((_index - 1).clamp(0, _entries.length - 1));
              case MediaCommand.next:
                _select((_index + 1).clamp(0, _entries.length - 1));
              case MediaCommand.toggle:
                break;
            }
            return null;
          },
        ),
      },
      child: Padding(
        // A slab, not a strip: glass standing a little off the edges.
        padding: EdgeInsets.fromLTRB(
          MenuDock.margin(theme),
          0,
          MenuDock.margin(theme),
          MenuDock.margin(theme),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_moving)
              const Glass(
                child: Padding(
                  padding: EdgeInsets.all(4),
                  child: CaptionText('Turn to move · Select to place'),
                ),
              ),
            Glass(
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: theme.space.x2,
                  vertical: theme.space.x1,
                ),
                child: WheelRail<MenuLocation>(
                  focusNode: _focus,
                  value: entry,
                  physics: MenuDock.physics,
                  // The glass is the track: the rail's own trough would be a
                  // second, solid one on top of it.
                  style: _railStyle(theme),
                  onChanged: (chosen) => _select(_entries.indexOf(chosen)),
                  onActivate: (chosen) {
                    if (_moving) {
                      setState(() => _moving = false);
                    } else if (MenuScreens.isAction(chosen)) {
                      MenuScreens.activate(context, chosen);
                    } else {
                      MenuDock.select(chosen);
                    }
                  },
                  onMoved: _moved,
                  segments: [
                    for (final item in _entries)
                      SegmentOption(
                        value: item,
                        label: Icon(MenuIcons.of(item.node.hint)),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The segmented dress with no fill under the options: the box in the
  /// primary's subtle, as every other rail on the player, and nothing else
  /// painted.
  static SegmentedControlStyle _railStyle(Theme theme) {
    final base = theme.widgets.segmented.resolve(
      SemanticSwatch.primary,
      SurfaceVariant.subtle,
    );
    return base.copyWith(
      track: SurfaceStyle(
        foreground: base.track.foreground,
        radius: base.track.radius,
      ),
    );
  }
}

enum _DockAction { open, pin, move, close, cancel }

class _DockActionsDialog extends StatefulWidget {
  const _DockActionsDialog({required this.entry});
  final MenuLocation entry;
  @override
  State<_DockActionsDialog> createState() => _DockActionsDialogState();
}

class _DockActionsDialogState extends State<_DockActionsDialog> {
  final _scope = FocusScopeNode(debugLabel: 'Dock actions');
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scope.requestFocus();
    });
  }

  @override
  void dispose() {
    _scope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final required = MenuDock.required.contains(widget.entry.path);
    final options = <(_DockAction, String, IconData)>[
      (_DockAction.open, 'Open', LucideIcons.play),
      if (!required)
        (
          _DockAction.pin,
          MenuDock.pins.value.contains(widget.entry.path)
              ? 'Unpin from dock'
              : 'Pin to dock',
          LucideIcons.pin,
        ),
      (_DockAction.move, 'Rearrange', LucideIcons.moveHorizontal),
      if (!required) (_DockAction.close, 'Close app', LucideIcons.x),
      (_DockAction.cancel, 'Cancel', LucideIcons.arrowLeft),
    ];
    void cancel() => Navigator.of(context).pop();
    return Actions(
      actions: {
        WheelBackIntent: CallbackAction<WheelBackIntent>(
          onInvoke: (_) {
            cancel();
            return null;
          },
        ),
        WheelMenuIntent: CallbackAction<WheelMenuIntent>(
          onInvoke: (_) {
            cancel();
            return null;
          },
        ),
      },
      child: Dialog(
        title: Text(widget.entry.label),
        content: FocusScope(
          node: _scope,
          child: DialogList(
            onActivate: (index) => Navigator.of(context).pop(options[index].$1),
            children: [
              for (final option in options)
                ListRow(label: option.$2, icon: option.$3),
            ],
          ),
        ),
      ),
    );
  }
}
