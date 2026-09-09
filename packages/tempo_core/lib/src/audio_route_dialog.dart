import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

import 'services/output.dart';

/// A routing decision captures the wheel so the underlying page cannot act.
class AudioRouteDialog extends StatefulWidget {
  const AudioRouteDialog({required this.output, super.key});
  final AudioOutput output;
  @override
  State<AudioRouteDialog> createState() => _AudioRouteDialogState();
}

class _AudioRouteDialogState extends State<AudioRouteDialog> {
  final _rail = WheelRailController();
  bool _switch = true;

  @override
  Widget build(BuildContext context) => InputCapture(
    active: true,
    debugLabel: 'AudioRouteDialog',
    captures: const {
      WheelInput.wheel,
      WheelInput.select,
      WheelInput.menu,
      WheelInput.skip,
    },
    releaseOn: const {},
    onCapture: (intent) {
      switch (intent) {
        case JogIntent():
          _rail.jog(intent);
        case ActivateIntent():
          Navigator.of(context).pop(_switch);
        case WheelBackIntent() || WheelMenuIntent():
          Navigator.of(context).pop(false);
        case MediaIntent(command: MediaCommand.previous):
          _rail.step(-1);
        case MediaIntent(command: MediaCommand.next):
          _rail.step(1);
      }
    },
    child: Dialog(
      title: Text('Switch to ${widget.output.label}?'),
      content: WheelRail<bool>(
        controller: _rail,
        value: _switch,
        onChanged: (value) => setState(() => _switch = value),
        segments: const [
          SegmentOption(value: true, label: Text('Switch')),
          SegmentOption(value: false, label: Text('Keep Current')),
        ],
      ),
    ),
  );
}
