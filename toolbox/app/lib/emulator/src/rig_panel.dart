import 'package:tempo_core/tempo_core.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:file_selector/file_selector.dart';
import 'package:tomeui/tomeui.dart';

import 'rig.dart';
import 'paths.dart';
import 'card_import.dart';

/// Shared controls for the emulated device state.
class RigPanel extends StatelessWidget {
  const RigPanel({
    required this.rig,
    this.showUiScale = true,
    this.collapsible = false,
    super.key,
  });

  static const swatch = SemanticSwatch.primary;

  /// Show the rig over the device.
  ///
  /// Pushed on the device's own navigator rather than the app's, so the
  /// modal covers the player and stops there: the title bar above it stays
  /// live, and the window can still be moved, minimized, or closed with the
  /// rig open.
  static Future<void> show(NavigatorState navigator, Theme theme, Rig rig) =>
      navigator.push(route(theme, rig));

  /// The rig as a route, for a caller that wants to hold onto it - the
  /// bar's button, which is the way in and the way out.
  static DialogRoute<void> route(Theme theme, Rig rig) => DialogRoute<void>(
    theme: theme,
    builder: (context) => Dialog(
      swatch: swatch,
      title: Row(
        children: [
          const Expanded(child: Text('Machine state')),
          Tooltip(
            message: const Text('Close'),
            child: Button(
              onPressed: () => Navigator.of(context).maybePop(),
              variant: SurfaceVariant.ghost,
              swatch: swatch,
              center: const Icon(LucideIcons.x, size: 14),
            ),
          ),
        ],
      ),
      message: const Text(
        'What the player is told about the hardware under it.',
      ),
      content: RigPanel(rig: rig),
      actions: [
        Button(
          onPressed: () => Navigator.of(context).maybePop(),
          swatch: swatch,
          center: const Text('Done'),
        ),
      ],
    ),
  );

  final Rig rig;
  final bool showUiScale;
  final bool collapsible;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);

    return ListenableBuilder(
      listenable: rig,
      builder: (context, _) => _PanelPresentation(
        collapsible: collapsible,
        child: Builder(
          builder: (context) {
            final content = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: collapsible ? 12 : theme.space.x5,
              children: [
                const _AppearanceSection(),
                if (!collapsible) const Divider(),
                if (showUiScale) ...[const _ScaleSection(), const Divider()],
                _BatterySection(rig: rig),
                if (!collapsible) const Divider(),
                _ScreenSection(rig: rig),
                if (!collapsible) const Divider(),
                _Section(
                  title: 'FM Radio',
                  children: [
                    _Control(
                      label: 'Mock FM radio',
                      description: CaptionText(
                        !rig.fmRadio.attached
                            ? 'FM radio uses simulated stations.'
                            : rig.fmRadio.mocked
                            ? 'Simulate tuning, stereo, and RDS without audio.'
                            : 'Tune and play broadcasts from the attached RTL-SDR.',
                      ),
                      child: Switch<bool>(
                        key: const Key('Emulator.mockFm'),
                        value: rig.fmRadio.mocked,
                        swatch: swatch,
                        onChanged: rig.fmRadio.canToggle
                            ? rig.fmRadio.setMocked
                            : null,
                      ),
                    ),
                  ],
                ),
                if (!collapsible) const Divider(),

                if (rig.radios.mode == RadioMode.mocked) _WifiSection(rig: rig),
                if (!collapsible) const Divider(),
                if (rig.radios.mode == RadioMode.mocked)
                  _BluetoothSection(rig: rig),
                if (!collapsible) const Divider(),
                _CardSection(rig: rig),
              ],
            );
            return collapsible
                ? content
                : SingleChildScrollView(child: content);
          },
        ),
      ),
    );
  }
}

class _PanelPresentation extends InheritedWidget {
  const _PanelPresentation({required this.collapsible, required super.child});
  final bool collapsible;
  @override
  bool updateShouldNotify(_PanelPresentation oldWidget) =>
      collapsible != oldWidget.collapsible;
}

/// Independently expandable controls, retaining field state while closed.
class EmulatorControlCard extends StatefulWidget {
  const EmulatorControlCard({
    required this.title,
    required this.icon,
    required this.child,
    super.key,
  });
  final String title;
  final IconData icon;
  final Widget child;
  @override
  State<EmulatorControlCard> createState() => _EmulatorControlCardState();
}

class _EmulatorControlCardState extends State<EmulatorControlCard> {
  bool _expanded = false;
  @override
  Widget build(BuildContext context) => Card(
    variant: SurfaceVariant.subtle,
    spacing: SpaceStep.none,
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          expanded: _expanded,
          child: Button(
            key: ValueKey('emulator-section-${widget.title}'),
            variant: SurfaceVariant.ghost,
            swatch: RigPanel.swatch,
            onPressed: () => setState(() => _expanded = !_expanded),
            leading: Icon(widget.icon, size: 18),
            center: Align(
              alignment: Alignment.centerLeft,
              child: Text(widget.title),
            ),
            trailing: AnimatedRotation(
              turns: _expanded ? .5 : 0,
              duration: const Duration(milliseconds: 200),
              child: const Icon(LucideIcons.chevronDown, size: 16),
            ),
          ),
        ),
        ClipRect(
          child: AnimatedAlign(
            alignment: Alignment.topCenter,
            heightFactor: _expanded ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            child: ExcludeFocus(
              excluding: !_expanded,
              child: ExcludeSemantics(
                excluding: !_expanded,
                child: IgnorePointer(
                  ignoring: !_expanded,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: widget.child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

/// A heading and its controls.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);

    final collapsible =
        context
            .dependOnInheritedWidgetOfExactType<_PanelPresentation>()
            ?.collapsible ??
        false;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: theme.space.x3,
      children: [
        if (!collapsible) KickerText(title),
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const Divider(),
          children[i],
        ],
      ],
    );
    return collapsible
        ? EmulatorControlCard(
            title: title,
            icon: switch (title) {
              'Appearance' => LucideIcons.palette,
              'Scale' => LucideIcons.maximize,
              'Battery' => LucideIcons.battery,
              'Screen' => LucideIcons.monitor,
              'FM Radio' => LucideIcons.radio,
              'Wi-Fi' => LucideIcons.wifi,
              'Bluetooth' => LucideIcons.bluetooth,
              'SD card' => LucideIcons.hardDrive,
              _ => LucideIcons.slidersHorizontal,
            },
            child: content,
          )
        : content;
  }
}

class _Control extends StatelessWidget {
  const _Control({
    required this.label,
    required this.description,
    required this.child,
  });
  final String label;
  final Widget description;
  final Widget child;

  bool get _inline => child is Switch;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 8,
    children: [
      if (_inline)
        Row(
          spacing: 12,
          children: [
            Expanded(child: BodyText(label)),
            Semantics(label: label, child: child),
          ],
        )
      else
        BodyText(label),
      description,
      if (!_inline)
        Align(
          alignment: Alignment.centerLeft,
          child: Semantics(
            label: label,
            child: child is SegmentedControl
                ? FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: child,
                  )
                : child is Slider
                ? SizedBox(width: double.infinity, child: child)
                : child,
          ),
        ),
    ],
  );
}

/// Light or dark, for the emulator and the player alike.
///
/// One control for both on purpose: this is the same [Appearance.mode] the
/// player's own Settings > Appearance > Theme moves, put where a hand on a
/// desk can reach it without walking the menus.
class _AppearanceSection extends StatelessWidget {
  const _AppearanceSection();
  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: Appearance.mode,
    builder: (context, mode, _) => _Section(
      title: 'Appearance',
      children: [
        _Control(
          label: 'Theme',
          description: mode == AppearanceMode.auto
              ? const _AutoReading()
              : CaptionText(
                  'Use the ${mode.name} theme for the player and emulator.',
                ),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedControl<AppearanceMode>(
              stretch: true,
              value: mode,
              swatch: RigPanel.swatch,
              onChanged: (value) => Appearance.mode.value = value,
              segments: const [
                SegmentOption(value: AppearanceMode.auto, label: Text('Auto')),
                SegmentOption(
                  value: AppearanceMode.light,
                  label: Text('Light'),
                ),
                SegmentOption(value: AppearanceMode.dark, label: Text('Dark')),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

/// What Auto is actually doing: the place it is working from and when it
/// next turns over, or - with no time zone set - the desktop it is
/// falling back to. The rig's job is to make an invisible rule visible.
class _AutoReading extends StatelessWidget {
  const _AutoReading();

  @override
  Widget build(BuildContext context) {
    final place = Appearance.place.value;
    if (place == null) {
      return const CaptionText(
        'No time zone set, so no sunrise to follow: taking the desktop\'s '
        'light instead.',
        emphasis: TextEmphasis.secondary,
      );
    }
    final next = Appearance.nextChange?.toLocal();
    final at = next == null
        ? 'not for days - the sun is not crossing the horizon there'
        : 'next at ${next.hour.toString().padLeft(2, '0')}:'
              '${next.minute.toString().padLeft(2, '0')}';
    return CaptionText(
      'Following the sun at ${place.latitude.toStringAsFixed(2)}, '
      '${place.longitude.toStringAsFixed(2)}: $at.',
      emphasis: TextEmphasis.secondary,
    );
  }
}

/// How large the player draws its UI: the click-wheel proportions it
/// defaults to, or the first UI at Tome's desktop size, kept for
/// comparison. The player's setting, moved from here until it has one.
class _ScaleSection extends StatelessWidget {
  const _ScaleSection();
  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: Appearance.scale,
    builder: (context, scale, _) => _Section(
      title: 'Scale',
      children: [
        _Control(
          label: 'Interface size',
          description: CaptionText(switch (scale) {
            UiScale.compact => 'Seven rows to the screen.',
            UiScale.regular => 'A title bar and six rows to the screen.',
            UiScale.large => 'The first UI: three rows to the screen.',
          }),
          child: SegmentedControl<UiScale>(
            value: scale,
            swatch: RigPanel.swatch,
            onChanged: (value) => Appearance.scale.value = value,
            segments: [
              for (final option in UiScale.values)
                SegmentOption(value: option, label: Text(option.label)),
            ],
          ),
        ),
      ],
    ),
  );
}

class _BatterySection extends StatelessWidget {
  const _BatterySection({required this.rig});
  final Rig rig;
  @override
  Widget build(BuildContext context) {
    final battery = rig.battery.value;
    final percent = battery.percent ?? 0;
    return _Section(
      title: 'Battery',
      children: [
        _Control(
          label: 'Charge level',
          description: const CaptionText(
            'Battery percentage reported to the player.',
          ),
          child: Row(
            children: [
              Expanded(
                child: Slider(
                  value: percent.toDouble(),
                  max: 100,
                  divisions: 20,
                  swatch: RigPanel.swatch,
                  onChanged: (value) => rig.setCharge(value.round()),
                ),
              ),
              const SizedBox(width: 12),
              BodyText('$percent%'),
            ],
          ),
        ),
        _Control(
          label: 'On the charger',
          description: const CaptionText(
            'Simulate connecting the player to external power.',
          ),
          child: Switch(
            value: battery.charging,
            swatch: RigPanel.swatch,
            onChanged: rig.setCharging,
          ),
        ),
      ],
    );
  }
}

/// A hand on the sleep clock: held (the default on a desk) the screen
/// never sleeps by itself; lifted, it sleeps the way the device does. The
/// power key works either way.
class _ScreenSection extends StatelessWidget {
  const _ScreenSection({required this.rig});
  final Rig rig;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: ScreenSleep.inhibited,
    builder: (context, inhibited, _) => _Section(
      title: 'Screen',
      children: [
        _Control(
          label: 'Stay awake',
          description: CaptionText(
            inhibited
                ? 'Never sleeps by itself. The power key still puts it to sleep and wakes it.'
                : 'Dims, then sleeps when left alone, as the device does.',
          ),
          child: Switch(
            value: inhibited,
            swatch: RigPanel.swatch,
            onChanged: (hold) => ScreenSleep.inhibited.value = hold,
          ),
        ),
      ],
    ),
  );
}

class _WifiSection extends StatelessWidget {
  const _WifiSection({required this.rig});
  final Rig rig;
  @override
  Widget build(BuildContext context) {
    final wifi = rig.wifi.value;
    return _Section(
      title: 'Wi-Fi',
      children: [
        _Control(
          label: 'Connection',
          description: CaptionText(switch (wifi.status) {
            WifiStatus.off => 'The Wi-Fi radio is switched off.',
            WifiStatus.connected => 'Connected to ${wifi.network}.',
            _ => 'Searching for a network to join.',
          }),
          child: SegmentedControl<WifiStatus>(
            value: wifi.status,
            swatch: RigPanel.swatch,
            onChanged: rig.setWifi,
            segments: const [
              SegmentOption(value: WifiStatus.off, label: Text('Off')),
              SegmentOption(
                value: WifiStatus.disconnected,
                label: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('Searching'),
                ),
              ),
              SegmentOption(value: WifiStatus.connected, label: Text('On')),
            ],
          ),
        ),
        if (wifi.status == WifiStatus.connected)
          _Control(
            label: 'Signal strength',
            description: CaptionText(
              '${wifi.bars} of 3 bars reported to the player.',
            ),
            child: Slider(
              value: wifi.bars.toDouble(),
              max: 3,
              divisions: 3,
              swatch: RigPanel.swatch,
              onChanged: (value) => rig.setBars(value.round()),
            ),
          ),
      ],
    );
  }
}

class _BluetoothSection extends StatelessWidget {
  const _BluetoothSection({required this.rig});
  final Rig rig;
  @override
  Widget build(BuildContext context) {
    final bluetooth = rig.bluetooth.value;
    return _Section(
      title: 'Bluetooth',
      children: [
        _Control(
          label: 'Connection',
          description: CaptionText(switch (bluetooth.status) {
            BluetoothStatus.off => 'The Bluetooth radio is switched off.',
            BluetoothStatus.on => 'On, with nothing paired at hand.',
            BluetoothStatus.connected => 'Talking to ${bluetooth.device}.',
          }),
          child: SegmentedControl<BluetoothStatus>(
            value: bluetooth.status,
            swatch: RigPanel.swatch,
            onChanged: rig.setBluetooth,
            segments: const [
              SegmentOption(value: BluetoothStatus.off, label: Text('Off')),
              SegmentOption(value: BluetoothStatus.on, label: Text('On')),
              SegmentOption(
                value: BluetoothStatus.connected,
                label: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('Connected'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CardSection extends StatelessWidget {
  const _CardSection({required this.rig});

  final Rig rig;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);

    return _Section(
      title: 'SD card',
      children: [
        _Control(
          label: 'First run',
          description: const CaptionText(
            'Open the player on its first-run setup, as a fresh device does.',
          ),
          child: Switch(
            value: rig.firstRun,
            swatch: RigPanel.swatch,
            onChanged: (on) => rig.firstRun = on,
          ),
        ),
        _Control(
          label: 'Card in the slot',
          description: const CaptionText(
            'Insert or remove the simulated SD card.',
          ),
          child: Switch(
            value: rig.cardInserted,
            swatch: RigPanel.swatch,
            onChanged: (inserted) => rig.cardInserted = inserted,
          ),
        ),
        _Control(
          label: 'Card contents',
          description: const CaptionText(
            'Choose where the simulated card reads and writes its files.',
          ),
          child: RadioGroup<CardSource>(
            value: rig.cardSource,
            onChanged: rig.cardInserted
                ? (source) => rig.cardSource = source
                : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: theme.space.x3,
              children: [
                const _CardChoice(
                  value: CardSource.inMemory,
                  title: 'In-Memory',
                  description:
                      'A card the emulator makes up. Writes live as long as '
                      'the session does and are gone on the next run.',
                ),
                _CardChoice(
                  value: CardSource.hostFolder,
                  title: 'Host Folder',
                  description:
                      'A directory on this machine, mounted as the card. Real '
                      'files, and the player writes to them.',
                  child: rig.cardSource == CardSource.hostFolder
                      ? _HostFolderField(rig: rig)
                      : null,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// One card source: the choice, and what choosing it means.
class _CardChoice extends StatelessWidget {
  const _CardChoice({
    required this.value,
    required this.title,
    required this.description,
    this.child,
  });

  final Widget? child;
  final CardSource value;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final chooser = RadioGroup.maybeOf<CardSource>(context)?.onChanged;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RadioButton<CardSource>(
          value: value,
          label: Text(title),
          swatch: RigPanel.swatch,
        ),
        Padding(
          // Under the words, lined up with them rather than with the dot.
          padding: EdgeInsets.only(
            left: theme.sizes.controlCompact,
            top: theme.space.x1,
          ),
          child: CaptionText(
            description,
            emphasis: chooser == null
                ? TextEmphasis.disabled
                : TextEmphasis.secondary,
          ),
        ),
        if (child != null)
          Padding(
            padding: EdgeInsets.only(
              left: theme.sizes.controlCompact,
              top: theme.space.x3,
            ),
            child: child,
          ),
      ],
    );
  }
}

class _HostFolderField extends StatefulWidget {
  const _HostFolderField({required this.rig});

  final Rig rig;

  @override
  State<_HostFolderField> createState() => _HostFolderFieldState();
}

class _HostFolderFieldState extends State<_HostFolderField> {
  late final _controller = TextEditingController(text: widget.rig.hostFolder);
  bool _importing = false;
  String? _importStatus;
  bool get _mobile =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  Future<void> _import() async {
    setState(() => _importing = true);
    try {
      final files = await openFiles();
      if (files.isEmpty) return;
      final card = Paths.ensureCard();
      final count = await importCardFiles(files, card);
      if (!mounted) return;
      widget.rig.hostFolder = card.path;
      _controller.text = card.path;
      await widget.rig.services.library.scan();
      if (!mounted) return;
      setState(
        () => _importStatus = 'Imported $count file(s) into the mock card.',
      );
    } catch (error) {
      if (mounted) setState(() => _importStatus = 'Import failed: $error');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// The desktop's own chooser, which is the only one that knows where this
  /// machine keeps things.
  Future<void> _choose() async {
    final chosen = await getDirectoryPath(
      confirmButtonText: 'Use as card',
      initialDirectory: widget.rig.hostFolder.isEmpty
          ? null
          : widget.rig.hostFolder,
    );
    if (chosen == null || !mounted) return;
    _controller.text = chosen;
    widget.rig.hostFolder = chosen;
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: theme.space.x2,
      children: [
        TextField(
          controller: _controller,
          label: const Text('Folder'),
          placeholder: const Text('Folder on this device'),
          helper: const Text('An absolute path on this machine.'),
          enabled: widget.rig.cardInserted && !_mobile,
          onChanged: (path) => widget.rig.hostFolder = path.trim(),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: Button(
            onPressed: widget.rig.cardInserted && !_importing
                ? (_mobile ? _import : _choose)
                : null,
            variant: SurfaceVariant.soft,
            swatch: RigPanel.swatch,
            leading: const Icon(LucideIcons.folderOpen, size: 14),
            center: Text(_mobile ? 'Import media files' : 'Choose folder'),
          ),
        ),
        if (_importStatus != null) CaptionText(_importStatus!),
      ],
    );
  }
}
