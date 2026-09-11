import 'package:flutter/gestures.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

import 'click_wheel_pad.dart';
import 'emulator_window.dart';
import 'pressable.dart';
import 'skin.dart';
import 'wheel_motion.dart';

/// The player, drawn: a body with the panel set into it, the wheel below,
/// and the buttons that live on its edges.
///
/// The screen is the real thing - [TempoApp] on a [PanelSurface] - so
/// what is inside the bezel is the player's own UI at the player's own
/// scale, and only the plastic around it is a picture.
class DeviceBody extends StatelessWidget {
  const DeviceBody({
    required this.window,
    required this.motion,
    required this.services,
    this.profileSuspended = false,
    this.firstRun = false,
    this.onFirstRunDone,
    this.onDrag,
    this.zoom,
    super.key,
  });

  final EmulatorWindow window;
  final double? zoom;

  /// The wheel, and the light that shows it turning.
  final WheelMotion motion;

  /// Explicit emulator sources prevent accidental native device fallback.
  final PlayerServices services;
  final bool profileSuspended;

  /// The player opens on its setup instead of its home, as on a device
  /// whose first run is not done; [onFirstRunDone] is the setup finishing.
  final bool firstRun;
  final VoidCallback? onFirstRunDone;
  final VoidCallback? onDrag;

  ClickWheelController get wheel => motion.wheel;

  @override
  Widget build(BuildContext context) {
    final skin = DeviceSkin.of(context);
    final geometry = window.geometryAt(zoom ?? window.zoom);

    // The first frame and zoom changes can precede the native window's
    // resize. Lay out the whole device at its intended size, then fit it
    // into the space available without squeezing the panel or wheel.
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: SizedBox(
        width: geometry.width + DeviceGeometry.surround * 2,
        height: geometry.height + DeviceGeometry.surround * 2,
        child: Stack(
          // The side buttons stand proud of the body.
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: DeviceGeometry.surround,
              top: DeviceGeometry.surround,
              width: geometry.width,
              height: geometry.height,
              child: Listener(
                key: const ValueKey('emulator-player-frame'),
                behavior: HitTestBehavior.opaque,
                onPointerSignal: (event) {
                  if (event is! PointerScrollEvent ||
                      event.scrollDelta.dy == 0) {
                    return;
                  }
                  GestureBinding.instance.pointerSignalResolver.register(
                    event,
                    (_) {
                      motion.jog(event.scrollDelta.dy.isNegative ? -1 : 1);
                    },
                  );
                },
                onPointerDown: onDrag == null
                    ? null
                    : (event) {
                        final wheelTop =
                            geometry.margin +
                            geometry.bezel * 2 +
                            geometry.panel.height +
                            geometry.gap;
                        final center = Offset(
                          geometry.width / 2,
                          wheelTop + geometry.wheel / 2,
                        );
                        if (event.buttons == 1 &&
                            (event.localPosition - center).distance >
                                geometry.wheel / 2) {
                          onDrag!();
                        }
                      },
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: skin.body,
                    borderRadius: BorderRadius.circular(geometry.radius),
                    border: Border.all(color: skin.edge),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0x40000000),
                        blurRadius: 24,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      SizedBox(height: geometry.margin),
                      // The bezel: black plastic, and the panel inside it.
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: skin.bezel,
                          borderRadius: BorderRadius.circular(geometry.bezel),
                        ),
                        child: Padding(
                          padding: EdgeInsets.all(geometry.bezel),
                          child: SizedBox.fromSize(
                            size: geometry.panel,
                            // The glass is the edge of the picture: what the
                            // player draws past its panel - the covers in the
                            // dock's flow - stops here, as it does on the real
                            // one. Nothing reaches the screen through a
                            // pointer, either: the Y2 has no touch panel, and
                            // a scroll over the glass is the wheel's, not a
                            // list's.
                            child: ClipRect(
                              child: IgnorePointer(
                                child: Stack(
                                  fit: StackFit.passthrough,
                                  children: [
                                    PanelSurface(
                                      size: geometry.panel,
                                      child: profileSuspended
                                          ? const Center(
                                              child: Text('Changing storage…'),
                                            )
                                          : services
                                                    .dataStorage
                                                    ?.value
                                                    .available ==
                                                false
                                          ? DataStorageRecoveryApp(
                                              controller: services.dataStorage!,
                                              wheel: wheel,
                                            )
                                          : firstRun
                                          ? FirstRunApp(
                                              key: ObjectKey(services),
                                              wheel: wheel,
                                              services: services,
                                              onFinished: onFirstRunDone,
                                            )
                                          : TempoApp(
                                              key: ObjectKey(services),
                                              wheel: wheel,
                                              services: services,
                                            ),
                                    ),
                                    // The backlight, off: the glass goes the
                                    // color of the bezel around it, as the
                                    // real one does. The player's own shade has
                                    // already faded the frame; this is the
                                    // light going out behind it.
                                    Positioned.fill(
                                      child: ValueListenableBuilder(
                                        valueListenable: services.screen,
                                        builder: (context, on, _) =>
                                            AnimatedOpacity(
                                              opacity: on ? 0 : 1,
                                              duration: ScreenService.fade,
                                              child: ColoredBox(
                                                color: skin.bezel,
                                              ),
                                            ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      SizedBox(height: geometry.gap),
                      ClickWheelPad(diameter: geometry.wheel, motion: motion),
                      SizedBox(height: geometry.bottomMargin),
                    ],
                  ),
                ),
              ),
            ),
            _SideRail(geometry: geometry, wheel: wheel),
          ],
        ),
      ),
    );
  }
}

/// Which edge of the body the buttons live on, as on the device: the right.
const _edge = _Edge.right;

enum _Edge { left, right }

/// The buttons on the device's edge, in the hardware's own proportions.
///
/// Each of the three is a quarter of the screen tall, and so is the space
/// between the volume pair and the power key - so the run is exactly as
/// long as the screen is, and it starts a quarter of the screen down from
/// the screen's own top:
///
/// ```
///   +
///   -      volume, one control in two halves
///
///          the gap
///
///   power  its own control
/// ```
class _SideRail extends StatelessWidget {
  const _SideRail({required this.geometry, required this.wheel});

  final DeviceGeometry geometry;
  final ClickWheelController wheel;

  @override
  Widget build(BuildContext context) {
    final unit = geometry.panel.height / 4;
    // Wider than the hardware's own keys, and deliberately: what is
    // printed on a real one is a molded bump you find with a thumb, and
    // what is printed on this one has to be read at a glance from a foot
    // away. The panel is 46mm across, which is what makes that a ratio
    // rather than a guess.
    final width = geometry.panel.width * (3.6 / Panel.millimeters.width);

    final rail = Column(
      children: [
        _SideControl(
          unit: unit,
          width: width,
          keys: [
            // Held rather than pressed: a volume key repeats while down.
            _SideKey(
              icon: LucideIcons.plus,
              onDown: () => wheel.buttonDown(WheelButton.volumeUp),
              onUp: () => wheel.buttonUp(WheelButton.volumeUp),
            ),
            _SideKey(
              icon: LucideIcons.minus,
              onDown: () => wheel.buttonDown(WheelButton.volumeDown),
              onUp: () => wheel.buttonUp(WheelButton.volumeDown),
            ),
          ],
        ),
        SizedBox(height: unit),
        _SideControl(
          unit: unit,
          width: width,
          keys: [
            _SideKey(
              icon: LucideIcons.power,
              // Held rather than pressed: the app counts taps and holds off
              // this button exactly as it does off the real key, so a hold
              // has to be held here too.
              onDown: wheel.powerDown,
              onUp: wheel.powerUp,
            ),
          ],
        ),
      ],
    );

    return Positioned(
      // Only part of the key stands proud of the body; the rest of it is
      // the plastic the glyph is printed on.
      left: _edge == _Edge.left ? DeviceGeometry.surround - width * 0.36 : null,
      right: _edge == _Edge.right
          ? DeviceGeometry.surround - width * 0.36
          : null,
      // The volume rocker begins just below the top of the lit panel.
      top:
          DeviceGeometry.surround + geometry.margin + geometry.bezel + unit / 2,
      child: rail,
    );
  }
}

/// One control on the edge: a single key, or several stacked into one
/// segmented run with a line between them.
class _SideControl extends StatelessWidget {
  const _SideControl({
    required this.keys,
    required this.unit,
    required this.width,
  });

  final List<_SideKey> keys;

  /// One key's height.
  final double unit;

  final double width;

  @override
  Widget build(BuildContext context) {
    final skin = DeviceSkin.of(context);
    final border = skin.edge;
    final round = Radius.circular(width / 2);

    return Container(
      width: width,
      height: unit * keys.length,
      decoration: BoxDecoration(
        color: skin.key,
        border: Border.all(color: border),
        // Rounded where it stands out of the body, square where it meets it.
        borderRadius: BorderRadius.horizontal(
          left: _edge == _Edge.left ? round : Radius.zero,
          right: _edge == _Edge.right ? round : Radius.zero,
        ),
      ),
      child: Column(
        children: [
          for (final (index, key) in keys.indexed)
            // Expanded rather than a fixed height: the control's *outer*
            // size is what the hardware measures, and its border is a part
            // of that rather than two pixels on top of it.
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  // The segment line, drawn inside the height each key is
                  // owed rather than added to it.
                  border: index == 0
                      ? null
                      : Border(top: BorderSide(color: border)),
                ),
                child: Pressable(
                  onDown: key.onDown,
                  onUp: key.onUp,
                  builder: (context, wash) => ColoredBox(
                    color: wash,
                    child: Center(
                      child: Icon(
                        key.icon,
                        size: width * 0.66,
                        color: skin.glyph,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// What one key on the edge does.
@immutable
class _SideKey {
  const _SideKey({required this.icon, this.onDown, this.onUp});

  final IconData icon;
  final VoidCallback? onDown;
  final VoidCallback? onUp;
}
