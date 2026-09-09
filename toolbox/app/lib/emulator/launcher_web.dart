import 'package:tomeui/tomeui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const emulatorAvailable = false;
Future<bool> startEmulatorEntrypoint(List<String> arguments) async => false;

void runToolboxApp(Widget app) => runApp(ProviderScope(child: app));

class EmbeddedEmulator extends StatelessWidget {
  const EmbeddedEmulator({super.key});
  @override
  Widget build(BuildContext context) => const Center(
    child: Text('Use the native Toolbox app to run the emulator.'),
  );
}
