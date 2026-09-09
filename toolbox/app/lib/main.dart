import 'emulator/src/event_log.dart';
import 'emulator/src/event_log_panel.dart';
import 'dart:async';
import 'package:desktop_drop/desktop_drop.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'toolbox_controller.dart';
import 'firmware_drop.dart';
import 'workflow_layout.dart';

import 'package:tomeui/tomeui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'native_advanced.dart';
import 'live_device.dart';
import 'emulator/launcher.dart';
import 'toolbox_ui.dart';

Future<void> main(List<String> arguments) async {
  if (await startEmulatorEntrypoint(arguments)) return;
  runToolboxApp(const InstallerApp());
}

final toolboxRouterProvider = Provider<GoRouter>((ref) {
  final router = GoRouter(
    initialLocation: '/player',
    routes: [
      GoRoute(path: '/', redirect: (_, _) => '/player'),
      GoRoute(path: '/live-player', builder: (_, _) => const LivePlayerPage()),
      GoRoute(
        path: '/:section',
        redirect: (context, state) {
          final name = state.pathParameters['section'];
          if (name == 'flash') return '/backup';
          if (!ToolboxSection.values.any((section) => section.name == name) ||
              (!emulatorAvailable && name == 'emulator')) {
            return '/player';
          }
          return null;
        },
        pageBuilder: (context, state) => NoTransitionPage(
          key: const ValueKey('toolbox-workspace'),
          child: ConnectionPage(
            section: ToolboxSection.values.byName(
              state.pathParameters['section']!,
            ),
          ),
        ),
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});

class InstallerApp extends ConsumerWidget {
  const InstallerApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => TomeApp.router(
    title: 'Tempo Toolbox',
    debugShowCheckedModeBanner: false,
    theme: const Theme(),
    routerConfig: ref.watch(toolboxRouterProvider),
  );
}

class ConnectionPage extends ConsumerStatefulWidget {
  const ConnectionPage({this.section = ToolboxSection.player, super.key});
  final ToolboxSection section;
  @override
  ConsumerState<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends ConsumerState<ConnectionPage> {
  final _scroll = ScrollController();
  bool _emulatorMounted = false;
  ToolboxSection get _section => widget.section;
  ToolboxController get model => ref.read(toolboxControllerProvider);
  ToolboxSection get _operationSection => switch (model.task) {
    'Backup' || 'Restore' || 'Flash' || 'Diagnostics' => ToolboxSection.backup,
    _ => ToolboxSection.player,
  };

  @override
  void initState() {
    super.initState();
    _syncRoute();
  }

  @override
  void didUpdateWidget(ConnectionPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.section != widget.section) {
      _syncRoute();
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
  }

  int _workflowStep = 0;
  String _workflowMode = 'Backup';
  bool _otherOpen = false;
  bool _diagnostics = false;
  String? _startedWorkflow;

  void _stepTo(bool flash, int step) {
    setState(() {
      _workflowStep = step;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _syncRoute() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || model.busy) return;
      final task = _diagnostics ? 'Diagnostics' : _workflowMode;
      if (_section == ToolboxSection.backup && model.task != task) {
        model.selectTask(task);
      }
    });
  }

  void _selectSection(ToolboxSection section) {
    if (model.busy &&
        section != _operationSection &&
        section != ToolboxSection.emulator &&
        section != ToolboxSection.settings) {
      return;
    }
    context.go('/${section.name}');
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _help() {
    showDialog<void>(
      context,
      builder: (context) => Dialog(
        title: const TitleText('Connecting your Y2'),
        content: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.5,
          child: ListView(
            children: [
              _HelpStep(
                number: '1',
                title: model.engine.isWeb
                    ? 'Open the Picker'
                    : 'Start listening',
                text: model.engine.isWeb
                    ? 'Close this guide, then choose Connect Y2 or Connect via serial. Keep the browser’s device picker open before connecting or resetting the player.'
                    : 'Close this guide and choose Connect Y2. The desktop installer will listen for the player.',
                screenshot: model.engine.isWeb
                    ? 'Browser device picker, waiting for a device'
                    : 'Desktop installer waiting for the Y2',
              ),
              const _HelpStep(
                number: '2',
                title: 'Connect or reset your Y2',
                text:
                    'Turn the Y2 fully off, unplug its USB cable, then plug it back in. Or press the reset button using a pin while the USB device is connected.',
                screenshot: 'Y2 USB connection and pin reset button',
              ),
              _HelpStep(
                number: '3',
                title: model.engine.isWeb
                    ? 'Select the entry quickly'
                    : 'Wait for the connection',
                text: model.engine.isWeb
                    ? 'As soon as the player connects or resets, you only have a few seconds to select MT65xx Preloader (or its MediaTek serial port) and click Connect in the picker.'
                    : 'The installer will try to capture the connection automatically after the player connects or resets.',
                screenshot: model.engine.isWeb
                    ? 'MediaTek entry selected and Connect button highlighted'
                    : 'Y2 connected to the desktop installer',
              ),
              const BodyText(
                'Missed it? Open the picker again first, then reconnect or reset the player. If the browser’s timing is difficult, use the desktop installer.',
              ),
            ],
          ),
        ),
        actions: [
          Button(
            onPressed: () => Navigator.of(context).pop(),
            center: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  Future<void> _start({bool serial = false}) async {
    if ((model.task == 'Flash' || model.task == 'Restore')) {
      final confirmed = await showDialog<bool>(
        context,
        builder: (context) => Dialog(
          title: TitleText(
            '${model.task == 'Restore' ? 'Restore' : 'Flash'} ${model.firmware}?',
          ),
          icon: LucideIcons.hardDriveDownload,
          content: BodyText(
            'This will overwrite the mapped eMMC ranges on your Y2 ${model.verifyWrites ? 'and verify them by reading them back' : 'without readback verification'}. ${model.allowPreloaderFlash ? 'Preloader flashing is enabled.' : 'The preloader will stay protected.'}',
          ),
          actions: [
            Button(
              onPressed: () => Navigator.of(context).pop(false),
              variant: SurfaceVariant.ghost,
              swatch: SemanticSwatch.neutral,
              center: const Text('Cancel'),
            ),
            Button(
              onPressed: () => Navigator.of(context).pop(true),
              swatch: SemanticSwatch.error,
              center: Text(model.task == 'Restore' ? 'Restore Y2' : 'Flash Y2'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() => _startedWorkflow = model.task);
    await model.start(serial: serial);
  }

  Future<void> _setPreloaderFlashing(bool enabled) async {
    if (!enabled) {
      model.setPreloaderFlashing(false);
      return;
    }
    final acknowledged = await showDialog<bool>(
      context,
      builder: (context) => Dialog(
        title: const TitleText('Allow preloader flashing?'),
        icon: LucideIcons.triangleAlert,
        swatch: SemanticSwatch.error,
        content: const BodyText(
          'Replacing the preloader with an invalid image, or interrupting its write, can make the Y2 permanently irrecoverable. By selecting Enable, you acknowledge and accept this risk.',
        ),
        actions: [
          Button(
            onPressed: () => Navigator.of(context).pop(false),
            variant: SurfaceVariant.ghost,
            swatch: SemanticSwatch.neutral,
            center: const Text('Cancel'),
          ),
          Button(
            onPressed: () => Navigator.of(context).pop(true),
            swatch: SemanticSwatch.error,
            center: const Text('Enable'),
          ),
        ],
      ),
    );
    if (mounted && acknowledged == true) {
      model.setPreloaderFlashing(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(toolboxControllerProvider);
    if (model.engine.isWeb && model.initialized && !model.supported) {
      return EmulatorLogDock(
        log: ref.watch(toolboxLogsProvider),
        child: const _UnsupportedBrowserPage(),
      );
    }
    _emulatorMounted = _emulatorMounted || _section == ToolboxSection.emulator;
    return ToolboxShell(
      section: _section,
      onSelect: _selectSection,
      emulatorAvailable: emulatorAvailable,
      disabledSections: {
        if (model.busy)
          for (final section in [ToolboxSection.player, ToolboxSection.backup])
            if (section != _operationSection) section,
      },
      status: model.busy
          ? 'USB operation in progress'
          : 'No active USB operation',
      child: EmulatorLogDock(
        log: ref.watch(toolboxLogsProvider),
        child: Stack(
          children: [
            if (_emulatorMounted)
              Positioned.fill(
                child: ExcludeFocus(
                  excluding: _section != ToolboxSection.emulator,
                  child: Offstage(
                    offstage: _section != ToolboxSection.emulator,
                    child: const EmbeddedEmulator(),
                  ),
                ),
              ),
            if (_section != ToolboxSection.emulator)
              LayoutBuilder(
                builder: (context, constraints) {
                  final padding = constraints.maxWidth < 600 ? 16.0 : 28.0;
                  final margin = constraints.maxWidth > 1180
                      ? (constraints.maxWidth - 1180) / 2
                      : 0.0;
                  final workflowResult =
                      {ToolboxSection.backup}.contains(_section) &&
                      _startedWorkflow == model.task &&
                      !model.busy &&
                      {
                        'result',
                        'error',
                        'stopped',
                        'flash-complete',
                      }.contains(model.phase);
                  final centeredWorkflow =
                      !_diagnostics &&
                      (workflowResult ||
                          (_section == ToolboxSection.backup &&
                              {'Flash', 'Restore'}.contains(_workflowMode) &&
                              _workflowStep == 1));
                  final page = switch (_section) {
                    ToolboxSection.player => _playerPage(),
                    ToolboxSection.backup =>
                      _diagnostics
                          ? [
                              const ToolboxPageHeader(
                                'Read-only diagnostics',
                                'Inspect the partition map or export a partition without changing the player.',
                              ),
                              const SizedBox.shrink(),
                              NativeAdvanced(
                                engine: model.engine,
                                busy: model.busy,
                                showConnectionFiles: false,
                                showDiagnostics: true,
                                onExit: () => setState(() {
                                  _diagnostics = false;
                                  model.selectTask(_workflowMode);
                                }),
                                onBusy: (value) =>
                                    model.updateUi(() => model.busy = value),
                              ),
                            ]
                          : _walkthrough(_workflowMode == 'Flash'),
                    ToolboxSection.settings => <Widget>[
                      const ToolboxPageHeader(
                        'Device settings [NYI]',
                        'Manage your player’s settings from Toolbox.',
                      ),
                      const DeviceSettingsPlaceholder(),
                    ],
                    ToolboxSection.emulator => <Widget>[],
                  };
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ListenableBuilder(
                        listenable: _scroll,
                        builder: (context, _) => ToolboxAppBar(
                          scrolledUnder:
                              _scroll.hasClients && _scroll.offset > 0,
                          child: page.first,
                        ),
                      ),
                      Expanded(
                        child: _section == ToolboxSection.backup
                            ? LayoutBuilder(
                                builder: (context, viewport) =>
                                    SingleChildScrollView(
                                      key: const ValueKey(
                                        'toolbox-page-scroll',
                                      ),
                                      controller: _scroll,
                                      child: Padding(
                                        padding: EdgeInsets.symmetric(
                                          horizontal: padding + margin,
                                          vertical: padding,
                                        ),
                                        child: WorkflowLayout(
                                          minimumHeight:
                                              (viewport.maxHeight - padding * 2)
                                                  .clamp(0, double.infinity),
                                          centerBody: centeredWorkflow,
                                          header: page[1],
                                          body: centeredWorkflow
                                              ? Center(
                                                  child: ConstrainedBox(
                                                    constraints:
                                                        const BoxConstraints(
                                                          maxWidth: 480,
                                                        ),
                                                    child: page[2],
                                                  ),
                                                )
                                              : page[2],
                                          footer: page.length > 3
                                              ? page[3]
                                              : null,
                                        ),
                                      ),
                                    ),
                              )
                            : ListView(
                                key: const ValueKey('toolbox-page-scroll'),
                                controller: _scroll,
                                padding: EdgeInsets.symmetric(
                                  horizontal: padding + margin,
                                  vertical: padding,
                                ),
                                children: page.skip(1).toList(),
                              ),
                      ),
                    ],
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _playerPage() => [
    ToolboxPageHeader(
      'Your player',
      'A home for your Y2, its firmware, and its tools.',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [
          ToolboxHeaderAction(
            label: 'Check USB connection',
            icon: LucideIcons.usb,
            onPressed: model.busy || !model.supported
                ? null
                : () {
                    model.selectTask(null);
                    unawaited(_start());
                  },
          ),
          if (livePlayerAvailable)
            ToolboxHeaderAction(
              label: 'Live Player',
              icon: LucideIcons.activity,
              onPressed: model.busy ? null : () => context.push('/live-player'),
            ),
          ToolboxHeaderAction(
            label: 'Connection help',
            icon: LucideIcons.circleHelp,
            onPressed: _help,
          ),
        ],
      ),
    ),
    const SizedBox(height: 24),
    Card(
      variant: SurfaceVariant.subtle,
      content: LayoutBuilder(
        builder: (context, constraints) {
          final details = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 20,
            children: [
              const TitleText('Innioasis Y2'),
              ToolboxMetrics([
                ('Serial [NYI]', 'Y2-8F31-04AC'),
                ('Firmware [NYI]', 'Tempo · development'),
                ('eMMC [NYI]', '7.3 GB'),
                ('Battery [NYI]', '82%'),
              ]),
              const Row(
                children: [
                  Expanded(child: CaptionText('Storage used [NYI]')),
                  BodyText('2.4 / 7.3 GB'),
                ],
              ),
              const Progress.bar(value: 2.4 / 7.3),
            ],
          );
          if (constraints.maxWidth < 560) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 20,
              children: [const PlayerThumbnail(), details],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const PlayerThumbnail(),
              const SizedBox(width: 28),
              Expanded(child: details),
            ],
          );
        },
      ),
      footer: const CaptionText(
        '[NYI] marks example data until device reporting is connected.',
      ),
    ),
    const SizedBox(height: 16),
    ToolboxColumns(
      children: [
        Card(
          variant: SurfaceVariant.subtle,
          header: const TitleText('Hardware'),
          content: ToolboxInfoRows([
            (
              model.report == null ? 'Chip [NYI]' : 'Chip',
              model.report == null
                  ? 'MediaTek MT6582'
                  : '0x${(model.report!['hardware_code'] as num).toInt().toRadixString(16)}',
            ),
            ('Memory [NYI]', '512 MB'),
            ('Display [NYI]', '480 × 360'),
            ('Radios [NYI]', 'Wi-Fi · Bluetooth · FM'),
          ]),
        ),
        const Card(
          variant: SurfaceVariant.subtle,
          header: TitleText('Partition map [NYI]'),
          content: ToolboxInfoRows([
            ('BOOT1', '4 MiB'),
            ('BOOT2', '4 MiB'),
            ('BOOTIMG', '16 MiB'),
            ('ROOTFS', '1.5 GiB'),
            ('User storage', '5.7 GiB'),
          ]),
        ),
      ],
    ),
    const SizedBox(height: 16),
    const Card(
      variant: SurfaceVariant.subtle,
      header: TitleText('Health'),
      content: ToolboxMetrics([
        ('Charge cycles [NYI]', '214'),
        ('eMMC life [NYI]', '90–100%'),
        ('Uptime [NYI]', '18 h 04 m'),
        ('Temperature [NYI]', '31 °C'),
      ]),
    ),
    const SizedBox(height: 24),
    _recentActivity(),
    if (model.task == null &&
        (model.busy || model.report != null || model.phase == 'error')) ...[
      const SizedBox(height: 24),
      _operationCard(),
    ],
  ];

  bool _firmwareDragOver = false;

  bool _restoreDragOver = false;
  Widget _restoreChooser() {
    final selected = model.task == 'Restore' && model.firmwareReady;
    return DropTarget(
      enable: !model.busy && !model.engine.isWeb,
      onDragEntered: (_) => setState(() => _restoreDragOver = true),
      onDragExited: (_) => setState(() => _restoreDragOver = false),
      onDragDone: (details) {
        setState(() => _restoreDragOver = false);
        final paths = firmwareDropPaths(
          details.files.map((file) => file.path),
          rawText: details.rawText,
        );
        if (paths.length != 1) {
          model.event({
            'event': 'error',
            'stage': 'restore-drop',
            'message': 'Drop one local Toolbox backup file.',
          });
          return;
        }
        _startedWorkflow = null;
        model.prepareRestore(path: paths.single);
      },
      child: Card(
        key: const ValueKey('restore-chooser'),
        variant: _restoreDragOver ? SurfaceVariant.soft : SurfaceVariant.subtle,
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 16,
          children: [
            const SizedBox(height: 16),
            const Icon(LucideIcons.archiveRestore, size: 64),
            TitleText(
              selected ? 'Selected backup' : 'Choose a backup to restore',
              textAlign: TextAlign.center,
            ),
            if (selected)
              Text(model.firmware ?? '', textAlign: TextAlign.center)
            else
              const Text(
                'Drop a Toolbox .img.gz backup here, or browse to choose one.',
                textAlign: TextAlign.center,
              ),
            const CaptionText(
              'The backup will be decompressed and validated before USB opens.',
              textAlign: TextAlign.center,
            ),
            if (model.busy) const Progress.bar(),
            if (model.phase == 'error')
              BodyText(
                model.status,
                swatch: SemanticSwatch.error,
                textAlign: TextAlign.center,
              ),
            Center(
              child: Button(
                onPressed: model.busy || model.engine.isWeb
                    ? null
                    : () {
                        _startedWorkflow = null;
                        model.prepareRestore();
                      },
                variant: selected
                    ? SurfaceVariant.ghost
                    : SurfaceVariant.subtle,
                leading: const Icon(LucideIcons.folderOpen),
                center: Text(
                  selected ? 'Choose a different backup' : 'Choose backup',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _firmwareChooser() {
    final info = model.firmwareInfo;
    final preview = info != null;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: DropTarget(
          enable: !model.busy && !model.engine.isWeb,
          onDragEntered: (_) => setState(() => _firmwareDragOver = true),
          onDragExited: (_) => setState(() => _firmwareDragOver = false),
          onDragDone: (details) {
            setState(() => _firmwareDragOver = false);
            final paths = firmwareDropPaths(
              details.files.map((file) => file.path),
              rawText: details.rawText,
            );
            if (paths.length != 1) {
              model.event({
                'event': 'error',
                'message': paths.isEmpty
                    ? 'The desktop did not provide a usable local file path. Try Choose package.'
                    : 'Drop one firmware package or ROM folder (${paths.length} distinct paths received).',
                'stage': 'firmware-drop',
                'entry_count': details.files.length,
                'paths': details.files.map((file) => file.path).toList(),
                'raw_payload': details.rawText,
              });
              return;
            }
            _startedWorkflow = null;
            model.prepareFirmware(path: paths.single);
          },
          child: Card(
            key: const ValueKey('firmware-chooser'),
            variant: _firmwareDragOver
                ? SurfaceVariant.soft
                : SurfaceVariant.subtle,
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 16,
              children: [
                if (preview) ...[
                  _FirmwareIdentity(
                    metadata: info['firmware'] as Map? ?? const {},
                  ),
                  Text(
                    info['filename']?.toString() ?? '',
                    textAlign: TextAlign.center,
                  ),
                  if (info['legacy'] == true)
                    const Text(
                      'Legacy SPFT ROM · Preloader excluded',
                      textAlign: TextAlign.center,
                    ),
                  if (info['preview_warning'] case final String warning)
                    Text(
                      'Logo preview unavailable: $warning',
                      textAlign: TextAlign.center,
                    ),
                ] else ...[
                  const SizedBox(height: 16),
                  const Icon(LucideIcons.package, size: 64),
                  const Center(child: TitleText('Choose your firmware')),
                  const Text(
                    'Drop a firmware package here, or browse to choose one.',
                    textAlign: TextAlign.center,
                  ),
                  Text(
                    model.engine.isWeb
                        ? '.y2-firmware'
                        : '.y2-firmware, SPFT ZIP, or a scatter file with its ROM images',
                    textAlign: TextAlign.center,
                  ),
                ],
                if (model.busy) ...[
                  _PackageValidationLabel(
                    completed: model.backupCompleted,
                    total: model.backupTotal,
                  ),
                  Progress.bar(
                    value: model.backupTotal != null && model.backupTotal! > 0
                        ? (model.backupCompleted ?? 0) / model.backupTotal!
                        : null,
                  ),
                ],
                if (!model.busy && model.phase == 'error')
                  BodyText(model.status, swatch: SemanticSwatch.error),
                Center(
                  child: Button(
                    onPressed: model.busy
                        ? null
                        : () {
                            _startedWorkflow = null;
                            model.prepareFirmware();
                          },
                    variant: preview
                        ? SurfaceVariant.ghost
                        : SurfaceVariant.subtle,
                    leading: const Icon(LucideIcons.folderOpen),
                    center: Text(
                      preview ? 'Choose a different package' : 'Choose package',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _walkthrough(bool flash) {
    final task = flash ? 'Flash' : _workflowMode;
    const choosing = 1;
    final options = choosing + 1;
    final review = options + 1;
    final transfer = review + 1;
    final savedStep = _workflowStep;
    final ready =
        model.task == task &&
        (task == 'Backup' ? model.backupReady : model.firmwareReady);
    final finished =
        model.task == task &&
        _startedWorkflow == task &&
        !model.busy &&
        {'result', 'error', 'stopped', 'flash-complete'}.contains(model.phase);
    // A different workflow may have replaced the engine's prepared file.
    final step = savedStep > choosing && !ready && !model.busy && !finished
        ? choosing
        : savedStep;
    final steps = [
      task == 'Flash'
          ? 'Flash a firmware'
          : task == 'Backup'
          ? 'Create a backup'
          : 'Restore a backup',
      task == 'Backup' ? 'Destination' : 'Source',
      'Options',
      'Review',
      finished ? 'Result' : 'Connect & transfer',
    ];
    return [
      ToolboxPageHeader(
        flash
            ? 'Flash a firmware'
            : task == 'Backup'
            ? 'Create a backup'
            : 'Restore a backup',
        flash
            ? 'Install a verified .y2-firmware package on your Y2.'
            : task == 'Backup'
            ? 'Create a complete backup of your Y2.'
            : 'Restore a saved backup to your Y2.',
      ),
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          WorkflowStepper(
            labels: steps,
            step: step,
            icons: [
              task == 'Flash'
                  ? LucideIcons.cpu
                  : task == 'Backup'
                  ? LucideIcons.archive
                  : LucideIcons.archiveRestore,
              LucideIcons.folderOpen,
              LucideIcons.slidersHorizontal,
              LucideIcons.clipboardCheck,
              finished ? LucideIcons.circleCheck : LucideIcons.cable,
            ],
          ),
          if (step > 0 && !finished)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Button(
                  key: const ValueKey('workflow-back'),
                  onPressed: model.busy ? null : () => _stepTo(flash, step - 1),
                  variant: SurfaceVariant.ghost,
                  leading: const Icon(LucideIcons.arrowLeft),
                  center: const Text('Back'),
                ),
              ),
            ),
        ],
      ),
      if (step == 0)
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 16,
          children: [
            const TitleText('What would you like to do?'),
            LayoutBuilder(
              builder: (context, constraints) {
                final choices = [
                  _operationChoice(
                    'Backup',
                    LucideIcons.archive,
                    'Create a backup',
                    'Save both boot areas and the complete user area as a compressed backup.',
                  ),
                  _operationChoice(
                    'Restore',
                    LucideIcons.archiveRestore,
                    'Restore a backup',
                    'Validate a saved Toolbox backup, then restore its mapped data to the player.',
                  ),
                  _operationChoice(
                    'Flash',
                    LucideIcons.cpu,
                    'Flash a firmware',
                    'Install a Tempo firmware package or a legacy SPFT ROM on your player.',
                  ),
                ];
                final sideBySide = constraints.maxWidth >= 600;
                final width = sideBySide
                    ? ((constraints.maxWidth -
                                  (constraints.maxWidth >= 900 ? 32 : 16)) /
                              (constraints.maxWidth >= 900 ? 3 : 2))
                          .clamp(0.0, 300.0)
                    : constraints.maxWidth.clamp(0.0, 300.0);
                return Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 16,
                  runSpacing: 16,
                  children: [
                    for (final choice in choices)
                      SizedBox(width: width, child: choice),
                  ],
                );
              },
            ),
            if (!model.engine.isWeb) ...[
              Align(
                alignment: Alignment.center,
                child: Button(
                  onPressed: model.busy
                      ? null
                      : () => setState(() => _otherOpen = !_otherOpen),
                  variant: SurfaceVariant.ghost,
                  center: const Text('Other'),
                  trailing: Icon(
                    _otherOpen
                        ? LucideIcons.chevronUp
                        : LucideIcons.chevronDown,
                  ),
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 180),
                alignment: Alignment.topCenter,
                child: _otherOpen
                    ? Align(
                        alignment: Alignment.center,
                        child: Button(
                          onPressed: model.busy
                              ? null
                              : () => setState(() {
                                  model.selectTask('Diagnostics');
                                  _diagnostics = true;
                                }),
                          variant: SurfaceVariant.subtle,
                          leading: const Icon(LucideIcons.listTree),
                          center: const Text('Read-only diagnostics'),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ],
        )
      else if (step == choosing && flash)
        _firmwareChooser()
      else if (step == choosing && task == 'Restore')
        _restoreChooser()
      else if (step == choosing)
        Card(
          variant: SurfaceVariant.subtle,
          header: TitleText(
            task == 'Backup'
                ? 'Choose a backup destination'
                : task == 'Restore'
                ? 'Choose a backup to restore'
                : 'Choose your firmware',
          ),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 16,
            children: [
              BodyText(
                task == 'Backup'
                    ? 'The backup includes BOOT1, BOOT2, and the full user area. Your player is only read during backup.'
                    : task == 'Restore'
                    ? 'Select a Toolbox .img.gz backup. Its contents will be decompressed and validated before USB opens.'
                    : 'Select a .y2-firmware package. Its images and hashes are validated before you continue.',
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: Button(
                  onPressed:
                      model.busy || (task == 'Restore' && model.engine.isWeb)
                      ? null
                      : () async {
                          _startedWorkflow = null;
                          model.selectTask(task);
                          if (task == 'Backup') {
                            await model.prepareBackup();
                          } else if (task == 'Restore') {
                            await model.prepareRestore();
                          } else {
                            await model.prepareFirmware();
                          }
                        },
                  leading: const Icon(LucideIcons.folderOpen),
                  center: Text(
                    task == 'Backup'
                        ? 'Choose backup destination'
                        : task == 'Restore'
                        ? 'Choose backup'
                        : 'Choose package',
                  ),
                ),
              ),
              if (model.firmwareInfo != null && task == 'Flash')
                _FirmwareIdentity(
                  metadata:
                      (model.firmwareInfo?['firmware'] as Map?) ?? const {},
                ),
              if (ready && task != 'Flash')
                BodyText(
                  task == 'Backup'
                      ? model.backupName ?? 'Browser download'
                      : model.firmware ?? 'Selected file',
                ),
              if (model.busy) ...[
                if (model.backupCompleted != null && model.backupTotal != null)
                  _OperationProgress(
                    completed: model.backupCompleted!,
                    total: model.backupTotal!,
                    label: model.status,
                  )
                else ...[
                  const Progress.bar(),
                  BodyText(model.status),
                ],
              ],
              if (!model.busy && model.phase == 'error' && model.task == task)
                BodyText(model.status, swatch: SemanticSwatch.error),
              if (task == 'Restore' && model.engine.isWeb)
                const CaptionText(
                  'Restore is available in the native Toolbox app.',
                ),
            ],
          ),
        )
      else if (step == options)
        Card(
          variant: SurfaceVariant.subtle,
          header: const TitleText('Options'),
          content: _workflowOptions(),
        )
      else if (step == review)
        Card(
          variant: SurfaceVariant.subtle,
          header: TitleText('Review ${task.toLowerCase()}'),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 16,
            children: [
              ToolboxInfoRows([
                ('Operation', task),
                (
                  'Transfer method',
                  model.useLegacyDownloadAgent
                      ? 'Legacy Download Agent'
                      : 'Tempo Recovery',
                ),
                (
                  task == 'Backup' ? 'Destination' : 'File',
                  task == 'Backup'
                      ? model.backupName ?? 'Browser download'
                      : model.firmware ?? '—',
                ),
                if (task == 'Backup') ...[
                  ('Format', 'gzip (.img.gz)'),
                  ('Included', 'BOOT1, BOOT2, full user area'),
                ] else ...[
                  (
                    'Validation',
                    task == 'Restore' ? 'Before USB connection' : 'Passed',
                  ),
                  (
                    'Verify after write',
                    model.verifyWrites ? 'Enabled' : 'Disabled',
                  ),
                  if (!model.engine.isWeb)
                    (
                      'Skip matching data',
                      model.resumeWrites ? 'Enabled' : 'Disabled',
                    ),
                  (
                    'Preloader protection',
                    model.allowPreloaderFlash ? 'Disabled' : 'Enabled',
                  ),
                ],
                (
                  'Reboot after success',
                  model.rebootAfterSuccess ? 'Enabled' : 'Disabled',
                ),
                if (flash) ...[
                  ('Version', model.firmwareVersion ?? 'Not specified'),
                  ('Images', '${model.firmwareInfo?['images'] ?? '—'}'),
                  (
                    'Payload',
                    _formatBytes(
                      (model.firmwareInfo?['bytes'] as num?)?.toInt(),
                    ),
                  ),
                ],
              ]),
              BodyText(
                task == 'Backup'
                    ? 'Your player’s storage will not be changed.'
                    : model.verifyWrites
                    ? 'The mapped storage ranges will be overwritten and verified by reading them back.'
                    : 'The mapped storage ranges will be overwritten without readback verification.',
              ),
            ],
          ),
        )
      else if (finished)
        Card(
          variant: SurfaceVariant.subtle,
          header: TitleText(
            model.phase == 'error'
                ? 'Operation failed'
                : model.phase == 'stopped'
                ? 'Operation stopped'
                : '${task == 'Flash' ? 'Installation' : task} complete',
          ),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: [
              BodyText(
                model.status,
                swatch: model.phase == 'error' ? SemanticSwatch.error : null,
              ),
              const CaptionText('Open Logs for the full operation history.'),
              if (model.phase == 'error')
                Align(
                  alignment: Alignment.centerLeft,
                  child: Button(
                    onPressed: model.copyError,
                    variant: SurfaceVariant.soft,
                    center: const Text('Copy error'),
                  ),
                ),
            ],
          ),
          footer: Button(
            onPressed: () {
              _startedWorkflow = null;
              model.updateUi(() {
                model.phase = 'ready';
                model.report = null;
                model.backupReady = false;
                model.firmwareReady = false;
              });
              _stepTo(flash, 0);
            },
            center: const Text('Start another operation'),
          ),
        )
      else
        _operationCard(),
      if (!finished && step < transfer)
        Align(
          alignment: Alignment.centerRight,
          child: Button(
            key: const ValueKey('workflow-next'),
            onPressed: model.busy || (step > 0 && !ready)
                ? null
                : () {
                    if (step == 0) {
                      _startedWorkflow = null;
                      model.selectTask(_workflowMode);
                    }
                    _stepTo(flash, step + 1);
                  },
            trailing: const Icon(LucideIcons.arrowRight),
            center: const Text('Continue'),
          ),
        ),
    ];
  }

  Widget _operationChoice(
    String task,
    IconData icon,
    String title,
    String description,
  ) {
    final selected = _workflowMode == task;
    final theme = ThemeProvider.of(context);
    return Semantics(
      selected: selected,
      child: Button.custom(
        key: ValueKey('operation-$task'),
        onPressed: model.busy
            ? null
            : () => setState(() => _workflowMode = task),
        style: theme.widgets.button
            .resolve(
              selected ? SemanticSwatch.primary : SemanticSwatch.neutral,
              selected ? SurfaceVariant.soft : SurfaceVariant.subtle,
            )
            .copyWith(
              height: 248 * MediaQuery.textScalerOf(context).scale(14) / 14,
              padding: const EdgeInsets.all(20),
            ),
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisAlignment: MainAxisAlignment.center,
              spacing: 16,
              children: [
                Icon(icon, size: 48),
                Text(title, textAlign: TextAlign.center),
                Text(
                  description,
                  textAlign: TextAlign.center,
                  style: theme.typography.caption,
                ),
              ],
            ),
            if (selected)
              const Positioned(
                top: 0,
                right: 0,
                child: Icon(LucideIcons.circleCheck, size: 20),
              ),
          ],
        ),
      ),
    );
  }

  Widget _recentActivity() {
    final activity = model.events
        .where(
          (event) => !{
            'progress',
            'flash-progress',
            'firmware-prepare-progress',
            'firmware-verify-progress',
          }.contains(event['event']),
        )
        .toList()
        .reversed
        .take(5);
    return Card(
      variant: SurfaceVariant.subtle,
      header: const TitleText('Recent activity'),
      content: activity.isEmpty
          ? const BodyText(
              'No operations yet. Connection checks, backups, and installs will appear here.',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 12,
              children: [
                for (final event in activity) _EventMessage(event: event),
              ],
            ),
      footer: const CaptionText('Activity from this Toolbox session.'),
    );
  }

  String _transferRate() {
    final seconds =
        DateTime.now().difference(model.operationStarted!).inMilliseconds /
        1000;
    if (seconds <= 0) return 'Calculating transfer speed…';
    final rate =
        model.transferBytesPerSecond ?? model.backupCompleted! / seconds;
    if (rate <= 0) return 'Calculating transfer speed…';
    final remaining = ((model.backupTotal! - model.backupCompleted!) / rate)
        .clamp(0, 864000)
        .round();
    return '${(rate / 1048576).toStringAsFixed(1)} MiB/s · approximately ${remaining < 60 ? '${remaining}s' : '${(remaining / 60).ceil()}m'} remaining';
  }

  static String _formatBytes(int? bytes) =>
      bytes == null ? '—' : '${(bytes / 1048576).toStringAsFixed(1)} MiB';

  Widget _workflowOptions() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 16,
    children: [
      Card(
        variant: SurfaceVariant.subtle,
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            Row(
              children: [
                const Expanded(child: BodyText('Reboot after success')),
                Switch<bool>(
                  key: const ValueKey('reboot-after-success'),
                  value: model.rebootAfterSuccess,
                  swatch: SemanticSwatch.primary,
                  onChanged: model.busy ? null : model.setRebootAfterSuccess,
                ),
              ],
            ),
            const CaptionText(
              'Restart the player when the operation finishes successfully.',
            ),
          ],
        ),
      ),

      if (model.task == 'Backup')
        const BodyText(
          'Backups use gzip compression and include BOOT1, BOOT2, and the complete user area. These settings are fixed; your player is only read.',
        ),
      if (model.task != 'Backup')
        Card(
          variant: SurfaceVariant.subtle,
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 8,
            children: [
              Row(
                children: [
                  const Expanded(child: BodyText('Verify written data')),
                  Switch<bool>(
                    key: const ValueKey('verify-written-data'),
                    value: model.verifyWrites,
                    swatch: SemanticSwatch.primary,
                    onChanged: model.busy ? null : model.setVerifyWrites,
                  ),
                ],
              ),
              const CaptionText(
                'Read written data back and compare it with the source. Adds transfer time. Input files are validated in either case.',
              ),
            ],
          ),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: Button(
          onPressed: model.busy
              ? null
              : () => model.updateUi(() => model.advanced = !model.advanced),
          variant: SurfaceVariant.ghost,
          leading: const Icon(LucideIcons.settings),
          center: const Text('Advanced'),
          trailing: Icon(
            model.advanced ? LucideIcons.chevronUp : LucideIcons.chevronDown,
          ),
        ),
      ),
      if (model.advanced)
        Card(
          variant: SurfaceVariant.subtle,
          header: const TitleText('Transfer method'),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: [
              Row(
                children: [
                  const Expanded(child: BodyText('Legacy Download Agent')),
                  Switch<bool>(
                    key: const ValueKey('legacy-download-agent'),
                    value: model.useLegacyDownloadAgent,
                    swatch: SemanticSwatch.primary,
                    onChanged: model.busy ? null : model.setLegacyDownloadAgent,
                  ),
                ],
              ),
              CaptionText(
                model.useLegacyDownloadAgent
                    ? 'Use the slower legacy transfer method without starting Tempo Recovery.'
                    : 'Tempo Recovery is the default. It runs in RAM and shows transfer progress on the player.',
              ),
              if (model.engine.isWeb && !model.useLegacyDownloadAgent)
                const CaptionText(
                  'Recovery transfers currently require the desktop Toolbox.',
                ),
            ],
          ),
        ),
      if (model.advanced &&
          (model.task == 'Flash' || model.task == 'Restore')) ...[
        const SizedBox(height: 16),
        Card(
          variant: SurfaceVariant.subtle,
          header: const TitleText('Write options'),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: [
              if (!model.engine.isWeb) ...[
                Row(
                  children: [
                    const Expanded(child: BodyText('Skip matching data')),
                    Switch<bool>(
                      key: const ValueKey('skip-matching-data'),
                      value: model.resumeWrites,
                      swatch: SemanticSwatch.primary,
                      onChanged: model.busy
                          ? null
                          : (value) => model.updateUi(
                              () => model.resumeWrites = value,
                            ),
                    ),
                  ],
                ),
                const CaptionText(
                  'Read each range first and skip it only if every byte already matches. The extra reads can take time.',
                ),
                const Divider(),
              ],
              Row(
                children: [
                  const Icon(LucideIcons.triangleAlert, size: 18),
                  const SizedBox(width: 8),
                  const Expanded(child: BodyText('Allow preloader flashing')),
                  Switch(
                    value: model.allowPreloaderFlash,
                    swatch: SemanticSwatch.error,
                    onChanged: model.busy ? null : _setPreloaderFlashing,
                  ),
                ],
              ),
              CaptionText(
                model.allowPreloaderFlash
                    ? 'Preloader protection is disabled for this installation.'
                    : 'Preloader protection is on. BOOT1 package ranges are skipped.',
                swatch: model.allowPreloaderFlash ? SemanticSwatch.error : null,
              ),
            ],
          ),
        ),
      ],

      if (model.advanced)
        NativeAdvanced(
          engine: model.engine,
          busy: model.busy,
          onBusy: (value) => model.updateUi(() {
            model.busy = value;
            if (!value) model.phase = 'ready';
          }),
        ),
    ],
  );

  Widget _operationCard() {
    final flashing = model.task == 'Flash' || model.task == 'Restore';
    final showProgress =
        !flashing || {'flash-started', 'flash-progress'}.contains(model.phase);
    final space = ThemeProvider.of(context).space;
    return Card(
      variant: SurfaceVariant.subtle,
      spacing: SpaceStep.x6,
      header: Row(
        children: [
          const Icon(LucideIcons.cable),
          const SizedBox(width: 12),
          Expanded(
            child: TitleText(
              model.task == null
                  ? 'Connection check'
                  : 'Connect to ${model.task!.toLowerCase()}',
            ),
          ),
        ],
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Step(
            number: '1',
            text: model.engine.isWeb
                ? 'Choose a connection button below to open the device picker.'
                : 'Choose Connect Y2 below to start listening.',
          ),
          _Step(
            number: '2',
            text: !model.useLegacyDownloadAgent && model.task != 'Probe'
                ? 'Connect a Y2 already running Tempo Recovery, or connect the powered-off player to start recovery in RAM.'
                : 'Connect the powered-off Y2. Or press the reset button using a pin while the USB device is connected.',
          ),
          _Step(
            number: '3',
            text: model.engine.isWeb
                ? 'Promptly select the MediaTek entry and click Connect in the picker.'
                : !model.useLegacyDownloadAgent && model.task != 'Probe'
                ? 'Toolbox will connect to recovery and start the transfer.'
                : 'The installer will catch the boot connection.',
          ),
        ],
      ),
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: space.x3,
            runSpacing: space.x3,
            children: [
              Button(
                onPressed:
                    model.supported &&
                        !model.busy &&
                        (model.task != 'Backup' || model.backupReady) &&
                        ((model.task != 'Flash' && model.task != 'Restore') ||
                            model.firmwareReady)
                    ? () => _start()
                    : null,
                leading: const Icon(LucideIcons.usb),
                center: Text(
                  (model.task == 'Flash' || model.task == 'Restore')
                      ? 'Connect and ${model.task!.toLowerCase()}'
                      : model.task == 'Backup'
                      ? 'Connect and back up'
                      : 'Connect Y2',
                ),
              ),
              if (model.busy)
                Button(
                  onPressed: model.preloaderWriting || model.stopping
                      ? null
                      : model.stop,
                  leading: model.stopping
                      ? const SizedBox.square(
                          dimension: 16,
                          child: Progress.spinner(),
                        )
                      : null,
                  variant: SurfaceVariant.ghost,
                  swatch: SemanticSwatch.neutral,
                  center: Text(model.stopping ? 'Stopping…' : 'Stop'),
                ),
            ],
          ),
          if (model.engine.isWeb || model.task == null) ...[
            SizedBox(height: space.x3),
            Button(
              onPressed: model.busy
                  ? null
                  : () =>
                        model.updateUi(() => model.advanced = !model.advanced),
              variant: SurfaceVariant.ghost,
              swatch: SemanticSwatch.neutral,
              leading: const Icon(LucideIcons.settings),
              trailing: Icon(
                model.advanced
                    ? LucideIcons.chevronUp
                    : LucideIcons.chevronDown,
              ),
              center: const Text('Advanced'),
            ),
            if (model.advanced) ...[
              const SizedBox(height: 16),
              if (model.task == null)
                NativeAdvanced(
                  engine: model.engine,
                  busy: model.busy,
                  onBusy: (value) => model.updateUi(() {
                    model.busy = value;
                    if (!value) model.phase = 'ready';
                  }),
                ),
              if (model.engine.isWeb) ...[
                SizedBox(height: space.x3),
                const CaptionText(
                  'Use the operating system’s serial driver if WebUSB cannot claim the preloader interface.',
                  emphasis: TextEmphasis.secondary,
                ),
                if (!model.serialSupported) ...[
                  SizedBox(height: space.x2),
                  const CaptionText(
                    'Web Serial is not available in this browser.',
                    emphasis: TextEmphasis.secondary,
                  ),
                ],
                SizedBox(height: space.x3),
                Button(
                  onPressed:
                      model.serialSupported &&
                          !model.busy &&
                          (model.task != 'Backup' || model.backupReady) &&
                          ((model.task != 'Flash' && model.task != 'Restore') ||
                              model.firmwareReady)
                      ? () => _start(serial: true)
                      : null,
                  variant: SurfaceVariant.outline,
                  leading: const Icon(LucideIcons.cable),
                  center: const Text('Connect via serial'),
                ),
              ],
            ],
          ],
          SizedBox(height: space.x5),
          if (model.busy &&
              {
                'recovery-boot-progress',
                'recovery-starting',
              }.contains(model.phase)) ...[
            BodyText(model.status),
            if (model.transferTaskTotal != null &&
                model.transferTaskCompleted != null)
              _OperationProgress(
                completed: model.transferTaskCompleted!,
                total: model.transferTaskTotal!,
                label: model.status,
              )
            else
              const Align(
                alignment: Alignment.centerLeft,
                child: SizedBox.square(
                  dimension: 24,
                  child: Progress.spinner(),
                ),
              ),
            SizedBox(height: space.x4),
          ],
          if (showProgress &&
              model.backupCompleted != null &&
              model.backupTotal != null) ...[
            if (flashing &&
                model.transferTaskTotal != null &&
                model.transferTaskCompleted != null) ...[
              BodyText(model.status),
              _OperationProgress(
                completed: model.transferTaskCompleted!,
                total: model.transferTaskTotal!,
                label: model.status,
              ),
              SizedBox(height: space.x4),
            ],
            if (!flashing ||
                model.showOverallFlashProgress ||
                model.transferTaskTotal == null ||
                model.transferTaskCompleted == null) ...[
              if (flashing) const BodyText('Overall flash'),
              _OperationProgress(
                completed: model.backupCompleted!,
                total: model.backupTotal!,
                label: (model.task == 'Flash' || model.task == 'Restore')
                    ? model.status
                    : 'Backup',
              ),
            ],
            if (model.busy &&
                model.backupCompleted! > 0 &&
                model.operationStarted != null) ...[
              SizedBox(height: space.x2),
              CaptionText(_transferRate()),
            ],
            SizedBox(height: space.x5),
          ] else if (showProgress && model.busy && model.task != 'Backup') ...[
            const Progress.bar(),
            SizedBox(height: space.x4),
          ],
          if (!(model.busy &&
                  {
                    'recovery-boot-progress',
                    'recovery-starting',
                  }.contains(model.phase)) &&
              (!showProgress ||
                  !{
                    'progress',
                    'backup-started',
                    'firmware-prepare-progress',
                    'firmware-verify-progress',
                    'flash-progress',
                  }.contains(model.phase)))
            Semantics(
              liveRegion: true,
              child: Row(
                children: [
                  if (flashing &&
                      model.busy &&
                      {
                        'firmware-prepare-started',
                        'firmware-prepare-progress',
                        'firmware-verify-progress',
                      }.contains(model.phase)) ...[
                    const SizedBox.square(
                      key: ValueKey('firmware-integrity-spinner'),
                      dimension: 20,
                      child: Progress.spinner(),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: BodyText(
                      model.status,
                      swatch: model.phase == 'error'
                          ? SemanticSwatch.error
                          : null,
                    ),
                  ),
                ],
              ),
            ),
          if (model.phase == 'error') ...[
            SizedBox(height: space.x3),
            Button(
              onPressed: model.copyError,
              variant: SurfaceVariant.outline,
              swatch: SemanticSwatch.neutral,
              leading: Icon(
                model.errorCopied ? LucideIcons.check : LucideIcons.copy,
              ),
              center: Text(model.errorCopied ? 'Error copied' : 'Copy error'),
            ),
          ],
          if (model.report != null) ...[
            SizedBox(height: space.x4),
            BodyText(
              'Chip 0x${(model.report!['hardware_code'] as int).toRadixString(16)} · ${model.report!['storage_written'] == true ? 'firmware written and verified' : 'storage unchanged'}',
            ),
            SizedBox(height: space.x2),
            CaptionText(
              model.report!['y2_verified'] == true
                  ? 'Exact Y2 eMMC geometry verified.'
                  : 'Full Y2 identification still requires checking its storage and partition layout.',
              emphasis: TextEmphasis.secondary,
            ),
          ],
        ],
      ),
    );
  }
}

class _EventMessage extends StatelessWidget {
  const _EventMessage({required this.event});

  final Map<String, dynamic> event;

  String get _kind => event['event']?.toString() ?? 'event';

  String get _title => switch (_kind) {
    'choosing' => 'Picker opened',
    'permission' => 'Device selected',
    'capturing' => 'Connecting to preloader',
    'descriptors' => 'USB interfaces found',
    'claiming' => 'Claiming USB interface',
    'waiting' => 'Waiting for Y2',
    'backup-started' => 'Backup started',
    'progress' => 'Backup progress',
    'backup-complete' => 'Backup finished',
    'result' => 'Connection complete',
    'disconnected' => 'Y2 disconnected',
    'stopped' => 'Connection stopped',
    'error' => 'Connection error',
    _ => _humanize(_kind),
  };

  IconData get _icon => switch (_kind) {
    'error' => LucideIcons.circleAlert,
    'result' || 'backup-complete' => LucideIcons.check,
    'permission' || 'capturing' || 'claiming' => LucideIcons.usb,
    _ => LucideIcons.circle,
  };

  static String _humanize(String value) {
    final words = value.replaceAll('-', ' ').replaceAll('_', ' ').split(' ');
    return words
        .where((word) => word.isNotEmpty)
        .map((word) => '${word[0].toUpperCase()}${word.substring(1)}')
        .join(' ');
  }

  static String _timestamp(Object? value) {
    final parsed = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
    if (parsed == null) return '';
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(parsed.hour)}:${two(parsed.minute)}:${two(parsed.second)}';
  }

  static List<(String, String)> _details(Map<String, dynamic> event) {
    final result = <(String, String)>[];
    void add(Object? value, List<String> path) {
      if (value is Map) {
        for (final entry in value.entries) {
          add(entry.value, [...path, entry.key.toString()]);
        }
      } else if (value is List && value.every((item) => item is Map)) {
        for (final (index, item) in value.indexed) {
          add(item, [...path, '${index + 1}']);
        }
      } else {
        final label = path.map(_humanize).join(' · ');
        final formatted = switch (value) {
          bool flag => flag ? 'Yes' : 'No',
          List values when values.every((item) => item is int) =>
            '${values.length} bytes · ${values.take(16).map((item) => (item as int).toRadixString(16).padLeft(2, '0')).join(' ')}${values.length > 16 ? ' …' : ''}',
          List values => values.take(12).join(', '),
          null => '—',
          _ => value.toString(),
        };
        result.add((label, formatted));
      }
    }

    for (final entry in event.entries) {
      if (!{'event', 'timestamp', 'message'}.contains(entry.key)) {
        add(entry.value, [entry.key]);
      }
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final space = ThemeProvider.of(context).space;
    final details = _details(event);
    return Surface(
      variant: SurfaceVariant.subtle,
      swatch: _kind == 'error' ? SemanticSwatch.error : SemanticSwatch.neutral,
      padding: EdgeInsets.all(space.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_icon, size: 18),
              SizedBox(width: space.x3),
              Expanded(child: TitleText(_title)),
              CaptionText(
                _timestamp(event['timestamp']),
                emphasis: TextEmphasis.secondary,
              ),
            ],
          ),
          if (event['message'] case final Object message) ...[
            SizedBox(height: space.x2),
            BodyText(message.toString()),
          ],
          if (details.isNotEmpty) ...[
            SizedBox(height: space.x3),
            for (final (label, value) in details) ...[
              CaptionText(label, emphasis: TextEmphasis.secondary),
              SizedBox(height: space.x1),
              BodyText(value),
              if ((label, value) != details.last) SizedBox(height: space.x2),
            ],
          ],
        ],
      ),
    );
  }
}

class _OperationProgress extends StatelessWidget {
  const _OperationProgress({
    required this.completed,
    required this.total,
    required this.label,
  });

  final int completed;
  final int total;
  final String label;

  static String _amount(int bytes) {
    const gibibyte = 1073741824;
    const mebibyte = 1048576;
    if (bytes < gibibyte) {
      return '${(bytes / mebibyte).toStringAsFixed(0)} MiB';
    }
    return '${(bytes / gibibyte).toStringAsFixed(2)} GiB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final space = theme.space;
    final progress = total <= 0 ? 0.0 : (completed / total).clamp(0.0, 1.0);
    final percent = (progress * 100).toStringAsFixed(1);
    return Semantics(
      liveRegion: true,
      label: '$label progress',
      value: '$percent percent, ${_amount(completed)} of ${_amount(total)}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    TitleText(
                      '$percent%',
                      style: const Typography.recursive().code.copyWith(
                        fontSize: theme.typography.title.fontSize,
                        fontWeight: theme.typography.title.fontWeight,
                      ),
                    ),
                    const TitleText(' complete'),
                  ],
                ),
              ),
              SizedBox(width: space.x4),
              CaptionText(
                '${_amount(completed)} of ${_amount(total)}',
                emphasis: TextEmphasis.secondary,
              ),
            ],
          ),
          SizedBox(height: space.x3),
          Progress.bar(
            value: progress,
            style: theme.widgets.progress
                .resolve(SemanticSwatch.primary, SurfaceDress.maybeOf(context))
                .copyWith(thickness: space.x3),
          ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.text});
  final String number, text;
  @override
  Widget build(BuildContext context) {
    final space = ThemeProvider.of(context).space;
    return Padding(
      padding: EdgeInsets.only(bottom: space.x3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CaptionText(number.padLeft(2, '0'), swatch: SemanticSwatch.primary),
          SizedBox(width: space.x4),
          Expanded(child: BodyText(text)),
        ],
      ),
    );
  }
}

class _UnsupportedBrowserPage extends StatelessWidget {
  const _UnsupportedBrowserPage();

  @override
  Widget build(BuildContext context) {
    final space = ThemeProvider.of(context).space;
    final width = MediaQuery.sizeOf(context).width;
    final pagePadding = width < 600 ? space.x6 : space.x12;
    final columnMargin = width > 960 ? (width - 960) / 2 : 0.0;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.symmetric(
            horizontal: columnMargin + pagePadding,
            vertical: pagePadding,
          ),
          children: [
            const TitleText('Tempo Toolbox'),
            SizedBox(height: space.x12),
            const Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(LucideIcons.circleAlert, size: 40),
                SizedBox(width: 16),
                Expanded(
                  child: DisplayText('This browser can’t connect to the Y2.'),
                ),
              ],
            ),
            SizedBox(height: space.x4),
            const BodyText(
              'This installer uses WebUSB to find the Y2 when it starts up, but this browser doesn’t provide the access it needs.',
            ),
            SizedBox(height: space.x6),
            Card(
              variant: SurfaceVariant.subtle,
              header: const TitleText('Use a supported browser'),
              content: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const BodyText(
                    'Open this page in Chrome, Edge, or another Chromium-based browser with WebUSB.',
                  ),
                  const SizedBox(height: 12),
                  Link(
                    'Use the installer app',
                    external: true,
                    onPressed: () => unawaited(
                      launchUrl(
                        Uri.parse(
                          'https://tempo.artificery.dev/downloads/installer',
                        ),
                        mode: LaunchMode.externalApplication,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HelpStep extends StatelessWidget {
  const _HelpStep({
    required this.number,
    required this.title,
    required this.text,
    required this.screenshot,
  });
  final String number, title, text, screenshot;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TitleText('$number. $title'),
        const SizedBox(height: 8),
        BodyText(text),
        const SizedBox(height: 12),
        Card(
          variant: SurfaceVariant.subtle,
          content: SizedBox(
            height: 96,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(LucideIcons.image),
                  const SizedBox(height: 8),
                  const CaptionText('Screenshot placeholder'),
                  CaptionText(screenshot),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

/// Package identity is self-contained; older packages have no icon.
class _FirmwareIdentity extends StatefulWidget {
  const _FirmwareIdentity({required this.metadata});
  final Map metadata;
  @override
  State<_FirmwareIdentity> createState() => _FirmwareIdentityState();
}

class _FirmwareIdentityState extends State<_FirmwareIdentity> {
  Map get metadata => widget.metadata;
  Uint8List? _iconBytes;
  Object? _iconSource;

  @override
  void initState() {
    super.initState();
    _refreshIcon();
  }

  @override
  void didUpdateWidget(covariant _FirmwareIdentity oldWidget) {
    super.didUpdateWidget(oldWidget);
    _refreshIcon();
  }

  void _refreshIcon() {
    if (_iconSource == metadata['icon']) return;
    _iconSource = metadata['icon'];
    _iconBytes = _decodeIcon();
  }

  Uint8List? _decodeIcon() {
    final value = metadata['icon'];
    const prefix = 'data:image/png;base64,';
    if (value is! String ||
        !value.startsWith(prefix) ||
        value.length > 128 * 1024 + prefix.length) {
      return null;
    }
    try {
      return base64Decode(value.substring(prefix.length));
    } on FormatException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _iconBytes;
    const fallback = Icon(LucideIcons.package, size: 40);
    return Column(
      key: const ValueKey('firmware-identity'),
      crossAxisAlignment: CrossAxisAlignment.center,
      spacing: 12,
      children: [
        SizedBox(
          width: 120,
          height: 96,
          child: bytes == null
              ? fallback
              : Image.memory(
                  bytes,
                  fit: BoxFit.contain,
                  cacheWidth: 240,
                  gaplessPlayback: true,
                  semanticLabel: '${metadata['name'] ?? 'Firmware'} icon',
                  errorBuilder: (_, _, _) => fallback,
                ),
        ),
        TitleText(metadata['name']?.toString() ?? 'Firmware'),
        BodyText('Version ${metadata['version'] ?? 'Not specified'}'),
        if (metadata['commit'] case final String commit)
          Text(
            'Commit ${commit.substring(0, commit.length.clamp(0, 7))}',
            textAlign: TextAlign.center,
          ),
      ],
    );
  }
}

class _PackageValidationLabel extends StatelessWidget {
  const _PackageValidationLabel({this.completed, this.total});
  final int? completed, total;
  @override
  Widget build(BuildContext context) {
    final percent = total != null && total! > 0
        ? ((completed ?? 0) / total! * 100).clamp(0, 100)
        : 0.0;
    final value = '${percent.toStringAsFixed(1).padLeft(4, '0')}%';
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        const Text('Validating package '),
        SizedBox(
          width: 64,
          child: Text(
            value,
            textAlign: TextAlign.center,
            style: const Typography.recursive().code,
          ),
        ),
        const Text(' complete'),
      ],
    );
  }
}
