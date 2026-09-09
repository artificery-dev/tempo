import 'dart:async';
import 'dart:math' as math;

import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

/// The wheel turning, as something to look at.
///
/// The device answers a jog by moving the selection, which is all the
/// feedback a thumb on real plastic needs - it can feel the detents. A
/// mouse cannot, so the emulator lights the wheel where the finger would
/// be and walks that light round as the wheel turns.
///
/// Every jog goes through here, from the ring's drag and from a scroll
/// over the player frame, so the light and the selection never disagree.
class WheelMotion extends ChangeNotifier {
  WheelMotion(this.wheel);

  final ClickWheelController wheel;

  /// How far round the light steps per detent.
  static const _step = math.pi / 10;

  /// How long the light lingers after the wheel stops.
  static const _linger = Duration(milliseconds: 700);

  Timer? _fade;

  double _angle = 0;

  /// Where the light sits, in radians clockwise from the top.
  double get angle => _angle;

  bool _lit = false;

  bool get lit => _lit;

  /// Turn the wheel: negative is up the list, positive is down.
  void jog(int detents) {
    if (detents == 0) return;
    wheel.jog(detents);
    _angle += _step * detents;
    _lit = true;
    _fade?.cancel();
    _fade = Timer(_linger, () {
      _lit = false;
      notifyListeners();
    });
    notifyListeners();
  }

  @override
  void dispose() {
    _fade?.cancel();
    super.dispose();
  }
}
