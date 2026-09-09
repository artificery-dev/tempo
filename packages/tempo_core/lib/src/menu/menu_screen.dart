import '../dialog_list.dart';
import 'dart:async';

import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

import '../content_surface.dart';
import '../appearance.dart';
import '../applet.dart';
import '../list_row.dart';
import '../dock.dart';
import '../panel_bar.dart';
import '../power.dart';
import '../routes.dart';
import '../scale.dart';
import '../screens.dart';
import '../screens/files.dart';
import '../screens/fm_radio.dart';
import '../settings/settings_app.dart';
import '../settings/settings.dart';
import '../screens/music.dart';
import '../screens/collection.dart';
import '../services/library.dart';
import 'menu_node.dart';
import 'menu_tree.dart';

/// Builds the screen a leaf opens, told which leaf asked.
typedef MenuPageBuilder = Widget Function(MenuLocation entry);

/// Builds the route a leaf opens, for a leaf that is not a page - a
/// dialog, say.
typedef MenuRouteBuilder = Route<void> Function(MenuLocation entry);

/// How the menu is drawn and what it keeps. Settings > Home & Menus >
/// Menu moves these.
abstract final class MenuOptions {
  /// The view a branch takes when its own node has no opinion.
  static final view = ValueNotifier<MenuLayout>(MenuLayout.list);

  /// Whether an app reopens where it was left, rather than at its root.
  static final remember = ValueNotifier<bool>(true);

  /// Whether a detent past the end of a menu comes back to the start.
  static final wrap = ValueNotifier<bool>(false);
}

/// The screens a leaf can name, by key.
///
/// The tree is data and says `screen: 'files'`; this is the other half,
/// where `'files'` becomes a [FilesScreen]. Keeping the two apart is what
/// lets the tree come from anywhere: a plugin registers its screen here
/// under a key of its own and puts a leaf naming it wherever it likes.
///
/// A screen is registered as a page ([register]) when it is one - which is
/// what lets the dock show it small before it is chosen - or as a route
/// ([registerRoute]) when it is something else, like the power dialog. A
/// leaf with no key, or a key nobody registered, opens the
/// [PlaceholderScreen] with the leaf's path on it - so an unfinished
/// branch of the menu is walkable and says where it is, rather than a
/// dead row.
abstract final class MenuScreens {
  /// Not a screen to push: the home screen is the root of the stack, and
  /// this leaf goes back down to it.
  static const home = 'home';

  static const files = 'files';
  static const settings = 'settings';
  static const power = 'power';
  static const songs = 'songs';
  static const albums = 'albums';
  static const artists = 'artists';
  static const fmRadio = 'fm-radio';
  static const libraryUpdate = 'library-update';

  static final Map<String, MenuPageBuilder> _pages = {
    for (final section in LibrarySection.values)
      if (section != LibrarySection.music)
        section.name: (_) => CollectionScreen(section: section),
    files: (_) => const FilesScreen(),
    settings: (_) => const SettingsApp(),
    songs: (_) => const SongsScreen(),
    albums: (_) => const AlbumsScreen(),
    artists: (_) => const ArtistsScreen(),
    libraryUpdate: (_) => const LibraryUpdateScreen(),
  };

  static final Map<String, void Function(BuildContext)> _actions = {
    fmRadio: (context) => unawaited(openFmRadio(context)),
  };

  static bool isAction(MenuLocation entry) =>
      _actions.containsKey(entry.node.screen);

  static bool activate(BuildContext context, MenuLocation entry) {
    final action = _actions[entry.node.screen];
    if (action == null) return false;
    action(context);
    return true;
  }

  static final Map<String, MenuRouteBuilder> _routes = {
    power: (_) => PowerDialog.route(),
  };

  /// Every key a leaf may name.
  static Iterable<String> get keys => [
    home,
    ..._pages.keys,
    ..._routes.keys,
    ..._actions.keys,
  ];

  static bool knows(String key) =>
      key == home ||
      _pages.containsKey(key) ||
      _routes.containsKey(key) ||
      _actions.containsKey(key);

  /// Offer a page under [key]. A later registration under the same key
  /// replaces the earlier one, which is how a plugin takes a screen over.
  static void register(String key, MenuPageBuilder builder) {
    _actions.remove(key);
    _routes.remove(key);
    _pages[key] = builder;
  }

  /// Offer something other than a page under [key]: a route of its own.
  static void registerRoute(String key, MenuRouteBuilder builder) {
    _actions.remove(key);
    _pages.remove(key);
    _routes[key] = builder;
  }

  /// The screen [entry] shows, built in place: home, a list of a branch's
  /// children, a leaf's page, or the placeholder. Null for a leaf whose
  /// screen is a route rather than a page - there is nothing to show
  /// small.
  static Widget? pageFor(MenuLocation entry) {
    if (entry.node.screen == home) return const HomeScreen();
    if (!entry.isLeaf) return branchPage(entry);
    final page = _pages[entry.node.screen];
    if (page != null) return page(entry);
    if (_routes.containsKey(entry.node.screen) || isAction(entry)) return null;
    return PlaceholderScreen(title: entry.label, path: entry.path);
  }

  /// A branch, shown the way its node asks - rows, or a grid of glyphs -
  /// and, where it asks for nothing, the way the default view is set.
  ///
  /// A branch with no opinion watches the setting rather than reading it
  /// once: the view can be changed from Settings while a menu is open
  /// underneath it, and coming back to find the old one still drawn is
  /// the sort of thing that reads as the setting not working.
  static Widget branchPage(MenuLocation entry) {
    final stated = entry.node.layout;
    if (stated != null) return _viewOf(stated, entry);
    return ValueListenableBuilder(
      valueListenable: MenuOptions.view,
      builder: (context, view, _) => _viewOf(view, entry),
    );
  }

  static Widget _viewOf(MenuLayout view, MenuLocation entry) {
    if (entry.path == '/library') {
      return LibraryMenuScreen(entry: entry, view: view);
    }
    return switch (view) {
      MenuLayout.list => MenuListScreen(entry: entry),
      MenuLayout.grid => MenuGridScreen(entry: entry),
    };
  }

  /// The route a branch opens.
  static Route<void> branchRoute(MenuLocation entry) => PanelRoute(
    settings: RouteSettings(name: entry.path),
    builder: (_) => branchPage(entry),
  );

  /// The route [entry] opens. Total: a leaf that names nothing, or names
  /// something nobody registered, gets the placeholder.
  static Route<void> routeFor(MenuLocation entry) {
    final route = _routes[entry.node.screen];
    if (route != null) return route(entry);
    return PanelRoute(
      settings: RouteSettings(name: entry.path),
      builder: (_) => pageFor(entry)!,
    );
  }
}

/// A list of one node's children, driven by the wheel.
///
/// Every level of the system menu is one of these: the wheel walks the
/// rows, the center button opens the selected one - a list of its own
/// children if it is a branch, its screen if it is a leaf - and menu backs
/// out to the level above. The home screen pushes the root; nothing else
/// about the tree is known here.
class MenuListScreen extends StatelessWidget {
  const MenuListScreen({required this.entry, super.key});

  /// The branch being shown.
  final MenuLocation entry;

  static Route<void> route(MenuLocation entry) => PanelRoute(
    settings: RouteSettings(name: entry.path),
    builder: (_) => MenuListScreen(entry: entry),
  );

  /// The top of the system menu.
  static Route<void> root() => route(systemMenu.rootEntry);

  @override
  Widget build(BuildContext context) {
    final children = entry.children;

    return PanelScreen(
      title: entry.label,
      child: _AppMenu(
        entry: entry,
        builder: (changed) => PanelList(
          onSelectionChanged: changed,
          // One row height for every wheel-driven list of entries, so the
          // rhythm is the same at every depth.
          itemExtent: UiScale.of(context).rowExtent,
          autofocus: true,
          wrap: MenuOptions.wrap.value,
          onActivate: (index) => openMenuEntry(context, children[index]),
          children: [for (final child in children) MenuRow(child)],
        ),
      ),
    );
  }
}

/// Open [child] from a menu screen: home goes back down to the dock's home,
/// a branch opens its own screen, a leaf its page or route.
///
/// One push per activation, however fast the button is pressed: a second
/// activation arriving during the route transition must not stack a
/// second copy of the screen.
void openMenuEntry(BuildContext context, MenuLocation child) {
  final route = ModalRoute.of(context);
  if (route != null && !route.isCurrent) return;

  if (MenuScreens.activate(context, child)) return;
  final navigator = Navigator.of(context);
  // Home, and anything pinned in the dock: the dock's copy is the app -
  // the one with its own stage and stack - so choosing it here is
  // choosing it there, not opening a second Files inside Apps.
  if (child.node.screen == MenuScreens.home ||
      (MenuDock.pinned(child) && MenuDock.current.value.contains(child))) {
    MenuDock.select(child);
    return;
  }
  // Apps is a launcher, never the navigation stack of a launched app.
  if (child.isLeaf &&
      Applet.maybeOf(context)?.id == '/apps' &&
      MenuScreens.pageFor(child) != null) {
    MenuDock.open(child);
    return;
  }
  navigator.push(
    child.isLeaf ? MenuScreens.routeFor(child) : MenuScreens.branchRoute(child),
  );
}

/// A branch shown as a grid of glyphs, driven by the wheel the way a page
/// is read: left to right, then down a row. The Apps page.
class MenuGridScreen extends StatelessWidget {
  const MenuGridScreen({required this.entry, super.key});

  final MenuLocation entry;

  @override
  Widget build(BuildContext context) {
    final children = entry.children;
    final scale = UiScale.of(context);

    return PanelScreen(
      title: entry.label,
      child: _AppMenu(
        entry: entry,
        builder: (changed) => WheelGrid(
          onSelectionChanged: changed,
          columns: scale.gridColumns,
          cellExtent: scale.gridCellExtent,
          autofocus: true,
          onActivate: (index) => openMenuEntry(context, children[index]),
          children: [
            for (final child in children) GridCard(child: MenuTile(child)),
          ],
        ),
      ),
    );
  }
}

/// One cell of a [MenuGridScreen]: the entry's glyph over its name.
class MenuTile extends StatelessWidget {
  const MenuTile(this.entry, {super.key});

  final MenuLocation entry;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);

    return Padding(
      padding: EdgeInsets.all(theme.space.x2),
      // Scaled down, never clipped: a cell is sized by the scale and the
      // glyph and its name by the theme, and a theme larger than the
      // scale bargained for (a bare test's) must still show a whole tile.
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: theme.space.x2,
          children: [
            Icon(
              MenuIcons.of(entry.node.hint),
              size: theme.sizes.iconExtraLarge,
            ),
            // Full emphasis, so the name takes the plate's contrast color
            // under the cursor rather than a dimmed gray of its own.
            CaptionText(
              entry.label,
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

/// One row of a [MenuListScreen]: the label, and a chevron when there is
/// a level below it - a [ListRow], like every other list's.
class MenuRow extends StatelessWidget {
  const MenuRow(this.entry, {super.key});

  final MenuLocation entry;

  @override
  Widget build(BuildContext context) => ListRow(
    label: entry.label,
    icon: entry.path.startsWith('/apps/')
        ? MenuIcons.of(entry.node.hint)
        : null,
    chevron: !entry.isLeaf,
  );
}

/// Library ordering belongs to the browsing screen, independently of folder settings.
class LibraryMenuScreen extends StatefulWidget {
  const LibraryMenuScreen({required this.entry, required this.view, super.key});
  final MenuLocation entry;
  final MenuLayout view;
  static const orderPath = '/settings/library/order';

  @override
  State<LibraryMenuScreen> createState() => _LibraryMenuScreenState();
}

class _LibraryMenuScreenState extends State<LibraryMenuScreen> {
  List<MenuLocation>? _entries;
  int _selected = 0;
  bool _moving = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_entries != null) return;
    final defaults = widget.entry.children;
    final saved = SettingsScope.maybeOf(
      context,
    )?.value(LibraryMenuScreen.orderPath);
    final byId = {for (final entry in defaults) entry.id: entry};
    _entries = [
      if (saved is List)
        for (final id in saved)
          if (byId.containsKey(id)) byId.remove(id)!,
      ...byId.values,
    ];
  }

  void _place() {
    SettingsScope.maybeOf(context)?.set(LibraryMenuScreen.orderPath, [
      for (final entry in _entries!) entry.id,
    ]);
    setState(() => _moving = false);
  }

  void _select(int next) {
    setState(() {
      if (_moving) _entries!.insert(next, _entries!.removeAt(_selected));
      _selected = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries!;
    final scale = UiScale.of(context);
    void activate(int index) {
      if (_moving) {
        _place();
      } else {
        openMenuEntry(context, entries[index]);
      }
    }

    return Actions(
      actions: {
        if (_moving)
          WheelBackIntent: CallbackAction<WheelBackIntent>(
            onInvoke: (_) {
              _place();
              return null;
            },
          ),
        ActivateHoldIntent: CallbackAction<ActivateHoldIntent>(
          onInvoke: (_) {
            if (_moving) {
              _place();
            } else {
              setState(() => _moving = true);
            }
            return null;
          },
        ),
      },
      child: PanelScreen(
        title: _moving
            ? 'Moving ${entries[_selected].label}'
            : widget.entry.label,
        child: Column(
          children: [
            if (_moving) const CaptionText('Turn to move · Center to place'),
            Expanded(
              child: widget.view == MenuLayout.grid
                  ? WheelGrid(
                      columns: scale.gridColumns,
                      cellExtent: scale.gridCellExtent,
                      initialIndex: _selected,
                      autofocus: true,
                      onSelectionChanged: _select,
                      onActivate: activate,
                      children: [
                        for (final entry in entries)
                          GridCard(child: MenuTile(entry)),
                      ],
                    )
                  : PanelList(
                      itemExtent: scale.rowExtent,
                      initialIndex: _selected,
                      autofocus: true,
                      wrap: !_moving && MenuOptions.wrap.value,
                      onSelectionChanged: _select,
                      onActivate: activate,
                      children: [for (final entry in entries) MenuRow(entry)],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Keeps app actions tied to the highlighted item in either layout.
class _AppMenu extends StatefulWidget {
  const _AppMenu({required this.entry, required this.builder});
  final MenuLocation entry;
  final Widget Function(ValueChanged<int>) builder;
  @override
  State<_AppMenu> createState() => _AppMenuState();
}

class _AppMenuState extends State<_AppMenu> {
  int _index = 0;
  bool _opening = false;
  final _scope = FocusScopeNode(debugLabel: 'App drawer');

  @override
  void dispose() {
    _scope.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    final children = widget.entry.children;
    if (_opening ||
        children.isEmpty ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    _opening = true;
    final entry = children[_index.clamp(0, children.length - 1)];
    final settings = SettingsScope.maybeOf(context);
    final route = DialogRoute<int>(
      theme: UiScale.regular.theme(Appearance.brightness.value),
      builder: (_) => _AppActionsDialog(entry: entry),
    );
    final action = await Navigator.of(context).push(route);
    await route.completed;
    if (!mounted) return;
    _opening = false;
    _scope.requestFocus();
    if (action == 0) {
      openMenuEntry(context, entry);
    } else if (action == 1) {
      final pins = [...MenuDock.pins.value];
      if (!pins.remove(entry.path)) pins.add(entry.path);
      MenuDock.pins.value = pins;
      settings?.set(MenuDock.pinsPath, pins);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scope.requestFocus();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.builder((index) => _index = index);
    if (widget.entry.path != '/apps') return child;
    return FocusScope(
      node: _scope,
      child: Actions(
        actions: {
          WheelBackIntent: CallbackAction<WheelBackIntent>(
            onInvoke: (_) {
              _open();
              return null;
            },
          ),
          WheelMenuIntent: CallbackAction<WheelMenuIntent>(
            onInvoke: (_) {
              _open();
              return null;
            },
          ),
        },
        child: child,
      ),
    );
  }
}

class _AppActionsDialog extends StatefulWidget {
  const _AppActionsDialog({required this.entry});
  final MenuLocation entry;
  @override
  State<_AppActionsDialog> createState() => _AppActionsDialogState();
}

class _AppActionsDialogState extends State<_AppActionsDialog> {
  final _scope = FocusScopeNode(debugLabel: 'App actions');
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
    void close() => Navigator.of(context).pop();
    return Actions(
      actions: {
        WheelBackIntent: CallbackAction<WheelBackIntent>(
          onInvoke: (_) {
            close();
            return null;
          },
        ),
        WheelMenuIntent: CallbackAction<WheelMenuIntent>(
          onInvoke: (_) {
            close();
            return null;
          },
        ),
      },
      child: Dialog(
        title: Text(widget.entry.label),
        content: FocusScope(
          node: _scope,
          child: DialogList(
            onActivate: (index) => Navigator.of(context).pop(index),
            children: [
              const ListRow(label: 'Open', icon: LucideIcons.play),
              ListRow(
                label: MenuDock.pins.value.contains(widget.entry.path)
                    ? 'Unpin from dock'
                    : 'Pin to dock',
                icon: LucideIcons.pin,
              ),
              const ListRow(label: 'Cancel'),
            ],
          ),
        ),
      ),
    );
  }
}
