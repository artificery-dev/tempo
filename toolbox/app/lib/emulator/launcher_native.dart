// The Toolbox pins Flutter's native multiwindow API until it is public.
// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:async';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'package:flutter/src/widgets/_window.dart' as native;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tomeui/tomeui.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';

import 'emulator.dart';
import 'src/emulator_window.dart';
import 'src/emulator_host.dart';
import 'src/native_window.dart';
import 'src/paths.dart';
import 'src/rig.dart';
import 'src/settings.dart';
import '../toolbox_ui.dart';

const emulatorAvailable = true;
bool get _desktop => Platform.isLinux || Platform.isMacOS || Platform.isWindows;
final emulatorWindowsProvider = ChangeNotifierProvider<DesktopEmulatorWindows>(
  (ref) => DesktopEmulatorWindows(),
);

/// One secondary native window, sharing the Toolbox engine and Dart isolate.
/// Window controls belong to the native frame, so emulator content never uses
/// window_manager's process-wide primary-window handle.
class DesktopEmulatorWindows extends ChangeNotifier {
  DesktopEmulatorWindows({native.WindowController Function()? createWindow})
    : _createWindow = createWindow ?? _newWindow;
  final native.WindowController Function() _createWindow;
  final sessionKey = GlobalKey<_MobileEmulatorState>();
  native.WindowController? get window => _window;
  native.WindowController? _window;

  static native.WindowController _newWindow() => native.WindowController(
    size: EmulatorWindow(managesWindow: false).windowSize(0),
    title: 'Tempo Emulator',
    constraints: const BoxConstraints(minWidth: 320, minHeight: 440),
  );

  void open() {
    if (_window case final existing?) {
      if (!existing.isDestroyed) {
        existing.activate();
        return;
      }
      _closed();
    }
    final window = _createWindow();
    _window = window;
    window.addListener(_closed);
    notifyListeners();
    window.activate();
  }

  void dock() => _window?.destroy();

  void _closed() {
    final window = _window;
    if (window == null || !window.isDestroyed) return;
    window.removeListener(_closed);
    _window = null;
    notifyListeners();
  }

  @override
  void dispose() {
    final window = _window;
    _window = null;
    window?.removeListener(_closed);
    window?.destroy();
    super.dispose();
  }
}

void runToolboxApp(Widget app) {
  if (!_desktop) {
    runApp(ProviderScope(child: app));
    return;
  }
  final binding = WidgetsFlutterBinding.ensureInitialized();
  final primaryView = binding.platformDispatcher.implicitView;
  if (primaryView == null) {
    throw StateError(
      'The Toolbox desktop runner did not create its main view.',
    );
  }
  runWidget(
    ProviderScope(
      child: Consumer(
        builder: (context, ref, _) {
          final windows = ref.watch(emulatorWindowsProvider);
          return ViewCollection(
            views: [
              View(view: primaryView, child: app),
              if (windows.window case final window?)
                native.Window(
                  key: ObjectKey(window),
                  controller: window,
                  child: EmulatorHost(
                    home: MobileEmulator(
                      key: windows.sessionKey,
                      standalone: true,
                      onSizeChanged: window.setSize,
                      onClose: window.destroy,
                      nativeWindow: true,
                      isWindowAlive: () => !window.isDestroyed,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    ),
  );
}

Future<bool> startEmulatorEntrypoint(List<String> arguments) async {
  if (!(arguments.contains('--emulator') ||
      Platform.environment['TEMPO_TOOLBOX_EMULATOR'] == '1' ||
      const bool.fromEnvironment('TEMPO_TOOLBOX_EMULATOR'))) {
    return false;
  }
  // The same flag the device's launcher would set, so the setup can be
  // driven here: `--first-run`, or the variable flutter-pi's launcher uses.
  Rig.launchFirstRun =
      arguments.contains('--first-run') ||
      Platform.environment['TEMPO_FIRST_RUN'] == '1';
  // The editor's direct emulator target uses the same reusable content as
  // the secondary desktop window and the mobile navigation route.
  runApp(
    EmulatorHost(
      home: MobileEmulator(standalone: true, nativeWindow: _desktop),
    ),
  );
  return true;
}

/// The embedded and detached presentations reparent this same keyed subtree.
/// The player navigator, services, playback and hardware state stay alive.
class EmbeddedEmulator extends ConsumerWidget {
  const EmbeddedEmulator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final desktopEmulatorWindows = ref.watch(emulatorWindowsProvider);
    final poppedOut = desktopEmulatorWindows.window != null;
    if (!poppedOut) {
      return MobileEmulator(
        key: desktopEmulatorWindows.sessionKey,
        standalone: true,
        expandedControls: true,
        onPopOut: _desktop ? desktopEmulatorWindows.open : null,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ToolboxAppBar(
          child: ToolboxPageHeader(
            'Emulator',
            'Innioasis Y2 · simulated hardware',
            trailing: _desktop
                ? Tooltip(
                    message: const Text('Dock emulator'),
                    child: Semantics(
                      label: 'Dock emulator',
                      child: SizedBox.square(
                        dimension: 36,
                        child: Button.custom(
                          onPressed: desktopEmulatorWindows.dock,
                          style: ThemeProvider.of(context).widgets.button
                              .resolve(
                                SemanticSwatch.primary,
                                SurfaceVariant.ghost,
                              )
                              .copyWith(padding: EdgeInsets.zero, height: 36),
                          child: const Icon(LucideIcons.panelLeft, size: 16),
                        ),
                      ),
                    ),
                  )
                : null,
          ),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Card(
                  variant: SurfaceVariant.subtle,
                  leading: const Icon(LucideIcons.externalLink, size: 32),
                  header: const TitleText('Emulator is popped out'),
                  content: const BodyText(
                    'The same player is running in its own window. Close that window or dock it here to return.',
                  ),
                  footer: Align(
                    alignment: Alignment.centerLeft,
                    child: Button(
                      onPressed: desktopEmulatorWindows.open,
                      variant: SurfaceVariant.subtle,
                      center: const Text('Show window'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class MobileEmulator extends StatefulWidget {
  const MobileEmulator({
    this.standalone = false,
    this.onSizeChanged,
    this.onClose,
    this.nativeWindow = false,
    this.isWindowAlive,
    this.expandedControls = false,
    this.onPopOut,
    super.key,
  });
  final ValueChanged<Size>? onSizeChanged;
  final bool standalone;
  final bool nativeWindow;
  final bool expandedControls;
  final bool Function()? isWindowAlive;
  final VoidCallback? onClose;
  final VoidCallback? onPopOut;
  @override
  State<MobileEmulator> createState() => _MobileEmulatorState();
}

class _MobileEmulatorState extends State<MobileEmulator> {
  final window = EmulatorWindow(managesWindow: false);
  Rig? rig;
  int? _configuredViewId;
  bool get _alive => mounted && (widget.isWindowAlive?.call() ?? true);
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _configureWindow();
  }

  @override
  void didUpdateWidget(MobileEmulator oldWidget) {
    super.didUpdateWidget(oldWidget);
    _configureWindow();
  }

  void _configureWindow() {
    final viewId = View.of(context).viewId;
    if (!widget.nativeWindow) {
      _configuredViewId = null;
      return;
    }
    if (_configuredViewId == viewId) return;
    _configuredViewId = viewId;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!_alive || _configuredViewId != viewId) return;
      try {
        await NativeEmulatorWindow.configure(viewId);
      } on PlatformException {
        if (_alive && _configuredViewId == viewId) rethrow;
      }
      if (_alive && _configuredViewId == viewId) _resize();
    });
  }

  EmulatorSettings? settings;
  late final Future<void> ready = _initialize();
  Future<void> _initialize() async {
    if (!_alive) return;
    VideoPlayerMediaKit.ensureInitialized(linux: true, windows: true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(publishEmulatorVmService());
    });
    Paths.applicationDirectory = await getApplicationSupportDirectory();
    if (!_alive) return;
    Paths.ensureCard();
    rig = Rig();
    settings = EmulatorSettings(window: window, rig: rig!);
    await settings!.load();
    if (!_alive) return;
    window.addListener(_resize);
    _resize();
    await rig!.initializeStorage();
    if (_alive) settings!.watch();
  }

  Size get _contentSize => window.windowSize(0);
  void _resize() {
    if (!_alive) return;
    if (widget.onSizeChanged case final resize?) {
      resize(_contentSize);
    } else if (widget.nativeWindow && mounted) {
      unawaited(
        NativeEmulatorWindow.setSize(View.of(context).viewId, _contentSize),
      );
    }
  }

  @override
  void dispose() {
    window.removeListener(_resize);
    unawaited(
      ready.whenComplete(() {
        settings?.dispose();
        rig?.dispose();
        window.dispose();
      }),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Column(
      children: [
        if (!widget.standalone)
          Button(
            onPressed: () => Navigator.of(context).pop(),
            center: const Text('Back to Toolbox'),
          ),
        Expanded(
          child: FutureBuilder<void>(
            future: ready,
            builder: (context, snapshot) {
              if (!_alive) return const SizedBox.shrink();
              if (snapshot.hasError) {
                return Center(child: Text('${snapshot.error}'));
              }
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: Text('Opening emulator…'));
              }
              return ListenableBuilder(
                listenable: window,
                builder: (context, _) => EmulatorApp(
                  window: window,
                  rig: rig,
                  expandedControls: widget.expandedControls,
                  onPopOut: widget.onPopOut,
                  onClose:
                      widget.onClose ??
                      (widget.nativeWindow
                          ? () => unawaited(
                              NativeEmulatorWindow.close(
                                View.of(context).viewId,
                              ),
                            )
                          : null),
                  onDrag: widget.nativeWindow
                      ? () => unawaited(
                          NativeEmulatorWindow.startDrag(
                            View.of(context).viewId,
                          ),
                        )
                      : null,
                ),
              );
            },
          ),
        ),
      ],
    ),
  );
}
