import 'package:tomeui/tomeui.dart';

/// A line of text that is ellipsized until the wheel is on it, and then
/// walks itself past so the rest can be read.
///
/// A panel 480 pixels wide cuts most sentences off, and a description a
/// user cannot finish reading is a description that may as well not be
/// there. So the row under the cursor moves: the words slide left until
/// their end is on screen, wait, and slide back.
///
/// It moves a bounded number of times ([passes]) rather than forever. A
/// line that never stops is noise on a screen with six rows on it, and by
/// the third pass either it has been read or the row is not the one that
/// was wanted. Selecting the row again starts it over.
///
/// A line that fits is a plain [Text] and no ticker at all: the only rows
/// that cost anything are the ones with something to say.
class MarqueeText extends StatefulWidget {
  const MarqueeText(
    this.data, {
    this.style,
    this.active = false,
    this.passes = 2,
    super.key,
  });

  final String data;
  final TextStyle? style;

  /// Whether the wheel is on this row.
  final bool active;

  /// How many times it walks out and back before resting.
  final int passes;

  /// How long the words wait at each end before moving.
  static const Duration pause = Duration(milliseconds: 900);

  /// How fast they move, in logical pixels a second. Slow enough to read
  /// at, which is slower than it feels like it should be.
  static const double speed = 22;

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  /// Made only for the lines that actually walk. A row whose description
  /// fits keeps no ticker at all - and a late field would have made one
  /// on the way out, which is a lookup no widget may do while it is being
  /// taken down.
  AnimationController? _walk;

  AnimationController get _controller =>
      _walk ??= AnimationController(vsync: this);

  /// How far the words reach past their line, in pixels. Zero when they
  /// fit, which is what says there is nothing to do.
  double _overflow = 0;

  /// The animation, built for the current overflow: out, a wait, back, a
  /// wait - [MarqueeText.passes] times over.
  Animation<double>? _offset;

  @override
  void dispose() {
    _walk?.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active != oldWidget.active || widget.data != oldWidget.data) {
      _restart();
    }
  }

  /// Start walking, or stop and go back to the beginning.
  void _restart() {
    // Nothing to walk, and nothing made to walk it with.
    if (!widget.active || _overflow <= 0.5) {
      _walk
        ?..stop()
        ..value = 0;
      return;
    }
    final walk = _controller..stop();
    walk.value = 0;

    // The whole trip: out at [speed], a wait, back at [speed], a wait.
    final travel = Duration(
      milliseconds: (_overflow / MarqueeText.speed * 1000).round(),
    );
    final pass = travel * 2 + MarqueeText.pause * 2;
    final out = travel.inMilliseconds / pass.inMilliseconds;
    final wait = MarqueeText.pause.inMilliseconds / pass.inMilliseconds;

    _offset = TweenSequence<double>([
      TweenSequenceItem(tween: ConstantTween(0), weight: wait),
      TweenSequenceItem(
        tween: Tween(begin: 0, end: -_overflow),
        weight: out,
      ),
      TweenSequenceItem(tween: ConstantTween(-_overflow), weight: wait),
      TweenSequenceItem(
        tween: Tween(begin: -_overflow, end: 0),
        weight: out,
      ),
    ]).animate(walk);

    // One trip is the controller's whole run, and the run repeats: a
    // sequence stretched over every pass would have walked at a fraction
    // of the speed and waited that much longer to start.
    walk.duration = pass;
    walk.repeat(count: widget.passes);
  }

  @override
  Widget build(BuildContext context) {
    final style =
        widget.style ?? DefaultTextStyle.of(context).style.merge(widget.style);

    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.data, style: style),
          maxLines: 1,
          textDirection: Directionality.of(context),
        )..layout();
        final overflow = (painter.width - constraints.maxWidth).clamp(
          0.0,
          double.infinity,
        );
        // The line's own height, which the walking shape has to keep to
        // the pixel: an [OverflowBox] takes all the height it is offered,
        // and a description that grew taller the moment the wheel landed
        // on it would shove everything under it down the row.
        final line = painter.height;
        painter.dispose();

        // The line's own width decides whether there is anything to walk,
        // and the walk has to be rebuilt when it changes - a scale change,
        // a longer description on the same row.
        if ((overflow - _overflow).abs() > 0.5) {
          _overflow = overflow;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _restart();
          });
        }

        // Nothing to walk, or nobody to walk it for: the plain thing,
        // ellipsized, with no ticker behind it. A row the wheel is not on
        // says as much as fits and stops - a screen of moving lines is
        // unreadable.
        if (overflow <= 0.5 || !widget.active) {
          return Text(
            widget.data,
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
          );
        }

        return SizedBox(
          height: line,
          child: ClipRect(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) => Transform.translate(
                offset: Offset(_offset?.value ?? 0, 0),
                child: child,
              ),
              // Laid out at its full width - the clip is what makes the
              // line - so the words do not re-wrap as they move.
              child: OverflowBox(
                alignment: AlignmentDirectional.centerStart,
                maxWidth: double.infinity,
                child: Text(
                  widget.data,
                  style: style,
                  maxLines: 1,
                  softWrap: false,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
