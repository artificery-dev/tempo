import 'package:tomeui/tomeui.dart';

/// A themed application surface that leaves the native window transparent.
/// The emulated player retains its own opaque TomeApp inside the device panel.
class EmulatorHost extends StatelessWidget {
  const EmulatorHost({
    required this.home,
    this.theme = const Theme(),
    super.key,
  });

  final Widget home;
  final Theme theme;

  @override
  Widget build(BuildContext context) => ThemeProvider(
    theme: theme,
    child: WidgetsApp(
      title: 'Tempo Emulator',
      color: const Color(0x00000000),
      debugShowCheckedModeBanner: false,
      textStyle: theme.typography.body.copyWith(color: theme.palette.text),
      home: home,
      pageRouteBuilder: <T>(settings, builder) => TomePageRoute<T>(
        settings: settings,
        builder: builder,
        motion: theme.motion,
      ),
      builder: (context, child) => IconTheme(
        data: IconThemeData(color: theme.palette.text, size: theme.sizes.icon),
        child: child ?? const SizedBox.shrink(),
      ),
    ),
  );
}
