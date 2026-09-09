import 'package:flutter_test/flutter_test.dart';
import 'package:tempo/main.dart' as app;
import 'package:tempo_core/tempo_core.dart';

/// The device binary is only the way in; what it must do is put the shared
/// UI on a panel and arm the boot handoff without anything a test host
/// lacks getting in the way. Off the device the handoff comes back missing,
/// and the app must come up regardless.
void main() {
  testWidgets('the app comes up on the home screen', (tester) async {
    app.main();
    await tester.pump();
    // main() has the wallpaper install its default into the player's home
    // - and off the player, under the harness, that home is this machine's,
    // so main() must not have.
    expect(WallpaperSource.installDefault, isFalse);
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(PanelSurface), findsOneWidget);
    expect(find.byType(TempoApp), findsOneWidget);
    expect(find.byType(HomeScreen), findsOneWidget);
  });
}
