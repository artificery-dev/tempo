import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

import '../content_surface.dart';
import '../panel_bar.dart';
import '../scale.dart';
import '../services/services.dart';
import '../status.dart';
import '../dock.dart';
import '../wallpaper.dart';
import '../wallpaper_import.dart';
import '../wallpaper_library.dart';
import '../wallpaper_palette.dart';
import 'setting_node.dart';
import 'setting_tile.dart';
import 'settings.dart';

/// Choosing the picture under everything.
///
/// The pictures come from the three folders [WallpaperLibrary] looks in.
/// Beside each one is the palette it would give the UI - three discs, the
/// primary, the accent and the gray - because a wallpaper on this player is
/// not only a picture: a color slot set to follow it takes its swatch from
/// exactly these.
///
/// The palettes are read one at a time in a background isolate, nearest
/// the wheel first, for as long as the page is open. A folder of
/// wallpapers is a folder of photographs, and decoding one is tens of
/// milliseconds at best: reading them all at once - even a frame apart -
/// is a frozen player for as long as the folder is long, and doing it on
/// this isolate janks every frame it touches.
///
/// So the work is off the wheel's thread and bounded to one at a time,
/// and the order is what makes it feel like nothing: the row the wheel
/// settled on, then outwards from it, so what is on screen fills in
/// before what is not, and a spin down the list retargets the queue
/// rather than adding to it. Sit on the page and the whole folder colors
/// itself in; leave, and it stops where it got to. Read once, kept.
class WallpaperPickerScreen extends StatefulWidget {
  const WallpaperPickerScreen({required this.entry, super.key});

  final SettingLocation entry;

  /// The key a row's discs carry once its palette has been read. The one
  /// thing about the sweep that is visible from outside: a row with this
  /// key on it is a row that has its colors.
  static Key dotsKey(String path) => Key('WallpaperPalette:$path');

  @override
  State<WallpaperPickerScreen> createState() => _WallpaperPickerScreenState();
}

class _WallpaperPickerScreenState extends State<WallpaperPickerScreen> {
  /// The folders walked into, deepest last. Empty is the top, where the
  /// three roots are shown as one.
  final _trail = <WallpaperCandidate>[];

  List<WallpaperCandidate>? _found;

  /// The palette each picture would give, once it has been read. A path
  /// present with an empty list is one that could not be read - asked and
  /// answered, so it is not asked again.
  final _palettes = <String, List<WallpaperPalette>>{};

  /// And the square of it that goes beside its name. Missing for a
  /// picture that has not been read yet, and for one that would not
  /// decode - a row with colors but no square cannot happen.
  final _thumbs = <String, ImageProvider>{};

  /// The one being taken in, so a second press does not start a second.
  String? _busy;

  /// Whether a decode is in flight: one at a time, whatever the wheel is
  /// doing.
  bool _reading = false;

  /// The row the wheel has settled on, and the timer waiting to see that
  /// it has settled.
  String? _wanted;
  Timer? _settling;

  /// The pause between two pictures of the sweep. A timer rather than a
  /// bare delay so that leaving the screen ends the sweep at once,
  /// instead of leaving one more read to wake up into a dead widget.
  Timer? _breathing;

  /// Where the wheel is, which is where the sweep reads outwards from.
  int _at = 0;

  /// How long the wheel must be still on a row before its picture is worth
  /// decoding. A spin down a long list should cost nothing.
  static const _settle = Duration(milliseconds: 180);

  /// The pause between two pictures of the sweep.
  ///
  /// The decode is in another isolate, but reading the file and rebuilding
  /// the list are here, and a folder read back to back would spend every
  /// frame of a long sweep doing that. A breath between them leaves the
  /// wheel the whole of its budget, and the sweep is not in a hurry: the
  /// row the wheel is on never waits for it.
  static const _breath = Duration(milliseconds: 90);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_found == null) _list();
  }

  /// Read whatever folder the trail is in.
  void _list() {
    final places = PlayerServicesScope.of(context).places.value;
    final at = _trail.isEmpty ? null : _trail.last.path;
    final found = at == null
        ? WallpaperLibrary.top(places)
        : WallpaperLibrary.inside(places, at);
    setState(() => _found = found);
    if (found.isEmpty) return;
    // A new folder is a new queue: what was wanted was in the last one.
    _at = _initialIndex(found);
    final first = found[_at];
    _want(first.isFolder ? null : first.path);
  }

  void _open(WallpaperCandidate folder) {
    setState(() {
      _trail.add(folder);
      _found = null;
    });
    _list();
  }

  /// Back up a folder. False at the top, where there is nowhere left to go
  /// and the screen itself should close.
  bool _up() {
    if (_trail.isEmpty) return false;
    setState(() {
      _trail.removeLast();
      _found = null;
    });
    _list();
    return true;
  }

  /// What the bar says: the folder being looked at, or the setting's own
  /// name at the top.
  String get _title => _trail.isEmpty ? widget.entry.label : _trail.last.name;

  @override
  void dispose() {
    _settling?.cancel();
    _breathing?.cancel();
    super.dispose();
  }

  /// Put [path] at the head of the queue - null for a row that has no
  /// picture of its own - and set the sweep going once the wheel has
  /// stopped moving.
  ///
  /// The settle is about *order*, not about whether: everything in the
  /// folder is read in the end, and this only says which one is read
  /// first. A spin passing over thirty rows should not put thirty of them
  /// at the head of the queue in the order they were passed.
  ///
  /// It schedules even where there is nothing to want - a row already
  /// read, a folder - because the sweep has the rest of the folder to get
  /// through and this is what starts it.
  void _want(String? path) {
    _wanted = path != null && !_palettes.containsKey(path) ? path : null;
    _settling?.cancel();
    _settling = Timer(_settle, _pump);
  }

  /// Read the next picture, then the one after it, until the folder is
  /// done or the screen is gone.
  Future<void> _pump() async {
    if (!mounted || _reading) return;
    final path = _next();
    if (path == null) return;
    _reading = true;
    try {
      // The reading stays here - the filesystem is the player's, and a
      // chroot or a memory tree does not cross to another isolate - and
      // only the decoding goes away, which is the part that costs.
      final bytes = await PlayerServicesScope.of(
        context,
      ).places.value.fileSystem.file(path).readAsBytes();
      final preview = await _decode(bytes);
      if (!mounted) return;
      setState(() {
        _palettes[path] = preview.palettes;
        final thumbnail = preview.thumbnail;
        if (thumbnail != null) _thumbs[path] = MemoryImage(thumbnail);
      });
    } on Object catch (error) {
      // Asked and answered: a picture this build cannot read is recorded
      // as having no palette, so the sweep does not come back to it.
      debugPrint('wallpaper: $path: $error');
      if (mounted) setState(() => _palettes[path] = const []);
    } finally {
      _reading = false;
    }
    if (!mounted) return;
    // The one the wheel is waiting on goes straight away; the rest of the
    // folder waits a breath.
    if (_wanted != null && !_palettes.containsKey(_wanted!)) {
      unawaited(_pump());
    } else {
      _breathing?.cancel();
      _breathing = Timer(_breath, _pump);
    }
  }

  /// The next picture worth reading: the row the wheel settled on, then
  /// the unread picture nearest it, then the next nearest. Null once
  /// every picture in the folder has been read.
  String? _next() {
    final wanted = _wanted;
    if (wanted != null && !_palettes.containsKey(wanted)) return wanted;
    final found = _found;
    if (found == null) return null;
    // Outwards from the wheel, a step at a time either side, so the rows
    // on screen are done before the ones that are not.
    for (var away = 0; away < found.length; away++) {
      for (final index in {_at - away, _at + away}) {
        if (index < 0 || index >= found.length) continue;
        final candidate = found[index];
        if (candidate.isFolder) continue;
        if (!_palettes.containsKey(candidate.path)) return candidate.path;
      }
    }
    return null;
  }

  /// Read [bytes] in a background isolate.
  ///
  /// Static, and taking the bytes as an argument, for a reason worth
  /// writing down: a closure made inside a State method captures that
  /// method's whole scope, and this State holds a [Timer]. A timer cannot
  /// cross to another isolate, so an inline closure here fails every time
  /// with "object is unsendable" - the decode never runs and every row
  /// falls back to no palette at all. With nothing in scope but the
  /// parameter, there is nothing unsendable to capture.
  static Future<WallpaperPreview> _decode(Uint8List bytes) =>
      Isolate.run(() => Wallpapers.preview(bytes, count: 1));

  int _initialIndex(List<WallpaperCandidate> found) {
    final current =
        '${SettingsScope.of(context).value(widget.entry.path) ?? ''}';
    return found
        .indexWhere((candidate) => candidate.name == current)
        .clamp(0, found.length - 1);
  }

  Future<void> _choose(WallpaperCandidate candidate) async {
    if (_busy != null) return;
    setState(() => _busy = candidate.path);
    final store = SettingsScope.of(context);
    final places = PlayerServicesScope.of(context).places.value;
    final took = await WallpaperSource.adopt(places, candidate.path);
    if (!mounted) return;
    setState(() => _busy = null);
    if (!took) return;
    store.set(widget.entry.path, candidate.name);
    // A new picture is a new set of readings: the one that was taken of
    // the last picture says nothing about this one.
    store.set('/settings/appearance/wallpaper/auto-palette', 0);
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) => Actions(
    actions: {
      // Menu walks back up the folders before it leaves the screen.
      WheelBackIntent: CallbackAction<WheelBackIntent>(
        onInvoke: (_) {
          if (!_up()) Navigator.of(context).maybePop();
          return null;
        },
      ),
    },
    child: Builder(builder: _body),
  );

  Widget _body(BuildContext context) {
    final scale = UiScale.of(context);
    final theme = ThemeProvider.of(context);
    final found = _found ?? const <WallpaperCandidate>[];

    if (found.isEmpty) {
      return PanelScreen(
        title: _title,
        child: ContentMessage(
          child: Padding(
            padding: EdgeInsets.all(theme.space.x4),
            child: BodyText(
              _trail.isEmpty
                  ? 'No pictures found. Put some in a Wallpapers folder on '
                        'the card, or in ${WallpaperLibrary.folder} at home.'
                  : 'No images found in this folder.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final current =
        '${SettingsScope.of(context).value(widget.entry.path) ?? ''}';
    return PanelScreen(
      title: _title,
      child: PanelList.builder(
        itemExtent: SettingTile.extentOf(scale),
        itemCount: found.length,
        autofocus: true,
        initialIndex: _initialIndex(found),
        onSelectionChanged: (index) {
          // A folder has no palette of its own, but the sweep still reads
          // outwards from wherever the wheel is standing.
          _at = index;
          final candidate = found[index];
          _want(candidate.isFolder ? null : candidate.path);
        },
        onActivate: (index) {
          final candidate = found[index];
          if (candidate.isFolder) {
            _open(candidate);
          } else {
            unawaited(_choose(candidate));
          }
        },
        itemBuilder: (context, index, selected) {
          final candidate = found[index];
          final palettes = _palettes[candidate.path];
          return SettingTile(
            title: candidate.name,
            icon: candidate.isFolder ? MenuIcons.of('folder') : null,
            leading: candidate.isFolder
                ? null
                : _Thumbnail(image: _thumbs[candidate.path]),
            trailing: candidate.isFolder
                ? Icon(theme.icons.chevronRight, size: theme.sizes.iconLarge)
                : _busy == candidate.path
                ? Spinner(size: theme.sizes.icon)
                : _PaletteDots(
                    key: palettes == null
                        ? null
                        : WallpaperPickerScreen.dotsKey(candidate.path),
                    palette: palettes == null || palettes.isEmpty
                        ? null
                        : palettes.first,
                    // Asked for and not yet answered: the row the wheel
                    // is on, while its picture is being read. The rest
                    // of the folder is being read too, but quietly -
                    // ninety spinners is not a page, it is weather.
                    loading: selected && palettes == null,
                    chosen: candidate.name == current,
                  ),
          );
        },
      ),
    );
  }
}

/// The square of a picture that goes beside its name.
///
/// A box of the right size either way, so a row does not change shape
/// when its picture arrives: before, the quiet ground a card is made of;
/// after, the picture itself, at the same corners.
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({this.image});

  final ImageProvider? image;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final image = this.image;
    final side = SettingTileMetrics(UiScale.of(context)).title;
    final corners = theme.radii.small;
    final ground = theme.widgets.surface.resolve(
      SemanticSwatch.neutral,
      SurfaceVariant.soft,
    );

    return SizedBox(
      width: side,
      height: side,
      child: DecoratedBox(
        decoration: BoxDecoration(color: ground.fill, borderRadius: corners),
        child: image == null
            ? null
            : ClipRRect(
                borderRadius: corners,
                clipBehavior: Clip.antiAlias,
                // A square of a square: the thumbnail was cropped square
                // when it was read, so this only ever scales it.
                child: Image(image: image, fit: BoxFit.cover),
              ),
      ),
    );
  }
}

/// The three colors a picture would give, as discs.
///
/// A row whose picture is being read shows a spinner instead: the wait is
/// a decode, and on a folder of photographs it is long enough to be worth
/// admitting to. A row nobody has asked about shows nothing at all rather
/// than a spinner that would never turn - the palettes are read for the
/// row the wheel is on, not for the whole list.
class _PaletteDots extends StatelessWidget {
  const _PaletteDots({
    required this.palette,
    required this.chosen,
    this.loading = false,
    super.key,
  });

  final WallpaperPalette? palette;
  final bool chosen;

  /// Whether this row's palette has been asked for and not yet arrived.
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final palette = this.palette;
    final size = theme.sizes.iconSmall;
    final light = theme.palette.brightness == Brightness.light;

    if (palette == null && loading) {
      return Spinner(size: theme.sizes.icon, color: theme.palette.text);
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: theme.space.x1,
      children: [
        if (palette != null)
          for (final name in [palette.primary, palette.accent, palette.neutral])
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: light
                    ? Swatch.named[name]!.s600
                    : Swatch.named[name]!.s400,
              ),
            ),
        if (chosen) ...[
          SizedBox(width: theme.space.x1),
          Icon(theme.icons.confirm, size: theme.sizes.iconSmall),
        ],
      ],
    );
  }
}

/// Which of the wallpaper's readings of itself the UI is mixed from.
///
/// A picture usually suggests more than one honest palette - the color that
/// covers the most of it and the color that leaps out of it are rarely the
/// same - so they are all offered, best first, and this is where one is
/// taken. Only the slots set to follow the wallpaper move with it; a slot
/// that names its own swatch is not touched.
class WallpaperPaletteScreen extends StatelessWidget {
  const WallpaperPaletteScreen({required this.entry, super.key});

  final SettingLocation entry;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final scale = UiScale.of(context);
    final store = SettingsScope.of(context);

    return PanelScreen(
      title: entry.label,
      child: ValueListenableBuilder(
        valueListenable: WallpaperSource.palettes,
        builder: (context, palettes, _) {
          if (palettes.isEmpty) {
            return ContentMessage(
              child: Padding(
                padding: EdgeInsets.all(theme.space.x4),
                child: const BodyText(
                  'No wallpaper palette is available. Choose an image first.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          final chosen = store
              .read<int>(entry.path)
              .clamp(0, palettes.length - 1);
          return PanelList(
            itemExtent: SettingTile.extentOf(scale),
            autofocus: true,
            initialIndex: chosen,
            onActivate: (index) {
              store.set(entry.path, index);
              Navigator.of(context).maybePop();
            },
            children: [
              for (final (index, palette) in palettes.indexed)
                SettingTile(
                  title: _nameOf(index),
                  trailing: _PaletteDots(
                    palette: palette,
                    chosen: index == chosen,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// What a palette is called on the list. Not the swatch names - three of
  /// those is a line nobody reads - but where it came in the ranking, with
  /// the colors themselves beside it saying the rest.
  static String _nameOf(int index) => switch (index) {
    0 => 'Best match',
    1 => 'Second',
    2 => 'Third',
    _ => 'Alternative ${index + 1}',
  };
}
