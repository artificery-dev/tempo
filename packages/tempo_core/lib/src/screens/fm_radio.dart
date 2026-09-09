import 'dart:async';
import 'dart:ui' as ui;

import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

import '../applet.dart';
import '../content_surface.dart';
import '../dock.dart';
import '../menu/menu.dart';
import '../panel_bar.dart';
import '../services/services.dart';
import '../services/video_playback.dart';

/// Start or resume FM directly on Home, without adding a route to Apps.
Future<void> openFmRadio(BuildContext context) async {
  final services = PlayerServicesScope.of(context);
  final memory = Applet.maybeOf(context)?.state;
  final old = FmRadioSession.active;
  final radio = services.tuner;
  final session = old != null && identical(old.radio, radio)
      ? old
      : FmRadioSession(radio: radio, memory: memory);
  if (!identical(old, session)) {
    // Publish the session before waiting so repeated activations reuse it.
    FmRadioSession.activate(session);
    await old?.close();
  }
  if (!identical(FmRadioSession.active, session)) return;
  VideoPlayback.active?.dispose();
  MenuDock.select(systemMenu.at('/home')!);
  await services.playback.stop();
  if (identical(FmRadioSession.active, session)) await session.start();
}

/// Broadcast radio on Home: the wheel is the dial, center stars the station,
/// and previous/next walk the stations that have been starred.
class FmRadioNowPlaying extends StatelessWidget {
  const FmRadioNowPlaying({required this.session, super.key});

  final FmRadioSession session;

  void _media(MediaIntent intent) {
    switch (intent.command) {
      case MediaCommand.previous:
        session.media(FmSeekDirection.down, held: intent.held);
      case MediaCommand.next:
        session.media(FmSeekDirection.up, held: intent.held);
      case MediaCommand.toggle:
        unawaited(session.togglePower());
    }
  }

  @override
  Widget build(BuildContext context) => PanelScreen(
    title: 'FM Radio',
    child: Actions(
      actions: {
        JogIntent: CallbackAction<JogIntent>(
          onInvoke: (intent) {
            if (session.reading.available) {
              session.jog(intent.amount, page: intent.page);
            }
            return null;
          },
        ),
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            if (session.reading.available) session.toggleFavorite();
            return null;
          },
        ),
        MediaIntent: CallbackAction<MediaIntent>(
          onInvoke: (intent) {
            if (session.reading.available) _media(intent);
            return null;
          },
        ),
        WheelBackIntent: CallbackAction<WheelBackIntent>(
          onInvoke: (_) {
            MenuDock.shown.value = true;
            return null;
          },
        ),
      },
      child: Focus(
        autofocus: true,
        debugLabel: 'FmRadioNowPlaying',
        child: ListenableBuilder(
          listenable: session,
          builder: (context, _) => session.reading.available
              ? _Tuner(
                  reading: session.reading,
                  frequencyKhz: session.frequencyKhz,
                  favorite: session.favorite,
                  favorites: session.favorites,
                  seeking: session.seeking,
                )
              : const ContentMessage(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(LucideIcons.radioTower),
                      SizedBox(height: 8),
                      BodyText(
                        'FM receiver unavailable',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
        ),
      ),
    ),
  );
}

class _Tuner extends StatelessWidget {
  const _Tuner({
    required this.reading,
    required this.frequencyKhz,
    required this.favorite,
    required this.favorites,
    required this.seeking,
  });

  final FmRadioReading reading;
  final int frequencyKhz;
  final bool favorite;
  final List<int> favorites;
  final bool seeking;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final frequency = (frequencyKhz / 1000).toStringAsFixed(1);
    final tuned = reading.frequencyKhz == frequencyKhz;
    final station = tuned ? reading.programName : null;
    final text = tuned ? reading.radioText : null;
    final primary = theme.widgets.surface.resolve(
      SemanticSwatch.primary,
      SurfaceVariant.solid,
    );

    final status = reading.error != null
        ? 'ERROR'
        : seeking
        ? 'SEEKING…'
        : !reading.on
        ? 'PAUSED'
        : !tuned
        ? 'TUNING…'
        : 'ON AIR';
    final channels = switch (reading.stereo) {
      true => 'Stereo',
      false => 'Mono',
      null => null,
    };

    // Each region fits independently in the small switcher preview. At full
    // size, the metadata stays at the top and the dial rests near the bottom.
    Widget fitted(
      Widget child,
      Alignment alignment, {
      double? naturalHeight,
    }) => LayoutBuilder(
      builder: (context, constraints) => Align(
        alignment: alignment,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: alignment,
          child: SizedBox(
            // Let the dial retain the whole panel width when a short viewport
            // scales it vertically to fit; otherwise the strip narrows as well.
            width:
                naturalHeight != null &&
                    constraints.maxHeight > 0 &&
                    naturalHeight > constraints.maxHeight
                ? constraints.maxWidth * naturalHeight / constraints.maxHeight
                : constraints.maxWidth,
            height: naturalHeight,
            child: child,
          ),
        ),
      ),
    );

    return Padding(
      padding: EdgeInsets.all(theme.space.x3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 2,
            child: fitted(
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: Semantics(
                            label: favorite
                                ? 'Favorite station'
                                : 'Not a favorite',
                            child: Icon(
                              favorite ? LucideIcons.star : LucideIcons.starOff,
                              key: const Key('FmRadio.favorite'),
                              size: theme.sizes.iconSmall,
                              color: favorite
                                  ? primary.fill ?? primary.foreground
                                  : null,
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        flex: 3,
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: theme.space.x2,
                          ),
                          child: Column(
                            key: const Key('FmRadio.rds'),
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (station != null)
                                SubtitleText(
                                  station,
                                  textAlign: TextAlign.center,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              if (station != null && text != null)
                                SizedBox(height: theme.space.x1),
                              if (text != null)
                                BodyText.small(
                                  text,
                                  textAlign: TextAlign.center,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                            ],
                          ),
                        ),
                      ),
                      Expanded(
                        child: Column(
                          key: const Key('FmRadio.status'),
                          crossAxisAlignment: CrossAxisAlignment.end,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerRight,
                              child: CaptionText(
                                status,
                                swatch: reading.error != null
                                    ? SemanticSwatch.error
                                    : reading.on || seeking
                                    ? SemanticSwatch.primary
                                    : null,
                                textAlign: TextAlign.right,
                                maxLines: 1,
                              ),
                            ),
                            if (reading.error == null &&
                                reading.on &&
                                tuned &&
                                !seeking) ...[
                              if (channels != null)
                                CaptionText(
                                  channels,
                                  textAlign: TextAlign.right,
                                ),
                              if (reading.rssi != null)
                                CaptionText(
                                  '${reading.rssi} dBm',
                                  textAlign: TextAlign.right,
                                  maxLines: 1,
                                ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (reading.error != null) ...[
                    SizedBox(height: theme.space.x2),
                    Semantics(
                      liveRegion: true,
                      child: BodyText.small(
                        reading.error!,
                        key: const Key('FmRadio.error'),
                        swatch: SemanticSwatch.error,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ],
              ),
              Alignment.topCenter,
            ),
          ),
          SizedBox(height: theme.space.x2),
          Expanded(
            flex: 3,
            child: fitted(
              Column(
                key: const Key('FmRadio.dial'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  DisplayText(
                    frequency,
                    swatch: SemanticSwatch.primary,
                    textAlign: TextAlign.center,
                    semanticsLabel: '$frequency megahertz',
                  ),
                  const CaptionText('MHz'),
                  SizedBox(height: theme.space.x1),
                  _AnalogueBand(
                    frequencyKhz: frequencyKhz,
                    favorites: favorites,
                  ),
                ],
              ),
              Alignment.bottomCenter,
              naturalHeight:
                  _AnalogueBand._height +
                  theme.space.x1 +
                  (theme.typography.display.fontSize ?? 32) *
                      (theme.typography.display.height ?? 1) +
                  (theme.typography.caption.fontSize ?? 12) *
                      (theme.typography.caption.height ?? 1),
            ),
          ),
        ],
      ),
    );
  }
}

class _AnalogueBand extends StatelessWidget {
  const _AnalogueBand({required this.frequencyKhz, required this.favorites});

  final int frequencyKhz;
  final List<int> favorites;

  static const _height = 78.0;
  static const _tickSpacing = 22.0;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final primary = theme.widgets.surface.resolve(
      SemanticSwatch.primary,
      SurfaceVariant.solid,
    );
    final needle = primary.fill ?? primary.foreground;
    final frequency = (frequencyKhz / 1000).toStringAsFixed(1);

    return Semantics(
      label: 'Analogue tuning scale centered on $frequency megahertz',
      child: SizedBox(
        key: const Key('FmRadio.analogueBand'),
        height: _height,
        width: double.infinity,
        child: ClipRect(
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: frequencyKhz.toDouble()),
            duration: theme.motion.fast,
            curve: theme.motion.move,
            builder: (context, centerKhz, _) => Stack(
              fit: StackFit.expand,
              children: [
                CustomPaint(
                  key: const Key('FmRadio.frequencyBand'),
                  painter: _FrequencyBandPainter(
                    centerKhz: centerKhz,
                    tickSpacing: _tickSpacing,
                    favorites: List<int>.of(favorites),
                    ink: theme.palette.text,
                    rule: theme.palette.divider,
                    primary: needle,
                    labelStyle: theme.typography.caption.copyWith(
                      color: theme.palette.text.withValues(alpha: 0.68),
                      fontFeatures: const [ui.FontFeature.tabularFigures()],
                    ),
                    textDirection: Directionality.of(context),
                  ),
                ),
                Align(
                  alignment: Alignment.topCenter,
                  child: Container(
                    key: const Key('FmRadio.tunedStationLine'),
                    width: theme.strokes.focus + 1,
                    height: 57,
                    decoration: BoxDecoration(
                      color: needle,
                      borderRadius: theme.radii.full,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A horizontal receiver dial. The selected line is a widget fixed above
/// this painter; changing [centerKhz] slides the numbered scale beneath it.
class _FrequencyBandPainter extends CustomPainter {
  const _FrequencyBandPainter({
    required this.centerKhz,
    required this.tickSpacing,
    required this.favorites,
    required this.ink,
    required this.rule,
    required this.primary,
    required this.labelStyle,
    required this.textDirection,
  });

  final double centerKhz;
  final double tickSpacing;
  final List<int> favorites;
  final Color ink;
  final Color rule;
  final Color primary;
  final TextStyle labelStyle;
  final TextDirection textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    const baseline = 34.0;
    final middle = size.width / 2;
    canvas.drawLine(
      Offset(0, baseline),
      Offset(size.width, baseline),
      Paint()
        ..color = rule
        ..strokeWidth = 1,
    );

    final radius = (size.width / 2 / tickSpacing).ceil() + 1;
    final centerIndex =
        ((centerKhz - FmRadioService.minFrequencyKhz) / FmRadioService.stepKhz)
            .round();
    final first = (centerIndex - radius)
        .clamp(
          0,
          (FmRadioService.maxFrequencyKhz - FmRadioService.minFrequencyKhz) ~/
              FmRadioService.stepKhz,
        )
        .toInt();
    final last = (centerIndex + radius)
        .clamp(
          0,
          (FmRadioService.maxFrequencyKhz - FmRadioService.minFrequencyKhz) ~/
              FmRadioService.stepKhz,
        )
        .toInt();

    for (var index = first; index <= last; index++) {
      final frequency =
          FmRadioService.minFrequencyKhz + index * FmRadioService.stepKhz;
      final x =
          middle +
          (frequency - centerKhz) / FmRadioService.stepKhz * tickSpacing;
      final edge = (1 - ((x - middle).abs() / middle)).clamp(0.15, 1.0);
      final wholeMhz = frequency % 1000 == 0;
      final halfMhz = frequency % 500 == 0;
      final length = wholeMhz ? 20.0 : (halfMhz ? 14.0 : 8.0);
      canvas.drawLine(
        Offset(x, baseline),
        Offset(x, baseline + length),
        Paint()
          ..color = ink.withValues(alpha: (wholeMhz ? 0.9 : 0.48) * edge)
          ..strokeWidth = wholeMhz ? 2 : 1,
      );

      if (favorites.contains(frequency)) {
        canvas.drawCircle(
          Offset(x, baseline - 7),
          2.5,
          Paint()..color = primary.withValues(alpha: edge),
        );
      }

      if (halfMhz) {
        final label = TextPainter(
          text: TextSpan(
            text: (frequency / 1000).toStringAsFixed(1),
            style: labelStyle,
          ),
          textDirection: textDirection,
          maxLines: 1,
        )..layout();
        label.paint(canvas, Offset(x - label.width / 2, baseline + 23));
        label.dispose();
      }
    }
  }

  @override
  bool shouldRepaint(_FrequencyBandPainter oldDelegate) =>
      centerKhz != oldDelegate.centerKhz ||
      tickSpacing != oldDelegate.tickSpacing ||
      favorites != oldDelegate.favorites ||
      ink != oldDelegate.ink ||
      rule != oldDelegate.rule ||
      primary != oldDelegate.primary ||
      labelStyle != oldDelegate.labelStyle ||
      textDirection != oldDelegate.textDirection;
}
