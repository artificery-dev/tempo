import 'package:tomeui/tomeui.dart';

import 'skin.dart';

/// A part of the device that answers to a pointer.
///
/// Hardware, not a control: it wears no focus ring and joins no focus
/// order, because the thing being drawn is a piece of plastic. What it does
/// have is the pointer's two states - under it, and pushed by it - which is
/// what tells you the drawn button is a button at all.
class Pressable extends StatefulWidget {
  const Pressable({
    required this.builder,
    this.onPressed,
    this.onDown,
    this.onUp,
    super.key,
  });

  /// Draws the part in the state it is in. [wash] is the overlay to lay
  /// over its fill.
  final Widget Function(BuildContext context, Color wash) builder;

  /// A press and release, once. For a key whose grammar is taps.
  final VoidCallback? onPressed;

  /// Going down and coming back up, for a key whose grammar is holds.
  final VoidCallback? onDown;
  final VoidCallback? onUp;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _hovered = false;
  bool _pressed = false;

  void _set({bool? hovered, bool? pressed}) {
    if (hovered == _hovered && pressed == _pressed) return;
    setState(() {
      _hovered = hovered ?? _hovered;
      _pressed = pressed ?? _pressed;
    });
  }

  @override
  Widget build(BuildContext context) {
    final skin = DeviceSkin.of(context);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => _set(hovered: true),
      onExit: (_) => _set(hovered: false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        onTapDown: (_) {
          _set(pressed: true);
          widget.onDown?.call();
        },
        onTapUp: (_) {
          _set(pressed: false);
          widget.onUp?.call();
        },
        onTapCancel: () {
          _set(pressed: false);
          widget.onUp?.call();
        },
        child: widget.builder(
          context,
          skin.washAt(hovered: _hovered, pressed: _pressed),
        ),
      ),
    );
  }
}
