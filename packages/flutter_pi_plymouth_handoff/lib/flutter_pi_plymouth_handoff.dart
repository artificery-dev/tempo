import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Hands the display off from the plymouth boot splash to this flutter-pi app
/// with no gap between them.
///
/// Started while the splash still owns the screen, flutter-pi renders its first
/// frame but cannot show it yet (the splash holds the DRM master), so it waits
/// and the splash keeps animating. Calling [armOnFirstFrame] tells the native
/// side to fade the splash out, drop its master, take it, and commit - so the
/// splash gives way exactly at the first frame, never a frozen image during
/// startup.
///
/// Call [armOnFirstFrame] once, right after `runApp`. It is a no-op anywhere
/// the native plugin is absent (a desktop build, a plain flutter-pi), so the
/// same `main` serves every target.
class PlymouthHandoff {
  PlymouthHandoff._();

  static const MethodChannel _channel = MethodChannel(
    'flutter_pi/plymouth_handoff',
  );

  static bool _armed = false;

  /// Signal the splash to hand over as soon as the first frame has rendered.
  static void armOnFirstFrame() {
    if (_armed) return;
    _armed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await _channel.invokeMethod<void>('handoff');
      } on Object {
        // No native plugin here - nothing is holding a splash to hand off.
      }
    });
  }
}
