import '../dialog_list.dart';
import 'package:file/file.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:path/path.dart' as p;
import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

import '../content_surface.dart';
import '../appearance.dart';
import '../applet.dart';
import '../list_row.dart';
import '../panel_bar.dart';
import '../routes.dart';
import '../scale.dart';
import '../services/services.dart';
import '../storage/places.dart';

/// One row in a column.
sealed class FileRow {
  const FileRow();
}

/// A place to start from. These are the leftmost column, always.
class PlaceRow extends FileRow {
  const PlaceRow(this.place);

  final Place place;
}

/// Something in a folder.
class EntryRow extends FileRow {
  const EntryRow(this.entity);

  final FileSystemEntity entity;

  bool get isFolder => entity is Directory;
}

/// The way back: closes the column it heads, the same as the menu key.
/// First in every folder column, with [OptionsRow] under it and a rule
/// under that; the two start scrolled off above the entries, a detent up
/// from the first, so a folder opens onto its files and the nav is there
/// when the wheel goes looking. The places column has none, since there
/// is nothing behind it to go back to.
class BackRow extends FileRow {
  const BackRow();
}

/// The column's options, in a popover: what to show and how.
class OptionsRow extends FileRow {
  const OptionsRow();
}

/// How the browser shows what it finds. A setting in the making, like
/// [FullFilesystem]: the popover moves it, every open column follows.
abstract final class FilesOptions {
  /// Whether dot-files are listed.
  static final showHidden = ValueNotifier<bool>(false);

  /// Whether an opened folder sits beside the one it came from, or takes
  /// the screen on its own.
  ///
  /// Only asked at the sizes where two columns fit. At [UiScale.large] a
  /// trail column and a working column would be two narrow lists rather
  /// than one readable one, so the browser is single-column there whatever
  /// this says - see [FilesOptions.twoColumnsAt].
  static final twoColumns = ValueNotifier<bool>(true);

  /// Whether [scale] has the room for two columns at all.
  static bool fitsTwoColumns(UiScale scale) => scale != UiScale.large;

  /// Whether the browser draws two columns at [scale].
  static bool twoColumnsAt(UiScale scale) =>
      fitsTwoColumns(scale) && twoColumns.value;
}

/// The rows a folder column starts with, before its entries.
const navRows = 2;

/// One column: what is in a folder, and which row of it is chosen.
class FileColumn {
  FileColumn({required this.rows, this.path, this.selected = 0});

  /// What the column lists. Replaced in place when the listing changes
  /// under an open column, so the column keeps its identity - and its
  /// widget, its scroll, its focus - rather than being born again.
  List<FileRow> rows;

  /// Null for the places column, which is not a folder.
  final String? path;

  int selected;
}

/// Files: the places to start from as a plain list across the whole
/// screen, and once one is opened, columns - the places on the left, and a
/// column for every folder opened since - the way a Finder window walks a
/// filesystem, on a screen the width of a thumb.
///
/// The wheel drives the rightmost column; the center button opens what is
/// selected, which pushes a new column beside it; menu closes the rightmost
/// column again - back to the single list from the second - and closes the
/// app from the first. Every folder column starts with a Back row that does
/// what menu does.
///
/// The columns hang from the right edge, the working one flush against it
/// and the trail behind it running off to the left, and they are painted
/// back to front. So when a folder opens, the new column is already in
/// its place and only the column that opened it moves: its trailing edge
/// sweeps left to the trail width, uncovering the new one - one edge in
/// motion, nothing sliding in.
class FilesScreen extends StatefulWidget {
  const FilesScreen({super.key});

  static Route<void> route() => PanelRoute(builder: (_) => const FilesScreen());

  /// How wide the column being driven is, and how wide the ones behind it
  /// are. Unequal on purpose: on a screen this narrow the working column
  /// needs the room for names, and the trail behind it only has to say
  /// where you came from. Alone, the places column is neither: it is the
  /// whole screen.
  static const columnWidth = 106.0;
  static const trailWidth = 68.0;

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  final _columns = <FileColumn>[];

  Places get _places => PlayerServicesScope.of(context).places.value;

  bool get _hasCard => PlayerServicesScope.of(context).storage.value.present;

  ValueListenable<StorageReading>? _watchedStorage;

  @override
  void initState() {
    super.initState();
    FilesOptions.showHidden.addListener(_relist);
    FilesOptions.twoColumns.addListener(_recolumn);
    FullFilesystem.enabled.addListener(_replaces);
  }

  @override
  void dispose() {
    FilesOptions.showHidden.removeListener(_relist);
    FilesOptions.twoColumns.removeListener(_recolumn);
    FullFilesystem.enabled.removeListener(_replaces);
    _watchedStorage?.removeListener(_replaces);
    super.dispose();
  }

  /// The applet this browser is, if it is one: where its open folders
  /// and its options are remembered.
  Applet? _applet;

  static const _openKey = 'open';
  static const _showHiddenKey = 'showHidden';
  static const _twoColumnsKey = 'twoColumns';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The places depend on the card: a screen that lives on, as the
    // docked one does, has to follow it in and out.
    final storage = PlayerServicesScope.of(context).storage;
    if (!identical(storage, _watchedStorage)) {
      _watchedStorage?.removeListener(_replaces);
      _watchedStorage = storage..addListener(_replaces);
    }
    _applet ??= Applet.maybeOf(context);
    if (_columns.isEmpty) {
      _columns.add(_placesColumn());
      _restore();
    }
  }

  /// Pick up where the applet left off: its option, and the folders it
  /// had open, each re-listed now (a folder that has gone since is where
  /// the trail ends).
  void _restore() {
    final state = _applet?.state;
    if (state == null) return;
    final hidden = state.get<bool>(_showHiddenKey);
    if (hidden != null) FilesOptions.showHidden.value = hidden;
    final two = state.get<bool>(_twoColumnsKey);
    if (two != null) FilesOptions.twoColumns.value = two;
    final open = state.get<List<Object?>>(_openKey) ?? const [];
    for (final path in open.whereType<String>()) {
      if (!_places.fileSystem.directory(path).existsSync()) break;
      _columns.add(_folderColumn(path));
    }
  }

  /// Write down what is open, for next time.
  void _remember() {
    _applet?.state.set(_openKey, [
      for (final column in _columns)
        if (column.path != null) column.path,
    ]);
  }

  /// The places changed under a screen that stays open - the debug option
  /// showing the root, the card coming or going: list them again, in place.
  /// A docked app keeps its stack; it must not keep a stale first column.
  void _replaces() {
    if (!mounted || _columns.isEmpty) return;
    setState(() {
      final places = _columns.first;
      places.rows = _placesColumn().rows;
      places.selected = places.selected.clamp(0, places.rows.length - 1);
    });
  }

  FileColumn _placesColumn() => FileColumn(
    rows: [
      for (final place in FullFilesystem.placesFor(_hasCard)) PlaceRow(place),
    ],
  );

  /// The listing of a folder, or an empty column with a way out of it if it
  /// won't open - permissions, a card pulled out mid-walk, a dangling
  /// mount. A browser has to survive all three.
  FileColumn _folderColumn(String path) {
    List<FileSystemEntity> entries;
    try {
      entries = _places.fileSystem.directory(path).listSync(followLinks: false)
        ..sort((a, b) {
          final folders = (b is Directory ? 1 : 0) - (a is Directory ? 1 : 0);
          if (folders != 0) return folders;
          return p.posix
              .basename(a.path)
              .toLowerCase()
              .compareTo(p.posix.basename(b.path).toLowerCase());
        });
    } on Object {
      entries = const [];
    }
    if (!FilesOptions.showHidden.value) {
      entries = [
        for (final entry in entries)
          if (!p.posix.basename(entry.path).startsWith('.')) entry,
      ];
    }

    return FileColumn(
      path: path,
      rows: [
        const BackRow(),
        const OptionsRow(),
        for (final entry in entries) EntryRow(entry),
      ],
      // The wheel starts on the first entry, with Options and Back the
      // detents above it.
      selected: entries.isEmpty ? navRows - 1 : navRows,
    );
  }

  /// The options changed: every open folder is listed again, in place -
  /// the same columns with new rows, never new columns, or a column
  /// rebuilt under the options popover would take the wheel back from it.
  void _relist() {
    if (!mounted) return;
    _applet?.state.set(_showHiddenKey, FilesOptions.showHidden.value);
    setState(() {
      for (final column in _columns) {
        final path = column.path;
        if (path == null) continue;
        column.rows = _folderColumn(path).rows;
        column.selected = column.selected.clamp(0, column.rows.length - 1);
      }
    });
  }

  void _open(FileRow row) {
    switch (row) {
      case PlaceRow(:final place):
        _push(_folderColumn(_places.pathOf(place)));
      case EntryRow(:final entity) when entity is Directory:
        _push(_folderColumn(entity.path));
      case EntryRow():
        // Nothing opens a file yet; the player that will is next door.
        break;
      case BackRow():
        _back();
      case OptionsRow():
        Navigator.of(context).push(FilesOptionsDialog.route());
    }
  }

  /// Out of the app: the route above this one if there is one, and
  /// otherwise the shell's own back - which, at the root of an app, is the
  /// switcher. Asked of the screen's context, which is above the screen's
  /// own actions, so the shell's are the ones found.
  void _leave() {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
    } else {
      Actions.maybeInvoke(context, const WheelBackIntent());
    }
  }

  void _push(FileColumn column) {
    setState(() => _columns.add(column));
    _remember();
  }

  /// Menu, and the Back row: close the rightmost column, or the app when
  /// that was the last.
  void _back() {
    if (_columns.length <= 1) {
      _leave();
      return;
    }
    setState(_columns.removeLast);
    _remember();
  }

  /// What the bar says: the app's own name, always. Where you are is told
  /// by the trail - the row lit in each column behind the working one -
  /// not by the bar changing its mind.
  String get _title => 'Files';

  /// How wide column [index] is: the whole screen while the places are
  /// all there is, and otherwise the working width for the last and the
  /// trail width for the rest.
  double _widthOf(int index, double whole, {required bool two}) {
    if (_columns.length == 1 || !two) return whole;
    return index == _columns.length - 1
        ? FilesScreen.columnWidth
        : FilesScreen.trailWidth;
  }

  /// How far column [index]'s right edge sits from the screen's: the
  /// columns after it, each with its rule.
  double _rightOf(int index, double whole, double rule, {required bool two}) {
    var right = 0.0;
    for (var after = index + 1; after < _columns.length; after++) {
      right += _widthOf(after, whole, two: two) + rule;
    }
    return right;
  }

  /// The columns changed shape rather than contents: nothing to re-list,
  /// only to lay out again - and to remember.
  void _recolumn() {
    if (!mounted) return;
    _applet?.state.set(_twoColumnsKey, FilesOptions.twoColumns.value);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);

    return PanelScreen(
      title: _title,
      child: Actions(
        actions: {
          WheelBackIntent: CallbackAction<WheelBackIntent>(
            onInvoke: (_) {
              _back();
              return null;
            },
          ),
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            final whole = constraints.maxWidth;
            final rule = theme.strokes.hairline;
            // Two columns where there is room for two and the browser is
            // set to them; one otherwise, with the trail sliding off the
            // left edge rather than disappearing.
            final two = FilesOptions.twoColumnsAt(UiScale.of(context));
            return Stack(
              // The trail runs off the left edge; nothing shows past it.
              clipBehavior: Clip.hardEdge,
              children: [
                // Back to front: the working column goes down first and
                // each column on top of the one it opened, so that a
                // column narrowing uncovers the one beside it instead of
                // being painted over by it.
                for (var index = _columns.length - 1; index >= 0; index--)
                  AnimatedPositioned(
                    key: ObjectKey(_columns[index]),
                    duration: theme.motion.standard,
                    curve: theme.motion.move,
                    top: 0,
                    bottom: 0,
                    right: _rightOf(index, whole, rule, two: two),
                    width: _widthOf(index, whole, two: two),
                    child: DecoratedBox(
                      // A trail column carries its own rule on the edge
                      // it shares with the next.
                      decoration: BoxDecoration(
                        border: index < _columns.length - 1
                            ? Border(
                                right: BorderSide(
                                  color: theme.palette.divider,
                                  width: rule,
                                ),
                              )
                            : null,
                      ),
                      child: _Column(
                        column: _columns[index],
                        places: _places,
                        // Only the rightmost column answers to the wheel;
                        // the ones behind it are a trail, showing what was
                        // chosen in each to get here.
                        active: index == _columns.length - 1,
                        onOpen: _open,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Column extends StatelessWidget {
  const _Column({
    required this.column,
    required this.places,
    required this.active,
    required this.onOpen,
  });

  final FileColumn column;
  final Places places;
  final bool active;
  final ValueChanged<FileRow> onOpen;

  @override
  Widget build(BuildContext context) {
    // The columns behind the working one are out of the focus tree, which
    // is what hands the wheel to each new column as it opens and takes it
    // back when the column closes.
    return ExcludeFocus(
      excluding: !active,
      child: PanelList(
        sectionOf: (index) => switch (column.rows[index]) {
          EntryRow(:final entity) => MusicShelf.sectionOf(
            p.basename(entity.path),
            ignoreArticles: false,
          ),
          _ => null,
        },
        leadingGroupCount: column.path == null ? 0 : navRows,
        // The same rows, at the same rhythm, as every other list.
        itemExtent: UiScale.of(context).rowExtent,
        autofocus: active,
        initialIndex: column.selected,
        // A folder opens onto its entries: Back and Options sit above the
        // top edge until the wheel goes up for them.
        initialTopRow: column.path == null ? 0 : navRows,
        onSelectionChanged: (index) => column.selected = index,
        onActivate: active ? (index) => onOpen(column.rows[index]) : null,
        children: [
          for (final (index, row) in column.rows.indexed)
            _Row(
              row: row,
              places: places,
              // A column that isn't being driven still shows what was
              // chosen in it, which is the thread back to where you
              // started.
              marked: !active && index == column.selected,
            ),
        ],
      ),
    );
  }
}

/// A file row as a [ListRow]: the place's or entry's glyph, its name, and a
/// chevron on anything that opens.
class _Row extends StatelessWidget {
  const _Row({required this.row, required this.places, required this.marked});

  final FileRow row;
  final Places places;
  final bool marked;

  static const _placeLabels = {
    Place.home: 'Home',
    Place.sdCard: 'SD Card',
    Place.root: 'Root',
  };

  static const _placeIcons = {
    Place.home: LucideIcons.house,
    Place.sdCard: LucideIcons.hardDrive,
    Place.root: LucideIcons.hardDriveDownload,
  };

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);

    final (label, icon, opens) = switch (row) {
      PlaceRow(:final place) => (
        _placeLabels[place]!,
        _placeIcons[place]!,
        true,
      ),
      EntryRow(:final entity, :final isFolder) => (
        p.posix.basename(entity.path),
        isFolder ? LucideIcons.folder : LucideIcons.file,
        isFolder,
      ),
      BackRow() => ('Back', LucideIcons.cornerUpLeft, false),
      OptionsRow() => ('Options', LucideIcons.slidersHorizontal, true),
    };

    Widget child = ListRow(
      label: label,
      icon: icon,
      chevron: opens,
      emphasis: marked ? TextEmphasis.full : TextEmphasis.secondary,
    );

    // The row chosen in a column behind the working one wears the same
    // dress as the cursor, in the neutral swatch rather than the primary:
    // a marker of where you came through, not a second cursor. It is
    // what tells you where you are, now that the bar keeps the app's name.
    if (marked) {
      final dress = theme.widgets.surface.resolve(
        SemanticSwatch.neutral,
        SurfaceVariant.subtle,
      );
      child = DecoratedBox(
        key: FilesRowMark.key,
        decoration: BoxDecoration(
          color: dress.fill,
          border: dress.border == null
              ? null
              : Border.all(color: dress.border!, width: theme.strokes.hairline),
          // The same box the cursor is, in the neutral swatch: same
          // corners, and - being inside the row's own inset - the same
          // width and height. Two marks of different shapes on one screen
          // read as two ideas.
          borderRadius: WheelRowDress.radiusOf(theme),
        ),
        child: IconTheme.merge(
          data: IconThemeData(color: dress.foreground),
          child: DefaultTextStyle.merge(
            style: TextStyle(color: dress.foreground),
            child: child,
          ),
        ),
      );
    }

    return child;
  }
}

/// The dress on a trail's chosen row, for a test to find.
abstract final class FilesRowMark {
  static const key = Key('FilesRow.mark');
}

/// The browser's options, as a popover over the columns: a short list the
/// wheel walks, the center button toggles, and menu closes.
class FilesOptionsDialog extends StatefulWidget {
  const FilesOptionsDialog({super.key});

  static Route<void> route() => DialogRoute<void>(
    // The player's own theme in its current light, as the power dialog
    // takes it: a popover is above every screen's scope.
    theme: UiScale.regular.theme(Appearance.brightness.value),
    builder: (_) => const FilesOptionsDialog(),
  );

  @override
  State<FilesOptionsDialog> createState() => _FilesOptionsDialogState();
}

class _FilesOptionsDialogState extends State<FilesOptionsDialog> {
  /// The list's scope, taken after the frame: the route wraps the dialog
  /// in a focus of its own that asks for autofocus first, and the list has
  /// to take over from it for the wheel's intents to land here.
  final _scope = FocusScopeNode(debugLabel: 'FilesOptionsDialog');

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
    final theme = ThemeProvider.of(context);
    return Actions(
      actions: {
        WheelBackIntent: CallbackAction<WheelBackIntent>(
          onInvoke: (_) {
            Navigator.of(context).pop();
            return null;
          },
        ),
      },
      child: Dialog(
        title: const Text('Options'),
        content: FocusScope(
          node: _scope,
          child: ListenableBuilder(
            listenable: Listenable.merge([
              FilesOptions.showHidden,
              FilesOptions.twoColumns,
            ]),
            builder: (context, _) {
              // The column count is only asked where two would fit: at the
              // large size the browser is single-column, and an option
              // that cannot be answered is not put on the card.
              final options = <(String, String, VoidCallback)>[
                (
                  'Show hidden files',
                  FilesOptions.showHidden.value ? 'On' : 'Off',
                  () => FilesOptions.showHidden.value =
                      !FilesOptions.showHidden.value,
                ),
                if (FilesOptions.fitsTwoColumns(UiScale.of(context)))
                  (
                    'Columns',
                    FilesOptions.twoColumns.value ? 'Two' : 'One',
                    () => FilesOptions.twoColumns.value =
                        !FilesOptions.twoColumns.value,
                  ),
              ];
              return DialogList(
                onActivate: (index) => index < options.length
                    ? options[index].$3()
                    : Navigator.of(context).pop(),
                children: [
                  for (final (label, reading, _) in options)
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: theme.space.x2),
                      child: Row(
                        children: [
                          Expanded(child: BodyText(label)),
                          BodyText(reading, emphasis: TextEmphasis.secondary),
                        ],
                      ),
                    ),
                  const ListRow(label: 'Done'),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
