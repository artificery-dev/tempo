import 'package:tomeui/tomeui.dart';

const livePlayerAvailable = false;
Future<void> openLivePlayer(BuildContext context) async {}

class LivePlayerPage extends StatelessWidget {
  const LivePlayerPage({super.key});
  @override
  Widget build(BuildContext context) => const Center(
    child: Text('Live Player is available in the desktop Toolbox app.'),
  );
}
