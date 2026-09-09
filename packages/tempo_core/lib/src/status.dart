import 'dart:async';

import 'battery_gauge.dart';

import 'package:flutter/scheduler.dart';
import 'package:tomeui/tomeui.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'osd.dart';
import 'services/services.dart';

/// Frame throughput, from the engine's own frame timings - works in every
/// build mode, unlike the framework's performance overlay (release strips
/// it). Frames counted over a fixed window, scaled to per-second; an idle
/// UI paints no frames, so at rest it reads "---fps", not zero.
///
/// A half-transparent black-on-white chip: the wash lightens a dark
/// surface and the black text darkens a light one, so it stays legible
/// wherever it sits. Pinned by its parent (see TempoApp).
class FpsText extends StatefulWidget {
  const FpsText({super.key});

  @override
  State<FpsText> createState() => _FpsTextState();
}

class _FpsTextState extends State<FpsText> {
  static const _window = Duration(milliseconds: 500);

  Timer? _timer;
  final List<FrameTiming> _timings = [];
  String _display = '---fps';

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _timer = Timer.periodic(_window, (_) => _publish());
  }

  @override
  void dispose() {
    _timer?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    super.dispose();
  }

  void _onTimings(List<FrameTiming> timings) {
    _timings.addAll(timings);
  }

  void _publish() {
    String display;
    if (_timings.isEmpty) {
      display = '---fps';
    } else {
      final fps = _timings.length * 1000 / _window.inMilliseconds;
      // Right-aligned to the three dashes at rest, so the digits sit in
      // the same monospace columns whether it reads 5, 60, or "---".
      display = '${fps.round().toString().padLeft(3)}fps';
      _timings.clear();
    }
    if (mounted && display != _display) {
      setState(() => _display = display);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mono = ThemeProvider.of(context).typography.code.copyWith(
      fontSize: 8,
      height: 1.0,
      color: const Color(0xFF000000),
    );
    // A fixed-width slot for the six characters, right-aligned. flutter-pi's
    // engine doesn't honor the MONO font-variation axis, so the "monospace"
    // face isn't actually fixed-pitch here and the chip would breathe as the
    // digits change; the SizedBox makes the six columns constant regardless.
    // Opacity over the whole chip - box and text together at half - so the
    // white never fully hides its background and the reading stays honest.
    return Opacity(
      opacity: 0.5,
      child: DecoratedBox(
        decoration: const BoxDecoration(color: Color(0xFFFFFFFF)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
          child: SizedBox(
            width: 30,
            child: Text(_display, textAlign: TextAlign.right, style: mono),
          ),
        ),
      ),
    );
  }
}

/// What the player is doing with sound, for the bars to show. A stand-in
/// until there is a player: it starts stopped and stays there unless
/// something says otherwise.
enum PlaybackState { stopped, playing, paused }

/// What the bar shows at its trailing end, from Settings > Appearance >
/// Status Bar.
abstract final class StatusReadings {
  static final batteryIcon = ValueNotifier<bool>(true);
  static final batteryPercent = ValueNotifier<bool>(false);
  static final wifiIcon = ValueNotifier<bool>(true);
  static final bluetoothIcon = ValueNotifier<bool>(true);
  static final playGlyph = ValueNotifier<bool>(true);
  static final hideIdle = ValueNotifier<bool>(true);

  static final changes = Listenable.merge([
    batteryIcon,
    batteryPercent,
    wifiIcon,
    bluetoothIcon,
    playGlyph,
    hideIdle,
  ]);
}

abstract final class Playback {
  static final state = ValueNotifier<PlaybackState>(PlaybackState.stopped);
}

/// The play state as a glyph: playing or paused, and nothing at all
/// otherwise. Leads the status cluster.
///
/// Two states, not three. The bar's job is to say what is going on, and a
/// stopped player is not going on - it is the ordinary state of a player at
/// rest, and a square standing there through all of it says only that the
/// bar has an icon for it.
class PlayStateGlyph extends StatelessWidget {
  const PlayStateGlyph({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final size = readingGlyphSize(theme);
    return ValueListenableBuilder(
      valueListenable: Playback.state,
      builder: (context, state, _) {
        final glyph = switch (state) {
          PlaybackState.playing => LucideIcons.play,
          PlaybackState.paused => LucideIcons.pause,
          PlaybackState.stopped => null,
        };
        if (glyph == null) return const SizedBox.shrink();
        return Icon(glyph, size: size, color: theme.palette.text);
      },
    );
  }
}

/// A glyph turning: the loader's ring, a turn a second, for as long as it
/// is in the tree. Leaves the tree when the wait is over rather than
/// standing still, so an idle bar paints nothing.
class Spinner extends StatefulWidget {
  const Spinner({required this.size, this.color, super.key});

  final double size;
  final Color? color;

  static const Duration turn = Duration(seconds: 1);

  @override
  State<Spinner> createState() => _SpinnerState();
}

class _SpinnerState extends State<Spinner> with SingleTickerProviderStateMixin {
  late final AnimationController _turns = AnimationController(
    vsync: this,
    duration: Spinner.turn,
  )..repeat();

  @override
  void dispose() {
    _turns.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(
    turns: _turns,
    child: Icon(
      LucideIcons.loaderCircle,
      size: widget.size,
      color: widget.color,
    ),
  );
}

/// The library taking in music, along the bottom of home: a spinner, the
/// words, and how far along it is - files done over files that are new
/// or changed - and nothing at all otherwise. Not the scan: looking over
/// an unchanged card is quiet work, and a line for it would be up on
/// every boot. Sits in the page's flow, so home steps up to make room
/// rather than being covered.
class LibraryFooter extends StatelessWidget {
  const LibraryFooter({super.key});

  static const footerKey = Key('LibraryFooter');
  static const countKey = Key('LibraryFooter.count');

  /// Whether there is anything to say: media being taken in.
  static bool shows(LibraryStatus status) {
    final scan = status.scan;
    return status.scanning &&
        scan != null &&
        scan.changed > 0 &&
        (scan.state == ScanState.extracting ||
            scan.state == ScanState.finishing);
  }

  /// What the count reads: the files the scan has landed over the files
  /// it found new or changed. Never past the total: an error is not
  /// always a file (a folder that would not list is one too).
  static String countOf(ScanStatus scan) {
    final done = scan.added + scan.updated + scan.errorCount;
    return '${done > scan.changed ? scan.changed : done} / ${scan.changed}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final library = PlayerServicesScope.of(context).library;
    return ValueListenableBuilder(
      valueListenable: library.status,
      builder: (context, status, _) {
        if (!shows(status)) return const SizedBox.shrink();
        final scan = status.scan!;
        // The notices' dress, like the now-playing card above it.
        final dress = OsdToast.dress(theme);
        final ink = dress.foreground;
        return DecoratedBox(
          key: footerKey,
          decoration: BoxDecoration(color: dress.fill),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: theme.space.x3,
              vertical: theme.space.x1,
            ),
            child: Row(
              spacing: theme.space.x2,
              children: [
                Spinner(size: readingGlyphSize(theme), color: ink),
                Expanded(
                  child: Text(
                    'Updating Library: ${countOf(scan)}',
                    key: countKey,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: readingStyle(theme).copyWith(color: ink),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The weight the bars' readings wear: a step up from the code face's
/// own, which is thin beside the glyphs they sit with.
const readingWeight = FontWeight.w600;

/// The size the bar's type is set at: the title face's, which on the
/// classic scale is 12dp - the size that reads at life size.
double barTypeSize(Theme theme) =>
    theme.typography.title.fontSize ?? theme.sizes.iconLarge;

/// The style the bar's readings are set in: the code face a step under
/// the title's size and heavy, set solid so it sits within the bar, in the
/// bar's own text color at full strength rather than a caption's quieter
/// gray.
TextStyle readingStyle(Theme theme) => theme.typography.code.copyWith(
  fontSize: theme.typography.subtitle.fontSize,
  fontWeight: readingWeight,
  height: 1,
);

/// The size of a glyph on the bar: two steps under the title's size.
///
/// The play state's, at the leading end, where it stands alone against the
/// page's name and wants to be read at the name's weight.
double readingGlyphSize(Theme theme) =>
    theme.typography.label.fontSize ?? theme.sizes.icon;

/// The size of the readings at the trailing end - the radios' glyphs and
/// the battery - one step under [readingGlyphSize].
///
/// A step down from the play state's because there are three or four of
/// them in a row rather than one: at the leading glyph's size the cluster
/// crowds the name it shares the bar with, and these are things to be
/// glanced at rather than read.
double statusGlyphSize(Theme theme) =>
    theme.typography.caption.fontSize ?? theme.sizes.iconSmall;

/// The clock's face on home: the readings' mono digits and weight, white
/// with a soft shadow so it reads on any wallpaper.
TextStyle homeClockStyle(Theme theme, {required double size}) =>
    theme.typography.code.copyWith(
      fontSize: size,
      fontWeight: readingWeight,
      height: 1,
      color: const Color(0xFFFFFFFF),
      shadows: const [Shadow(blurRadius: 6, color: Color(0x99000000))],
    );

/// The clock on the home screen: full size in the middle of the page
/// while nothing is playing, and gone once something is - the bar's
/// title slot shows it then (`BarChrome.clock`), where "Home" would be,
/// and the cover has the page.
class HomeClock extends StatelessWidget {
  const HomeClock({super.key});

  /// The face at rest: twice the display size.
  static double restSize(Theme theme) =>
      2 * (theme.typography.display.fontSize ?? 20);

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    return ValueListenableBuilder(
      valueListenable: Playback.state,
      builder: (context, state, _) => state == PlaybackState.stopped
          ? Center(
              child: ClockText(
                style: homeClockStyle(theme, size: restSize(theme)),
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}

/// Explicit zone conversion avoids Dart's cached process-local time zone.
/// Both the home clock and the bar observe this same selection.
abstract final class ClockZone {
  static final selected = ValueNotifier<String>('UTC');
  static final bool _initialized = _initialize();

  static bool _initialize() {
    tzdata.initializeTimeZones();
    return true;
  }

  static tz.Location location(String zone) {
    if (!_initialized) throw StateError('Time zone database unavailable');
    return zone == 'UTC' ? tz.UTC : tz.getLocation(zone);
  }

  static DateTime at(DateTime instant) =>
      tz.TZDateTime.from(instant, location(selected.value));
}

/// How the player writes the time of day.
///
/// Settings > Time & Language > Clock Format moves this; every clock on
/// the player reads it, so the bar and home never disagree.
abstract final class ClockFormat {
  /// Whether the clock is written on a 24-hour dial. The player starts
  /// there: a two-digit hour is one less thing for the eye to parse, and
  /// it keeps the reading the same width all day.
  static final hour24 = ValueNotifier<bool>(true);

  /// [at] as the player writes it: the dial, and the meridiem that goes
  /// after it on a twelve-hour one.
  ///
  /// Twelve-hour keeps its meridiem - a clock that cannot tell nine in the
  /// morning from nine at night is not telling the time - and drops the
  /// leading zero, which is what makes the twelve-hour dial read as one.
  /// The two come back apart because they are not set at the same size:
  /// at the home clock's full height, "PM" in the digits' own size runs
  /// the reading off both edges of the panel.
  static (String, String?) parts(DateTime at) {
    final minute = at.minute.toString().padLeft(2, '0');
    if (hour24.value) {
      return ('${at.hour.toString().padLeft(2, '0')}:$minute', null);
    }
    final hour = at.hour % 12 == 0 ? 12 : at.hour % 12;
    return ('$hour:$minute', at.hour < 12 ? 'AM' : 'PM');
  }

  /// The whole reading as one string, for anything that wants it flat.
  static String format(DateTime at) {
    final (time, meridiem) = parts(at);
    return meridiem == null ? time : '$time $meridiem';
  }
}

/// The time of day, to the minute.
class ClockText extends StatefulWidget {
  const ClockText({this.style, super.key});

  /// The face, when not a bar reading's.
  final TextStyle? style;

  @override
  State<ClockText> createState() => _ClockTextState();
}

class _ClockTextState extends State<ClockText> {
  DateTime _now = DateTime.now();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    ClockZone.selected.addListener(_zoneChanged);
    _arm();
  }

  void _zoneChanged() {
    setState(() => _now = DateTime.now());
  }

  /// One shot per tick, armed against the wall clock rather than a fixed
  /// period, so the minute changes when the minute does instead of
  /// drifting away from it.
  void _arm() {
    final now = DateTime.now();
    final untilNextMinute = Duration(
      seconds: 60 - now.second,
      milliseconds: -now.millisecond,
    );
    _timer = Timer(untilNextMinute, () {
      if (!mounted) return;
      setState(() => _now = DateTime.now());
      _arm();
    });
  }

  @override
  void dispose() {
    ClockZone.selected.removeListener(_zoneChanged);
    _timer?.cancel();
    super.dispose();
  }

  /// How large the meridiem is beside the digits, and the air before it.
  static const _meridiemScale = 0.45;
  static const _meridiemGap = 0.18;

  @override
  Widget build(BuildContext context) {
    // Mono digits: the colon holds still as the minutes walk.
    final style = widget.style ?? readingStyle(ThemeProvider.of(context));
    return ValueListenableBuilder(
      valueListenable: ClockFormat.hour24,
      builder: (context, _, _) {
        final (time, meridiem) = ClockFormat.parts(ClockZone.at(_now));
        final face = CaptionText(
          time,
          emphasis: TextEmphasis.full,
          style: style,
        );
        if (meridiem == null) return face;
        final size = style.fontSize ?? 12;
        // On the digits' own baseline and well under their height: the
        // hour is the reading, and the meridiem only says which of the
        // two it is.
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            face,
            SizedBox(width: size * _meridiemGap),
            CaptionText(
              meridiem,
              emphasis: TextEmphasis.full,
              style: style.copyWith(fontSize: size * _meridiemScale),
            ),
          ],
        );
      },
    );
  }
}

/// The status cluster, ordered from playback through radios to battery.
class StatusGlyphs extends StatelessWidget {
  const StatusGlyphs({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final services = PlayerServicesScope.of(context);
    final size = statusGlyphSize(theme);
    final color = theme.palette.text;
    return ListenableBuilder(
      listenable: Listenable.merge([
        StatusReadings.changes,
        Playback.state,
        services.bluetooth,
        services.wifi,
      ]),
      builder: (context, _) {
        final bluetooth = services.bluetooth.value;
        final wifi = services.wifi.value;
        return Row(
          mainAxisSize: MainAxisSize.min,
          spacing: theme.space.x3,
          children: [
            if (StatusReadings.playGlyph.value &&
                Playback.state.value != PlaybackState.stopped)
              const PlayStateGlyph(),
            if (StatusReadings.bluetoothIcon.value &&
                (!StatusReadings.hideIdle.value ||
                    bluetooth.status != BluetoothStatus.off))
              Semantics(
                label: 'Bluetooth ${bluetooth.status.name}',
                child: CustomPaint(
                  size: Size.square(size),
                  painter: BluetoothStatusPainter(
                    status: bluetooth.status,
                    color: color,
                  ),
                ),
              ),
            if (StatusReadings.wifiIcon.value &&
                (!StatusReadings.hideIdle.value ||
                    wifi.status != WifiStatus.off))
              Semantics(
                label: wifi.status == WifiStatus.connected
                    ? 'Wi-Fi connected, ${wifi.bars >= 3
                          ? 'full'
                          : wifi.bars >= 2
                          ? 'medium'
                          : 'minimum'} signal'
                    : 'Wi-Fi ${wifi.status.name}',
                child: WifiStatusIcon(
                  size: size,
                  status: wifi.status,
                  bars: wifi.bars,
                  color: color,
                ),
              ),
            if (StatusReadings.batteryIcon.value)
              BatteryGauge(showPercent: StatusReadings.batteryPercent.value)
            else if (StatusReadings.batteryPercent.value)
              ValueListenableBuilder(
                valueListenable: services.battery,
                builder: (context, battery, _) => Text(
                  battery.percent == null ? '—%' : '${battery.percent}%',
                  style: readingStyle(theme),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Lucide's matching signal levels, retaining the status bar's idle dimming.
class WifiStatusIcon extends StatelessWidget {
  const WifiStatusIcon({
    required this.status,
    required this.bars,
    required this.color,
    required this.size,
    super.key,
  });

  final WifiStatus status;
  final int bars;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Icon(
    status == WifiStatus.off
        ? LucideIcons.wifiOff
        : status != WifiStatus.connected
        ? LucideIcons.wifi
        : switch (bars) {
            <= 0 => LucideIcons.wifiZero,
            1 => LucideIcons.wifiLow,
            2 => LucideIcons.wifiHigh,
            _ => LucideIcons.wifi,
          },
    size: size,
    color: status == WifiStatus.connected
        ? color
        : color.withValues(alpha: color.a * 0.45),
  );
}

/// Bluetooth's rune, with connection dots and an explicit off slash.
class BluetoothStatusPainter extends CustomPainter {
  const BluetoothStatusPainter({required this.status, required this.color});

  final BluetoothStatus status;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final paint = Paint()
      ..color = status == BluetoothStatus.off
          ? color.withValues(alpha: 0.5)
          : color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(
      Path()
        ..moveTo(7, 7)
        ..lineTo(17, 17)
        ..lineTo(12, 22)
        ..lineTo(12, 2)
        ..lineTo(17, 7)
        ..lineTo(7, 17),
      paint,
    );
    if (status == BluetoothStatus.connected) {
      paint.style = PaintingStyle.fill;
      canvas.drawCircle(const Offset(4, 12), 1.4, paint);
      canvas.drawCircle(const Offset(21, 12), 1.4, paint);
    } else if (status == BluetoothStatus.off) {
      paint.color = color;
      canvas.drawLine(const Offset(3, 3), const Offset(21, 21), paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(BluetoothStatusPainter oldDelegate) =>
      status != oldDelegate.status || color != oldDelegate.color;
}
