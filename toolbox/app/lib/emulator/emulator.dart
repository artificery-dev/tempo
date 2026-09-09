import 'dart:async';
import 'dart:math' as math;
import 'dart:io' show Platform, File;
import 'dart:developer' show Service;

import 'dart:ui';

import 'package:tempo_core/tempo_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:file_selector/file_selector.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

import 'src/device_body.dart';
import 'src/frame_settings_overlay.dart';
import 'src/event_log.dart';
import 'package:tempo_logger/tempo_logger.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'src/emulator_window.dart';
import 'src/emulator_host.dart';
import 'src/hardware.dart';
import 'src/rig.dart';
import 'src/rig_panel.dart';
import 'src/wheel_motion.dart';
import '../toolbox_ui.dart';

/// The emulator follows the host's appearance, and hands the same answer to
/// the player inside it - which is a stand-in for the setting the player
/// will own (see [Appearance]), not a claim that a music player should care
/// what a laptop is wearing.
class EmulatorApp extends StatefulWidget {
  const EmulatorApp({
    required this.window,
    this.rig,
    this.onClose,
    this.onDrag,
    this.expandedControls = false,
    this.onPopOut,
    super.key,
  });

  final VoidCallback? onClose;
  final VoidCallback? onDrag;
  final bool expandedControls;
  final VoidCallback? onPopOut;

  final EmulatorWindow window;

  /// The machine the player thinks it is running on. Null makes its own,
  /// which is what a test that just wants a shell gets.
  final Rig? rig;

  @override
  State<EmulatorApp> createState() => _EmulatorAppState();
}

class _EmulatorAppState extends State<EmulatorApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tellAppearance();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() => _tellAppearance();

  /// The emulator is the only one of the two that can see a desktop, so it
  /// is the one that reports what the desktop is wearing. What is done with
  /// that is [Appearance]'s business, and the rig's.
  void _tellAppearance() => Appearance.systemBrightness.value =
      PlatformDispatcher.instance.platformBrightness;

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      child: ValueListenableBuilder(
        valueListenable: Appearance.brightness,
        // The same light as the player, at the desktop's own size: the
        // player's scale is the player's, and stops at the panel.
        builder: (context, brightness, _) => EmulatorHost(
          theme: Theme(palette: Palette(brightness: brightness)),
          home: EmulatorShell(
            window: widget.window,
            rig: widget.rig,
            onClose: widget.onClose,
            onDrag: widget.onDrag,
            expandedControls: widget.expandedControls,
            onPopOut: widget.onPopOut,
          ),
        ),
      ),
    );
  }
}

/// The device and its independent, unscaled control strip.
class EmulatorShell extends ConsumerStatefulWidget {
  const EmulatorShell({
    required this.window,
    this.rig,
    this.onClose,
    this.onDrag,
    this.expandedControls = false,
    this.onPopOut,
    super.key,
  });

  final VoidCallback? onClose;
  final VoidCallback? onDrag;
  final bool expandedControls;
  final VoidCallback? onPopOut;

  final EmulatorWindow window;

  final Rig? rig;

  @override
  ConsumerState<EmulatorShell> createState() => _EmulatorShellState();
}

class _EmulatorShellState extends ConsumerState<EmulatorShell> {
  /// One hand on the hardware for the whole session: the drawn wheel, the
  /// ring, and the side buttons all press through this.
  final _motion = WheelMotion(ClickWheelController());

  @override
  void initState() {
    super.initState();
    // Say the hardware's name, so a script on the VM service can press a
    // button without going through the window manager.
    EmulatorHardware.attach(
      _motion,
      screenRoot: () => _captureKey.currentContext as Element?,
    );
    _rig.addListener(_recordRig);
    unawaited(_logger.info('Emulator started'));
    unawaited(_rig.initializeStorage());
    _rig.detachProfile = () async {
      await WidgetsBinding.instance.endOfFrame;
    };
  }

  /// The machine the player thinks it is running on: the one handed to us,
  /// or one of our own when nobody brought one.
  late final _rig = widget.rig ?? Rig();

  /// Keep the player subtree alive across presentation and settings changes.
  final _device = GlobalKey<NavigatorState>();
  bool _rigOpen = false;
  bool _actionsOpen = false;

  void _toggleRig() {
    setState(() => _rigOpen = !_rigOpen);
    _presentation.value++;
  }

  @override
  void dispose() {
    _rig.removeListener(_recordRig);
    _rig.detachProfile = null;
    EmulatorHardware.detach(_motion);
    _motion.dispose();
    _presentation.dispose();
    _controlsScroll.dispose();
    if (widget.rig == null) _rig.dispose();
    super.dispose();
  }

  final _captureKey = GlobalKey();
  final _presentation = ValueNotifier(0);
  final _controlsScroll = ScrollController();

  @override
  void didUpdateWidget(EmulatorShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expandedControls != widget.expandedControls) {
      _scrolledUnder = false;
      _rigOpen = false;
      _actionsOpen = false;
    }
    _presentation.value++;
  }

  late final _activity = ref.read(toolboxLogsProvider);
  late final _logger = Logger(tag: 'emulator', writer: _activity);
  String? _lastRigState;
  bool _working = false;
  bool _scrolledUnder = false;
  bool get _canSaveCapture =>
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  void _record(
    String message, {
    LogLevel level = LogLevel.info,
    String source = 'emulator',
    Map<String, Object?> fields = const {},
    StackTrace? stackTrace,
  }) {
    if (!mounted) return;
    final logger = source == 'emulator'
        ? _logger
        : Logger(tag: source, parent: _logger, writer: _activity);
    unawaited(
      logger.log(
        level,
        message,
        metadata: {
          ...fields,
          if (stackTrace != null) 'stackTrace': stackTrace.toString(),
        },
      ),
    );
  }

  void _recordRig() {
    final state =
        'Battery ${_rig.battery.value.percent}% charging=${_rig.battery.value.charging} · '
        'Wi-Fi ${_rig.wifi.value.status.name} bars=${_rig.wifi.value.bars} · '
        'Bluetooth ${_rig.bluetooth.value.status.name} · '
        'SD ${_rig.cardInserted ? 'inserted' : 'removed'}';
    if (_lastRigState == state) return;
    _lastRigState = state;
    _record(
      'Emulated device state changed',
      source: 'hardware',
      fields: {
        'battery': {
          'percent': _rig.battery.value.percent,
          'charging': _rig.battery.value.charging,
        },
        'wifi': {
          'status': _rig.wifi.value.status.name,
          'bars': _rig.wifi.value.bars,
        },
        'bluetooth': {'status': _rig.bluetooth.value.status.name},
        'sdCard': {'inserted': _rig.cardInserted},
      },
    );
  }

  Future<void> _capture() async {
    setState(() => _working = true);
    try {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final boundary =
          _captureKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) return;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ImageByteFormat.png);
      image.dispose();
      if (bytes == null || !mounted) return;
      final destination = await getSaveLocation(
        suggestedName:
            'tempo-emulator-${DateTime.now().millisecondsSinceEpoch}.png',
        acceptedTypeGroups: const [
          XTypeGroup(label: 'PNG image', extensions: ['png']),
        ],
      );
      if (destination == null) return;
      await XFile.fromData(
        bytes.buffer.asUint8List(),
        mimeType: 'image/png',
      ).saveTo(destination.path);
      _record(
        'Screenshot saved',
        source: 'capture',
        fields: {'path': destination.path},
      );
    } catch (error, stackTrace) {
      _record(
        'Screenshot failed',
        level: LogLevel.error,
        source: 'capture',
        fields: {'error': error.toString()},
        stackTrace: stackTrace,
      );
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _restart() async {
    setState(() => _working = true);
    try {
      await _rig.restart();
      _record('Player restarted; stored data kept');
    } catch (error, stackTrace) {
      _record(
        'Restart failed',
        level: LogLevel.error,
        fields: {'error': error.toString()},
        stackTrace: stackTrace,
      );
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  bool _onControlsScroll(ScrollNotification notification) {
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical) {
      return false;
    }
    final scrolled = notification.metrics.pixels > 0;
    if (scrolled != _scrolledUnder) {
      setState(() => _scrolledUnder = scrolled);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.window, _rig]),
    builder: (context, _) {
      if (!widget.expandedControls) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final geometry = widget.window.geometry;
              final deviceWidth = geometry.width + DeviceGeometry.surround * 2;
              final deviceHeight =
                  geometry.height + DeviceGeometry.surround * 2;
              final scale = math.min(
                1.0,
                math.min(
                  math.max(
                        0,
                        constraints.maxWidth -
                            12 -
                            EmulatorWindow.controlStripWidth,
                      ) /
                      deviceWidth,
                  constraints.maxHeight / deviceHeight,
                ),
              );
              final frameTop =
                  (constraints.maxHeight - deviceHeight * scale) / 2 +
                  DeviceGeometry.surround * scale;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _deviceView()),
                  const SizedBox(width: 12),
                  Padding(
                    padding: EdgeInsets.only(top: frameTop),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: constraints.maxHeight - frameTop,
                      ),
                      child: _controlStrip(context),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ToolboxAppBar(
            key: const ValueKey('emulator-page-header'),
            scrolledUnder: _scrolledUnder,
            child: ToolboxPageHeader(
              'Emulator',
              'Innioasis Y2 · simulated hardware',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 8,
                children: [
                  _headerAction(
                    label: _canSaveCapture ? 'Screenshot' : 'Screenshot [NYI]',
                    icon: LucideIcons.camera,
                    onPressed: _working || !_canSaveCapture ? null : _capture,
                  ),
                  _headerAction(
                    label: 'Restart',
                    icon: LucideIcons.rotateCcw,
                    onPressed: _working ? null : _restart,
                  ),
                  if (widget.onPopOut != null)
                    _headerAction(
                      label: 'Pop out',
                      icon: LucideIcons.externalLink,
                      onPressed: widget.onPopOut,
                    ),
                ],
              ),
            ),
          ),
          Expanded(child: _embeddedContent()),
        ],
      );
    },
  );

  Widget _embeddedContent() => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth >= 720) {
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerSignal: (event) {
            if (event is! PointerScrollEvent ||
                event.scrollDelta.dy == 0 ||
                !_controlsScroll.hasClients) {
              return;
            }
            // Descendant controls and the player frame claim their own signals first.
            GestureBinding.instance.pointerSignalResolver.register(event, (_) {
              _controlsScroll.position.pointerScroll(event.scrollDelta.dy);
            });
          },
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // DeviceBody already reserves its shadow and side-button surround.
              Expanded(child: _deviceView()),
              SizedBox(
                width: 320,
                child: NotificationListener<ScrollNotification>(
                  key: const ValueKey('emulator-controls-sidebar'),
                  onNotification: _onControlsScroll,
                  child: SingleChildScrollView(
                    key: const ValueKey('emulator-expanded-controls'),
                    controller: _controlsScroll,
                    padding: const EdgeInsets.all(12),
                    child: _expandedControls(),
                  ),
                ),
              ),
            ],
          ),
        );
      }
      return NotificationListener<ScrollNotification>(
        onNotification: _onControlsScroll,
        child: SingleChildScrollView(
          key: const ValueKey('emulator-expanded-controls'),
          controller: _controlsScroll,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 20,
            children: [
              SizedBox(
                height: constraints.maxHeight.clamp(360, 680),
                child: _deviceView(),
              ),
              _expandedControls(),
            ],
          ),
        ),
      );
    },
  );

  Widget _deviceView() => Navigator(
    key: _device,
    onGenerateRoute: (settings) => PageRouteBuilder<void>(
      // No transition and no background of its own: this
      // navigator exists to give the rig somewhere to be
      // modal, not to move between screens.
      transitionDuration: Duration.zero,
      pageBuilder: (context, _, _) => ListenableBuilder(
        listenable: Listenable.merge([_rig, widget.window, _presentation]),
        builder: (context, _) => !_rig.storageInitialized
            ? const Center(child: Text('Opening storage…'))
            : LayoutBuilder(
                builder: (context, constraints) {
                  final zoom = widget.expandedControls
                      ? widget.window.zoomForSpace(constraints.biggest)
                      : widget.window.zoom;
                  final geometry = widget.window.geometryAt(zoom);
                  final width = geometry.width + DeviceGeometry.surround * 2;
                  final height = geometry.height + DeviceGeometry.surround * 2;
                  final scale = math.min(
                    1.0,
                    math.min(
                      constraints.maxWidth / width,
                      constraints.maxHeight / height,
                    ),
                  );
                  final showControls = _rigOpen && !widget.expandedControls;
                  return Stack(
                    children: [
                      Positioned.fill(
                        child: ExcludeFocus(
                          excluding: showControls,
                          child: IgnorePointer(
                            ignoring: showControls,
                            child: Center(
                              child: RepaintBoundary(
                                key: _captureKey,
                                child: DeviceBody(
                                  key: ValueKey(_rig.profileGeneration),
                                  window: widget.window,
                                  zoom: widget.expandedControls ? zoom : null,
                                  motion: _motion,
                                  services: _rig.services,
                                  profileSuspended: _rig.profileSuspended,
                                  onDrag: widget.onDrag,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left:
                            (constraints.maxWidth - width * scale) / 2 +
                            DeviceGeometry.surround * scale,
                        top:
                            (constraints.maxHeight - height * scale) / 2 +
                            DeviceGeometry.surround * scale,
                        width: geometry.width * scale,
                        height: geometry.height * scale,
                        child: ClipRRect(
                          key: const ValueKey('emulator-frame-settings'),
                          borderRadius: BorderRadius.circular(
                            geometry.radius * scale,
                          ),
                          child: FrameSettingsOverlay(
                            visible: showControls,
                            child: FocusScope(
                              autofocus: true,
                              onKeyEvent: (node, event) {
                                if (event is KeyDownEvent &&
                                    event.logicalKey ==
                                        LogicalKeyboardKey.escape) {
                                  _toggleRig();
                                  return KeyEventResult.handled;
                                }
                                return KeyEventResult.ignored;
                              },
                              child: SingleChildScrollView(
                                padding: const EdgeInsets.all(24),
                                child: _expandedControls(),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
      ),
    ),
  );

  Widget _headerAction({
    required String label,
    required IconData icon,
    required VoidCallback? onPressed,
  }) => Tooltip(
    message: Text(label),
    child: Semantics(
      label: label,
      child: SizedBox.square(
        dimension: 36,
        child: Button.custom(
          key: ValueKey('emulator-action-$label'),
          onPressed: onPressed,
          style: ThemeProvider.of(context).widgets.button
              .resolve(SemanticSwatch.primary, SurfaceVariant.ghost)
              .copyWith(padding: EdgeInsets.zero, height: 36),
          child: Icon(icon, size: 16),
        ),
      ),
    ),
  );

  Widget _expandedControls() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 12,
    children: [
      Semantics(header: true, child: const TitleText('Emulated Device State')),
      const CaptionText(
        'Use the click wheel or keyboard to operate the player. Scroll over the player frame to turn the wheel; scroll elsewhere to browse controls.',
      ),
      RigPanel(rig: _rig, showUiScale: false, collapsible: true),
    ],
  );

  Widget _controlStrip(BuildContext context) {
    final dark = Appearance.brightness.value == Brightness.dark;
    return Container(
      key: const ValueKey('emulator-control-strip'),
      width: EmulatorWindow.controlStripWidth,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: dark ? const Color(0xff242528) : const Color(0xfff6f6f7),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: dark ? const Color(0xff45464a) : const Color(0xffd1d2d6),
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x30000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: [
            if (widget.onDrag != null)
              Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (_) => widget.onDrag!(),
                child: const SizedBox(
                  width: 36,
                  height: 16,
                  child: Icon(LucideIcons.gripHorizontal, size: 16),
                ),
              ),
            _BarButton(
              tooltip: _canSaveCapture ? 'Screenshot' : 'Screenshot [NYI]',
              icon: LucideIcons.camera,
              onPressed: _working || !_canSaveCapture ? null : _capture,
            ),
            const _BarDivider(),
            _BarButton(
              tooltip: 'Charging',
              icon: LucideIcons.batteryCharging,
              active: _rig.battery.value.charging,
              onPressed: () => _rig.setCharging(!_rig.battery.value.charging),
            ),
            _BarButton(
              tooltip: 'Wi-Fi',
              icon: LucideIcons.wifi,
              active: _rig.wifi.value.status != WifiStatus.off,
              onPressed: () => _rig.setWifi(
                _rig.wifi.value.status == WifiStatus.off
                    ? WifiStatus.connected
                    : WifiStatus.off,
              ),
            ),
            _BarButton(
              tooltip: 'Bluetooth',
              icon: LucideIcons.bluetooth,
              active: _rig.bluetooth.value.status != BluetoothStatus.off,
              onPressed: () => _rig.setBluetooth(
                _rig.bluetooth.value.status == BluetoothStatus.off
                    ? BluetoothStatus.connected
                    : BluetoothStatus.off,
              ),
            ),
            _BarButton(
              tooltip: 'SD card inserted',
              icon: LucideIcons.hardDrive,
              active: _rig.cardInserted,
              onPressed: () => _rig.cardInserted = !_rig.cardInserted,
            ),
            const _BarDivider(),
            _BarButton(
              tooltip: 'Larger',
              icon: LucideIcons.plus,
              onPressed: widget.window.zoom == EmulatorWindow.zooms.last
                  ? null
                  : () => widget.window.step(1, titleBarHeight: 0),
            ),
            Text(_zoomLabel(widget.window.zoom)),
            _BarButton(
              tooltip: 'Smaller',
              icon: LucideIcons.minus,
              onPressed: widget.window.zoom == EmulatorWindow.zooms.first
                  ? null
                  : () => widget.window.step(-1, titleBarHeight: 0),
            ),
            const _BarDivider(),
            _BarButton(
              tooltip: 'Machine state',
              icon: LucideIcons.slidersHorizontal,
              active: _rigOpen,
              onPressed: _toggleRig,
            ),
            Menu(
              open: _actionsOpen,
              side: PopoverSide.left,
              onDismiss: () => setState(() => _actionsOpen = false),
              anchor: _BarButton(
                tooltip: 'Emulator actions',
                icon: LucideIcons.ellipsis,
                onPressed: () => setState(() => _actionsOpen = !_actionsOpen),
              ),
              entries: [
                if (widget.onClose != null)
                  MenuItem(
                    label: const Text('Dock emulator'),
                    leading: const Icon(LucideIcons.panelLeft, size: 16),
                    onPressed: widget.onClose,
                  ),
                MenuItem(
                  label: const Text('Restart emulator'),
                  leading: const Icon(LucideIcons.rotateCcw, size: 16),
                  onPressed: _working ? null : _restart,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _zoomLabel(double zoom) =>
    zoom == zoom.roundToDouble() ? '${zoom.round()}x' : '${zoom}x';

/// A compact control-strip action with tooltip and persistent active state.
class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.active,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  /// Lit while the thing it opens is open, so the button reads as the
  /// switch it is.
  final bool? active;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    const iconSize = 20.0;

    // Icon actions reserve a square hit target without text-button padding.
    final style = theme.widgets.button
        .resolve(
          active == true ? SemanticSwatch.primary : SemanticSwatch.neutral,
          switch (active) {
            true => SurfaceVariant.solid,
            false => SurfaceVariant.subtle,
            null => SurfaceVariant.soft,
          },
        )
        .copyWith(height: 36, padding: EdgeInsets.zero);

    return Tooltip(
      message: Text(tooltip),
      child: SizedBox.square(
        dimension: 36,
        child: Button.custom(
          onPressed: onPressed,
          style: style,
          child: Icon(icon, size: iconSize),
        ),
      ),
    );
  }
}

/// The line between two runs of bar buttons.
class _BarDivider extends StatelessWidget {
  const _BarDivider();

  @override
  Widget build(BuildContext context) => const Divider(
    axis: Axis.horizontal,
    indent: SpaceStep.x2,
    endIndent: SpaceStep.x2,
  );
}

Future<void> publishEmulatorVmService() async {
  final service = await Service.getInfo();
  if (service.serverUri case final uri?) {
    final target = File(
      Platform.environment['TEMPO_EMULATOR_VM_FILE'] ??
          '${Platform.environment['HOME'] ?? Platform.environment['LOCALAPPDATA'] ?? '.'}/.cache/tempo/emulator-vm.url',
    );
    await target.parent.create(recursive: true);
    await target.writeAsString('$uri');
  }
}
