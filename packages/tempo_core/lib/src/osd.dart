import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tomeui/tomeui.dart';

import 'services/output.dart';
import 'services/readings.dart';
import 'services/volume.dart';
import 'status.dart';

/// The one style every on-screen notice wears: a glyph, a body, and a
/// short trailing word, white on a dark translucent card low on the
/// panel. Depth is opacity here, as everywhere on this panel.
///
/// The volume shows on one (a bar and the number); an output change on
/// another (its name); a Bluetooth device, when there is one, on the same.
/// Uniform on purpose: a notice is a notice.
class OsdToast extends StatelessWidget {
  const OsdToast({required this.icon, this.body, this.trailing, super.key});

  final IconData icon;

  /// What sits between the glyph and the trailing word: a bar, a label.
  final Widget? body;

  /// The short word on the right: a number, a state.
  final String? trailing;

  /// The card, for a test that wants to know whether one is up.
  static const cardKey = Key('OsdToast.card');

  /// The dress every notice wears - and the now-playing card, and the
  /// library line: the theme's neutral surface in its subtle variant, so
  /// the chrome that floats over the wallpaper is the theme's own.
  static SurfaceStyle dress(Theme theme) => theme.widgets.surface.resolve(
    SemanticSwatch.neutral,
    SurfaceVariant.subtle,
  );

  /// The ink on that dress.
  static Color ink(Theme theme) => dress(theme).foreground;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final dress = OsdToast.dress(theme);
    final ink = dress.foreground;
    return DecoratedBox(
      key: cardKey,
      decoration: BoxDecoration(
        color: dress.fill,
        border: dress.border == null
            ? null
            : Border.all(color: dress.border!, width: theme.strokes.hairline),
        borderRadius: dress.radius,
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: theme.space.x3,
          vertical: theme.space.x2,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: theme.sizes.iconExtraLarge, color: ink),
            if (body != null) ...[
              SizedBox(width: theme.space.x2),
              SizedBox(
                width: theme.sizes.content - theme.sizes.dialog / 2,
                child: body,
              ),
            ],
            if (trailing != null) ...[
              SizedBox(width: theme.space.x2),
              SizedBox(
                // Three digits' worth, so a bar does not jog as 9 turns
                // into 10.
                width: 3 * (theme.typography.subtitle.fontSize ?? 10) * 0.7,
                child: Text(
                  trailing!,
                  textAlign: TextAlign.right,
                  style: readingStyle(theme).copyWith(color: ink),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A level as a bar: 0..1 of the width lit, in the primary swatch - the
/// track its subtle wash, the lit part the swatch itself. The volume
/// notice's body, and the track's progress on the now-playing card.
class OsdBar extends StatelessWidget {
  const OsdBar({required this.value, this.height, this.litKey, super.key});

  /// 0..1.
  final double value;

  /// The bar's height; the theme's third step unless told otherwise.
  final double? height;

  /// The lit part's key, for a test that wants to measure it; [fillKey]
  /// by default.
  final Key? litKey;

  /// The lit part, for a test that wants to measure it.
  static const fillKey = Key('OsdBar.fill');

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final lit = (value.clamp(0.0, 1.0) * 1000).round();
    final dress = theme.widgets.surface.resolve(
      SemanticSwatch.primary,
      SurfaceVariant.subtle,
    );
    final height = this.height ?? theme.space.x3;
    return SizedBox(
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: dress.fill,
          border: dress.border == null
              ? null
              : Border.all(color: dress.border!, width: theme.strokes.hairline),
          borderRadius: BorderRadius.circular(height / 2),
        ),
        // Two flexes rather than a fraction of a loose box: the split is
        // exact at either end, and needs no constraint to lean on. Stretched
        // to the bar's height: a decorated box with nothing in it is as
        // tall as it is told to be, and told nothing it is a line of zero.
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (lit > 0)
              Expanded(
                flex: lit,
                child: DecoratedBox(
                  key: litKey ?? fillKey,
                  decoration: BoxDecoration(
                    color: dress.foreground,
                    borderRadius: BorderRadius.circular(height / 2),
                  ),
                ),
              ),
            if (lit < 1000) Expanded(flex: 1000 - lit, child: const SizedBox()),
          ],
        ),
      ),
    );
  }
}

/// The notice that is up right now, and its clock.
///
/// One slot: a new notice replaces the last, and every [show] restarts
/// the clock that puts it away. The [OsdLayer] above the navigator draws
/// whatever is here, fading it in and out, and leaves the tree when the
/// slot is empty.
abstract final class Osd {
  /// What to draw, or null for nothing.
  static final ValueNotifier<WidgetBuilder?> current = ValueNotifier(null);

  /// How long a notice stays after the last [show].
  static const Duration linger = Duration(milliseconds: 1500);

  /// How long it takes to fade in, and out.
  static const Duration fade = Duration(milliseconds: 150);

  static Timer? _clock;

  /// Put [builder] up, or keep it up: every call restarts the clock.
  static void show(WidgetBuilder builder) {
    _clock?.cancel();
    current.value = builder;
    _clock = Timer(linger, () => current.value = null);
  }

  /// Put it away now, clock or no clock.
  static void hide() {
    _clock?.cancel();
    _clock = null;
    current.value = null;
  }
}

/// The volume on screen while it moves: a square card with the glyph over
/// a bar.
abstract final class VolumeOsd {
  /// The card, for a test.
  static const cardKey = OsdToast.cardKey;

  static const Duration linger = Osd.linger;
  static const Duration fade = Osd.fade;

  /// Bring the volume up, or keep it up.
  static void show(VolumeService volume) =>
      Osd.show((context) => VolumeToast(volume: volume));

  static void hide() => Osd.hide();

  /// A level about to be asked for by a control that shows it already -
  /// the slider in Settings - so the display need not repeat it. The
  /// mixer's echo of that one level passes [VolumeToasts] in silence;
  /// any other level, from anywhere, still shows.
  static void quietly(int level) => _quietLevel = level.clamp(0, 100);

  static int? _quietLevel;

  static bool _consumeQuiet(int level) {
    if (_quietLevel != level) return false;
    _quietLevel = null;
    return true;
  }
}

/// Show volume changes regardless of whether they came from local controls
/// or the sound server (including Bluetooth absolute-volume notifications).
class VolumeToasts extends StatefulWidget {
  const VolumeToasts({required this.volume, required this.awake, super.key});

  final VolumeService volume;
  final bool awake;

  @override
  State<VolumeToasts> createState() => _VolumeToastsState();
}

class _VolumeToastsState extends State<VolumeToasts> {
  @override
  void initState() {
    super.initState();
    widget.volume.addListener(_moved);
  }

  @override
  void didUpdateWidget(VolumeToasts oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.volume != oldWidget.volume) {
      oldWidget.volume.removeListener(_moved);
      widget.volume.addListener(_moved);
    }
  }

  void _moved() {
    if (VolumeOsd._consumeQuiet(widget.volume.value.level)) return;
    if (widget.awake) VolumeOsd.show(widget.volume);
  }

  @override
  void dispose() {
    widget.volume.removeListener(_moved);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// The volume, as a square: the glyph over a bar the width of the card.
///
/// Square rather than the notices' strip, and without the number the strip
/// carried. A level being turned by a rocker is read at a glance and let
/// go of - the glyph says which end of the range it is at, the bar says
/// how far along, and a number is a third way of saying the same thing
/// that has to be focused on to be read.
class VolumeToast extends StatelessWidget {
  const VolumeToast({required this.volume, super.key});

  final VolumeService volume;

  /// How big the square is: half the room a dialog gets, which on the
  /// panel is a card the thumb's own size.
  static double sideOf(Theme theme) => theme.sizes.dialog / 2;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    // The notices' own neutral wash: the volume is a transient, not a
    // thing to be picked out in the brand's color.
    final dress = OsdToast.dress(theme);
    final ink = dress.foreground;
    final side = sideOf(theme);

    return ValueListenableBuilder(
      valueListenable: volume,
      builder: (context, reading, _) {
        final level = reading.level;
        return DecoratedBox(
          key: OsdToast.cardKey,
          decoration: BoxDecoration(
            color: dress.fill,
            border: dress.border == null
                ? null
                : Border.all(
                    color: dress.border!,
                    width: theme.strokes.hairline,
                  ),
            borderRadius: theme.radii.small,
          ),
          child: SizedBox.square(
            dimension: side,
            child: Padding(
              padding: EdgeInsets.all(theme.space.x3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 4,
                    child: Center(
                      child: Icon(
                        reading.device != null
                            ? LucideIcons.bluetooth
                            : reading.muted || level == 0
                            ? LucideIcons.volumeX
                            : level < 34
                            ? LucideIcons.volume
                            : level < 67
                            ? LucideIcons.volume1
                            : LucideIcons.volume2,
                        // The glyph is the card: at the notices' icon size
                        // a square this big would be mostly empty.
                        size: side * 0.42,
                        color: ink,
                      ),
                    ),
                  ),
                  if (reading.device != null) ...[
                    Text(
                      reading.device!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: readingStyle(theme).copyWith(color: ink),
                    ),
                    Text(
                      reading.hardware ? '$level%' : 'Player $level%',
                      textAlign: TextAlign.center,
                      style: readingStyle(theme).copyWith(color: ink),
                    ),
                  ],
                  SizedBox(height: theme.space.x2),
                  OsdBar(value: level / 100),
                  // Air under the bar, so it sits in the lower third
                  // rather than along the card's bottom edge.
                  const Spacer(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Where the sound goes, when that changes: the jack in or out, a
/// Bluetooth device on or off. Shown by [OutputToasts]; built here.
class OutputToast extends StatelessWidget {
  const OutputToast({required this.output, super.key});

  final AudioOutput output;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    return OsdToast(
      icon: switch (output.kind) {
        OutputKind.speaker => LucideIcons.speaker,
        OutputKind.headphones => LucideIcons.headphones,
        OutputKind.bluetooth => LucideIcons.bluetooth,
      },
      body: Text(
        output.label,
        style: readingStyle(theme).copyWith(color: OsdToast.ink(theme)),
      ),
    );
  }
}

/// Watches the output and puts an [OutputToast] up when it moves. Draws
/// nothing itself; sits in the app above the navigator with the layer.
class OutputToasts extends StatefulWidget {
  const OutputToasts({required this.output, super.key});

  final OutputService output;

  @override
  State<OutputToasts> createState() => _OutputToastsState();
}

class _OutputToastsState extends State<OutputToasts> {
  /// Read at once, not lazily: read first from inside [_moved] it would
  /// already be the new value, and no change would ever show.
  late AudioOutput _last;

  @override
  void initState() {
    super.initState();
    _last = widget.output.value;
    widget.output.addListener(_moved);
  }

  @override
  void didUpdateWidget(OutputToasts oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.output != oldWidget.output) {
      oldWidget.output.removeListener(_moved);
      widget.output.addListener(_moved);
      _last = widget.output.value;
    }
  }

  @override
  void dispose() {
    widget.output.removeListener(_moved);
    super.dispose();
  }

  void _moved() {
    final output = widget.output.value;
    if (output == _last) return;
    _last = output;
    Osd.show((context) => OutputToast(output: output));
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// The layer above the navigator that draws the current notice: fades it
/// in on arrival, out on departure, and leaves the tree in between so an
/// idle frame composites nothing extra.
class OsdLayer extends StatefulWidget {
  const OsdLayer({super.key});

  @override
  State<OsdLayer> createState() => _OsdLayerState();
}

class _OsdLayerState extends State<OsdLayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: Osd.fade,
    value: Osd.current.value == null ? 0 : 1,
  );

  /// The last builder, kept through the fade-out so the card does not
  /// vanish before it has faded.
  WidgetBuilder? _shown = Osd.current.value;

  @override
  void initState() {
    super.initState();
    Osd.current.addListener(_follow);
  }

  @override
  void dispose() {
    Osd.current.removeListener(_follow);
    _fade.dispose();
    super.dispose();
  }

  void _follow() {
    final builder = Osd.current.value;
    if (builder != null) {
      setState(() => _shown = builder);
      _fade.forward();
    } else {
      _fade.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _fade,
      builder: (context, _) {
        final builder = _shown;
        if (_fade.isDismissed || builder == null) {
          return const SizedBox.shrink();
        }
        return IgnorePointer(
          child: FadeTransition(
            opacity: _fade,
            // Centered on the panel: a notice this size is a thing to be
            // looked at squarely rather than glanced at down in a corner,
            // and it is gone again in a moment either way.
            child: Align(
              alignment: Alignment.center,
              child: Builder(builder: builder),
            ),
          ),
        );
      },
    );
  }
}

/// The card on screen as it comes and goes: a glyph and a word, the way
/// the output says where the sound went.
class CardToast extends StatelessWidget {
  const CardToast({required this.present, super.key});

  final bool present;

  @override
  Widget build(BuildContext context) => OsdToast(
    icon: LucideIcons.hardDrive,
    body: Text(present ? 'SD card inserted' : 'SD card removed'),
  );
}

/// Watches the slot and puts a [CardToast] up when a card comes or goes.
/// Draws nothing itself; sits in the app above the navigator with the
/// layer. The first reading is the baseline: a card found in the slot at
/// startup is not an arrival.
class CardToasts extends StatefulWidget {
  const CardToasts({required this.storage, super.key});

  final ValueListenable<StorageReading> storage;

  @override
  State<CardToasts> createState() => _CardToastsState();
}

class _CardToastsState extends State<CardToasts> {
  late bool _present;

  @override
  void initState() {
    super.initState();
    _present = widget.storage.value.present;
    widget.storage.addListener(_moved);
  }

  @override
  void didUpdateWidget(CardToasts oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.storage, widget.storage)) {
      oldWidget.storage.removeListener(_moved);
      widget.storage.addListener(_moved);
      _present = widget.storage.value.present;
    }
  }

  @override
  void dispose() {
    widget.storage.removeListener(_moved);
    super.dispose();
  }

  void _moved() {
    final present = widget.storage.value.present;
    if (present == _present) return;
    _present = present;
    Osd.show((context) => CardToast(present: present));
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
