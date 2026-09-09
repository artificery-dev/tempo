import 'dart:convert';
import 'dart:developer';

import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

import 'wheel_motion.dart';

/// The running emulator's hardware, reachable by name.
///
/// The emulator is a machine you press: a wheel, five buttons, a rocker,
/// a power key. Everything that presses them from *inside* the process -
/// the drawn wheel, the ring, the side buttons - goes through one
/// [WheelMotion], which lives in a State and has no name anyone outside
/// can say.
///
/// That left one way to press a button from outside: send a key event to
/// the window and hope the compositor put the focus where you meant. It
/// races the window manager, it needs the window fronted, and a press
/// that lands on the wrong window is a press that silently does nothing.
///
/// So the hardware says its own name. A script attached to the Dart VM
/// service can reach [wheel] and press exactly the button it means, with
/// no window in the way and no question about where the focus was:
///
/// ```dart
/// // Over the VM service, in this library's scope:
/// EmulatorHardware.press(WheelButton.select);
/// EmulatorHardware.jog(3);
/// EmulatorHardware.hold(WheelButton.menu);
/// ```
///
/// Null before the shell is built and after it is gone, which is the only
/// honest answer for a machine that is not running.
abstract final class EmulatorHardware {
  static WheelMotion? _motion;
  static Element? _root;
  static Element? Function()? _screenRoot;

  /// Told by the shell, for as long as the shell is up.
  static bool _registered = false;
  static void attach(
    WheelMotion motion, {
    Element? root,
    Element? Function()? screenRoot,
  }) {
    _motion = motion;
    _root = root;
    _screenRoot = screenRoot;
    if (_registered) return;
    _registered = true;
    registerExtension('ext.tempo.emulator', (method, parameters) async {
      final argument = parameters['argument'] ?? '';
      final value = switch (parameters['action']) {
        'status' => running.toString(),
        'knows' => knows(argument).toString(),
        'pressNamed' => pressNamed(argument).toString(),
        'down' => down(argument).toString(),
        'up' => up(argument).toString(),
        'jog' => jog(int.parse(argument).clamp(-1000, 1000)).toString(),
        'screen' => screenText(),
        _ => 'unsupported action',
      };
      return ServiceExtensionResponse.result(jsonEncode({'value': value}));
    });
  }

  static String screenText() {
    final found = <String>{};
    void walk(Element element) {
      final widget = element.widget;
      if (widget is Offstage && widget.offstage) return;
      if (widget is Visibility && !widget.visible) return;
      if (widget is Text && widget.data != null) {
        if (widget.data!.trim().isNotEmpty) found.add(widget.data!.trim());
      } else if (widget is RichText) {
        final text = widget.text.toPlainText().trim();
        if (text.isNotEmpty) found.add(text);
      }
      element.visitChildren(walk);
    }

    // Inspect the player, excluding the surrounding Toolbox controls.
    if ((_screenRoot?.call() ?? _root) case final root?) walk(root);
    return found.join(' | ');
  }

  static void detach(WheelMotion motion) {
    if (identical(_motion, motion)) {
      _motion = null;
      _root = null;
      _screenRoot = null;
    }
  }

  /// The wheel and its buttons, or null while nothing is running.
  static ClickWheelController? get wheel => _motion?.wheel;

  /// Whether there is a machine to press at all.
  static bool get running => _motion != null;

  /// Turn the wheel: negative is up a list, positive is down.
  ///
  /// Through the [WheelMotion] rather than the controller, so the light
  /// under the finger walks round with it exactly as it does when a hand
  /// turns the drawn wheel - what is scripted and what is done by hand
  /// are the same press.
  static bool jog(int detents) {
    final motion = _motion;
    if (motion == null) return false;
    motion.jog(detents);
    return true;
  }

  /// A jog at the fast tier, the way a quick spin reads.
  static bool page(int detents) {
    final wheel = EmulatorHardware.wheel;
    if (wheel == null) return false;
    wheel.jog(detents, page: true);
    return true;
  }

  /// Press and release a button: its short word.
  static bool press(WheelButton button) {
    final wheel = EmulatorHardware.wheel;
    if (wheel == null) return false;
    wheel.press(button);
    return true;
  }

  /// Hold a ring button past its threshold: its long word, said at once.
  ///
  /// Not for menu or power. Those two are keys the machine times from
  /// their own edges - a menu hold is the dock, a power hold is the power
  /// dialog - and a word said at once is not a key that was held. Use
  /// [down] and [up] with a real wait between them for those.
  static bool hold(WheelButton button) {
    final wheel = EmulatorHardware.wheel;
    if (wheel == null) return false;
    wheel.hold(button);
    return true;
  }

  /// A button going down, and coming back up, with the wait between them
  /// left to the caller.
  ///
  /// This is the honest hold: the short word comes on a release in time,
  /// the long one at the threshold, and a volume key repeats while it is
  /// down - all counted by the machine from these two edges, exactly as
  /// they are counted from the real key.
  static bool down(String name) => _edge(name, down: true);

  static bool up(String name) => _edge(name, down: false);

  static bool _edge(String name, {required bool down}) {
    final wheel = EmulatorHardware.wheel;
    if (wheel == null) return false;
    switch (name.toLowerCase()) {
      case 'menu':
        down ? wheel.menuDown() : wheel.menuUp();
      case 'power':
        down ? wheel.powerDown() : wheel.powerUp();
      default:
        final button = buttonNamed(name);
        if (button == null) return false;
        down ? wheel.buttonDown(button) : wheel.buttonUp(button);
    }
    return true;
  }

  /// A button by the name a script would type: `select`, `menu`, `next`,
  /// `previous`, `playPause`, `volumeUp`, `volumeDown`, `power`. Null for
  /// a name this build has not heard of, so a typo is an answer rather
  /// than the wrong button.
  static WheelButton? buttonNamed(String name) {
    for (final button in WheelButton.values) {
      if (button.name.toLowerCase() == name.toLowerCase()) return button;
    }
    return null;
  }

  /// Press whatever [name] means, said at once. False for a name nobody
  /// knows, or a machine that is not running.
  ///
  /// Menu and power are keys rather than ring buttons, so their short
  /// word is a key going down and straight back up.
  static bool pressNamed(String name) {
    final lowered = name.toLowerCase();
    if (lowered == 'menu' || lowered == 'power') {
      return down(name) && up(name);
    }
    final button = buttonNamed(name);
    if (button == null) return false;
    return press(button);
  }

  /// Whether [name] is a button this machine has at all.
  static bool knows(String name) {
    final lowered = name.toLowerCase();
    return lowered == 'menu' || lowered == 'power' || buttonNamed(name) != null;
  }
}
