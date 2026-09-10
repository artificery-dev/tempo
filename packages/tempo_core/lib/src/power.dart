import 'dart:async';
import 'services/tempod.dart';

import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

import 'appearance.dart';
import 'scale.dart';

/// What the power dialog can do to the machine.
enum PowerCommand { restart, shutDown }

/// The power dialog: the one thing that must always answer. Reached by
/// holding the power key from anywhere, and from Settings > Power.
///
/// A modal over whatever was showing, and while it is up the wheel is its
/// alone - it takes every word the wheel says ([InputCapture]) and hands
/// them to the track. Restart and Power Off sit on a [WheelRail] that
/// fills the card: half a revolution of the wheel slides the box from one
/// to the other, left and right walk it without the weight, and the center
/// takes whatever is under it.
///
/// There is no close button and no way off the rail. Menu says nothing
/// here - the reflex that leaves every other screen would reboot a player
/// by accident - and the hold that opened the card is the way out of it,
/// which is the same hold either way.
class PowerDialog extends StatefulWidget {
  const PowerDialog({this.initialCommand = PowerCommand.restart, super.key});

  final PowerCommand initialCommand;

  /// How a command reaches the machine: the privileged tempod socket. A test
  /// swaps in a listener, so that pressing Power Off in a test does not
  /// power off the machine the test is on.
  static Future<void> Function(PowerCommand command) perform = _requestPower;

  static Future<void> _requestPower(PowerCommand command) async {
    await Tempod().request({
      'op': switch (command) {
        PowerCommand.restart => 'reboot',
        PowerCommand.shutDown => 'poweroff',
      },
    });
  }

  /// The dialog's route, for the menu leaf and for [show].
  ///
  /// Dressed at the classic scale whatever the rest of the UI is drawn at:
  /// a card of this shape fits the panel at that scale and no other - the
  /// large one's margins alone take half the width.
  static Route<void> route({
    PowerCommand initialCommand = PowerCommand.restart,
  }) => DialogRoute<void>(
    theme: UiScale.regular.theme(Appearance.brightness.value),
    // No scrim tap on the player, and on the emulator the X is the way.
    barrierDismissible: false,
    settings: const RouteSettings(name: 'power'),
    builder: (_) => PowerDialog(initialCommand: initialCommand),
  );

  /// Put the dialog over [navigator], unless one is already up, however it
  /// got there.
  static void show(NavigatorState? navigator) {
    if (navigator == null || _PowerDialogState._open != null) return;
    navigator.push(route());
  }

  /// Close the power dialog when another global shortcut takes over.
  static void dismiss() => _PowerDialogState._open?._closeDialog();

  /// A hold of the power key: the dialog if there is none, and the way out
  /// of it if there is - the same hold, the other way.
  static void toggle(NavigatorState? navigator) {
    final open = _PowerDialogState._open;
    if (open != null) {
      open._closeDialog();
      return;
    }
    show(navigator);
  }

  @override
  State<PowerDialog> createState() => _PowerDialogState();
}

class _PowerDialogState extends State<PowerDialog> {
  /// The one on screen, so [PowerDialog.show] can refuse a second and
  /// [PowerDialog.toggle] can close it.
  static _PowerDialogState? _open;

  /// The hand on the rail. The dialog owns the wheel while it is up - it
  /// is a modal over everything - and hands every word it hears to the
  /// track: there is nowhere else on this card for the wheel to be.
  final WheelRailController _rail = WheelRailController();

  /// The rail's weight: the same as every other rail of options. It used
  /// to be the default, which is heavier, on the reasoning that Power Off
  /// wants a guard - but a rail that turns differently from every other
  /// rail reads as a stiff one rather than a careful one, and the guard is
  /// the confirm, not the friction. The give is the card's own padding,
  /// and set at build.
  static const _physics = WheelRailPhysics(weight: panelRailWeight);

  /// The option under the rail's box.
  PowerCommand _command = PowerCommand.restart;

  @override
  void initState() {
    super.initState();
    _open = this;
    _command = widget.initialCommand;
  }

  @override
  void dispose() {
    if (identical(_open, this)) _open = null;
    super.dispose();
  }

  bool _busy = false;
  String? _error;

  void _closeDialog() {
    if (!_busy) Navigator.of(context).pop();
  }

  Future<void> _perform(PowerCommand command) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await PowerDialog.perform(command);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$error';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    // The box may leave the rail, but not the card: its give is the card's
    // own padding.
    final margin = theme.widgets.dialog
        .resolve()
        .padding
        .resolve(Directionality.of(context))
        .right;

    // Everything the wheel says goes to the rail, and nothing goes past
    // it. The dialog is the one thing that must always answer, so it takes
    // the words rather than leaving any to the screen underneath: menu
    // does not back out of it - the reflex that leaves every other screen
    // would reboot a player by accident - and the hold that opened it is
    // the way out.
    return InputCapture(
      active: true,
      debugLabel: 'PowerDialog',
      captures: const {
        WheelInput.wheel,
        WheelInput.select,
        WheelInput.menu,
        WheelInput.skip,
        WheelInput.play,
      },
      releaseOn: const {},
      onCapture: (intent) {
        if (_busy) return;
        switch (intent) {
          case JogIntent():
            _rail.jog(intent);
          case ActivateIntent():
            _perform(_command);
          // Left and right walk the rail, without the wheel's weight.
          case MediaIntent(command: MediaCommand.previous):
            _rail.step(-1);
          case MediaIntent(command: MediaCommand.next):
            _rail.step(1);
          // Menu and play say nothing here: this card is two commands and
          // the way out is the hold that opened it.
          default:
            return;
        }
      },
      child: Dialog(
        title: const Text('Power'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_busy) const Text('Requesting power action…'),
            if (_error != null)
              Text('Could not complete power action: $_error'),
            WheelRail<PowerCommand>(
              controller: _rail,
              value: _command,
              onChanged: (command) {
                if (!_busy) setState(() => _command = command);
              },
              physics: _physics.copyWith(give: margin),
              variant: SurfaceVariant.subtle,
              segments: const [
                SegmentOption(
                  value: PowerCommand.restart,
                  label: Text('Restart'),
                ),
                SegmentOption(
                  value: PowerCommand.shutDown,
                  label: Text('Power Off'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
