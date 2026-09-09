import 'package:tomeui/tomeui.dart';

import 'engine.dart';

class NativeAdvanced extends StatelessWidget {
  const NativeAdvanced({
    super.key,
    required this.engine,
    required this.busy,
    required this.onBusy,
    this.showConnectionFiles = true,
    this.showDiagnostics = false,
    this.onExit,
  });
  final VoidCallback? onExit;
  final bool showConnectionFiles, showDiagnostics;
  final UsbEngine engine;
  final bool busy;
  final ValueChanged<bool> onBusy;
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
