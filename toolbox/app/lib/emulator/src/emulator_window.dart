import 'dart:math' as math;

import 'package:tempo_core/tempo_core.dart';
import 'package:flutter/services.dart';
import 'package:tomeui/tomeui.dart';
import 'package:window_manager/window_manager.dart';

/// Y2 proportions estimated from the player's front face, with perspective
/// accounted for using the rectangular 4:3 screen. Ratios use the panel width
/// so the embedded frame and every pop-out zoom share the same silhouette.
@immutable
class DeviceGeometry {
  const DeviceGeometry(this.panel);

  /// The panel, in the host's logical pixels.
  final Size panel;

  /// The plastic between the screen's bezel and the body's edge.
  double get margin => panel.width * 0.085;

  /// The black surround the panel is set into.
  double get bezel => panel.width * 0.065;

  /// Screen to wheel.
  double get gap => panel.width * 0.165;

  /// The lower chin is deeper than the strip above the screen surround.
  double get bottomMargin => panel.width * 0.18;

  double get width => panel.width + (margin + bezel) * 2;

  double get wheel => panel.width * 0.84;

  double get height =>
      margin + bezel * 2 + panel.height + gap + wheel + bottomMargin;

  Size get size => Size(width, height);

  double get radius => width * 0.085;

  /// Room to leave around the body inside the window: the shadow it casts,
  /// and the side buttons standing proud of it.
  static const double surround = 20;
}

/// The emulator's own window: how big the player is on this desk, and how
/// big a window that comes to.
///
/// Life-size is the honest default and a 2.3" screen is very small on a
/// monitor, so the zoom is a first-class control rather than a debug one -
/// but 1x still means 1x, to the millimeter, which is the whole point of
/// asking the display how many pixels it puts in one.
class EmulatorWindow extends ChangeNotifier {
  EmulatorWindow({this.managesWindow = true});
  final bool managesWindow;

  /// Whole and half steps of life-size.
  static const zooms = <double>[1, 1.5, 2, 2.5, 3, 4];

  static const controlStripWidth = 54.0;

  static const _channel = MethodChannel('tempo_emulator/display');

  /// A logical pixel's own density: 1/96 inch, which is what every Flutter
  /// dimension in this app means by "1".
  static const _logicalPerMm = 96 / 25.4;

  /// Until the host answers: the 96dpi everything else assumes.
  double _pixelsPerMillimeter = _logicalPerMm;

  double _zoom = 2;

  double get zoom => _zoom;

  /// How much bigger than a 96dpi screen this monitor is.
  ///
  /// The desktop's own UI - the title bar, its buttons, the rig - is drawn
  /// at this scale, so a 44dp bar is 44dp of thumb rather than 44 pixels on
  /// a 163dpi panel. It has nothing to do with the device's zoom: the
  /// player's screen is a physical object being reproduced at a chosen
  /// size, and the chrome around it is a desktop UI that should look like
  /// every other desktop UI on the machine.
  ///
  /// Never below 1: where the compositor already scales (a Wayland session
  /// at scale 2 reports half the pixels per millimeter), it has done this
  /// job already and doing it twice would be absurd.
  double get uiScale => math.max(1, _pixelsPerMillimeter / _logicalPerMm);

  /// The panel at this zoom, in the window's logical pixels. Height comes
  /// from the panel's pixel aspect rather than its height in millimeters:
  /// the driver's 46x35mm implies slightly non-square pixels, and a screen
  /// that is exactly 4:3 is a screen with no letterbox in it.
  Size get panelSize => geometry.panel;

  DeviceGeometry geometryAt(double zoom) {
    // In this app's logical pixels, which [uiScale] then puts back into the
    // monitor's - so the panel comes out the millimeters it claims either
    // way.
    final width = Panel.millimeters.width * _logicalPerMm * zoom;
    return DeviceGeometry(
      Size(width, width * Panel.pixels.height / Panel.pixels.width),
    );
  }

  DeviceGeometry get geometry => geometryAt(_zoom);

  /// Fit the embedded player without changing the popout's remembered zoom.
  double zoomForSpace(Size available) {
    for (final zoom in zooms.reversed) {
      final geometry = geometryAt(zoom);
      if (geometry.width + DeviceGeometry.surround * 2 <= available.width &&
          geometry.height + DeviceGeometry.surround * 2 <= available.height) {
        return zoom;
      }
    }
    return zooms.first;
  }

  /// Device surround, outer padding, and a fixed-width control strip.
  /// The strip stays at desktop UI scale when the device zoom changes.
  Size windowSize(double titleBarHeight) => Size(
    geometry.width + DeviceGeometry.surround * 2 + 40 + 12 + controlStripWidth,
    math.max(geometry.height + DeviceGeometry.surround * 2, 448) + 40,
  );

  /// Ask the host how dense this monitor is.
  Future<void> measure() async {
    try {
      final ppm = await _channel.invokeMethod<double>('getPixelsPerMillimeter');
      if (ppm != null && ppm > 0) _pixelsPerMillimeter = ppm;
    } on PlatformException catch (error) {
      debugPrint('emulator: display: ${error.message}');
    } on MissingPluginException {
      // A host that doesn't measure: 96dpi it is.
    }
  }

  /// Put back a remembered zoom, without moving a window that isn't shown
  /// yet - [fit] does that once, afterwards.
  void restoreZoom(double zoom) {
    if (!zooms.contains(zoom) || zoom == _zoom) return;
    _zoom = zoom;
    notifyListeners();
  }

  Future<void> setZoom(double zoom, {required double titleBarHeight}) async {
    if (zoom == _zoom) return;
    _zoom = zoom;
    notifyListeners();
    await fit(titleBarHeight);
  }

  /// Step to the next zoom up or down the list.
  Future<void> step(int direction, {required double titleBarHeight}) {
    final next = (zooms.indexOf(_zoom) + direction).clamp(0, zooms.length - 1);
    return setZoom(zooms[next], titleBarHeight: titleBarHeight);
  }

  /// Cut the window to the device. The window manager counts in the
  /// monitor's logical pixels, so the size goes back through [uiScale] on
  /// the way out.
  Future<void> fit(double titleBarHeight) => managesWindow
      ? windowManager.setSize(windowSize(titleBarHeight) * uiScale)
      : Future.value();
}
