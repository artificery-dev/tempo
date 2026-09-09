import 'package:tomeui/tomeui.dart';

enum ToolboxSection {
  player('Player', 'Player', LucideIcons.smartphone),
  settings('Device Settings', 'Settings', LucideIcons.slidersHorizontal),
  emulator('Emulator', 'Emulator', LucideIcons.monitor),
  backup('Backup & Restore', 'Backup', LucideIcons.hardDriveDownload);

  const ToolboxSection(this.label, this.shortLabel, this.icon);
  final String label, shortLabel;
  final IconData icon;
}

class ToolboxShell extends StatelessWidget {
  const ToolboxShell({
    required this.section,
    required this.onSelect,
    required this.child,
    required this.status,
    this.emulatorAvailable = true,
    this.disabledSections = const {},
    super.key,
  });
  final ToolboxSection section;
  final ValueChanged<ToolboxSection> onSelect;
  final Widget child;
  final String status;
  final bool emulatorAvailable;
  final Set<ToolboxSection> disabledSections;

  @override
  Widget build(BuildContext context) {
    final palette = ThemeProvider.of(context).palette;
    final sections = ToolboxSection.values.where(
      (section) => emulatorAvailable || section != ToolboxSection.emulator,
    );
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 850;
            final navigation = <Widget>[
              for (final destination in sections)
                _NavigationButton(
                  key: ValueKey('nav-${destination.name}'),
                  destination: destination,
                  selected: section == destination,
                  compact: !wide,
                  onPressed: disabledSections.contains(destination)
                      ? null
                      : () => onSelect(destination),
                ),
            ];
            if (!wide) {
              return Column(
                children: [
                  Expanded(child: child),
                  Container(
                    decoration: BoxDecoration(
                      color: palette.surface,
                      border: Border(top: BorderSide(color: palette.divider)),
                    ),
                    padding: const EdgeInsets.all(4),
                    child: Row(
                      children: [
                        for (final button in navigation)
                          Expanded(child: button),
                      ],
                    ),
                  ),
                ],
              );
            }
            return Row(
              children: [
                Container(
                  key: const ValueKey('toolbox-sidebar'),
                  width: 224,
                  decoration: BoxDecoration(
                    color: palette.surface,
                    border: Border(right: BorderSide(color: palette.divider)),
                  ),
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: ListView(
                          children: [
                            for (final button in navigation)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: button,
                              ),
                          ],
                        ),
                      ),
                      Card(
                        variant: SurfaceVariant.subtle,
                        header: const BodyText('Innioasis Y2'),
                        content: CaptionText(status),
                      ),
                    ],
                  ),
                ),
                Expanded(child: child),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _NavigationButton extends StatelessWidget {
  const _NavigationButton({
    super.key,
    required this.destination,
    required this.selected,
    required this.compact,
    required this.onPressed,
  });
  final ToolboxSection destination;
  final bool selected, compact;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final swatch = selected ? SemanticSwatch.primary : SemanticSwatch.neutral;
    final variant = selected ? SurfaceVariant.soft : SurfaceVariant.ghost;
    return Semantics(
      selected: selected,
      label: destination.label,
      child: compact
          ? Button.custom(
              onPressed: onPressed,
              style: ThemeProvider.of(context).widgets.button
                  .resolve(swatch, variant)
                  .copyWith(
                    height: 62,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 2,
                      vertical: 6,
                    ),
                  ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(destination.icon, size: 20),
                  const SizedBox(height: 5),
                  Text(
                    destination.shortLabel,
                    maxLines: 1,
                    softWrap: false,
                    style: const TextStyle(fontSize: 11, height: 1.2),
                  ),
                ],
              ),
            )
          : Button(
              onPressed: onPressed,
              swatch: swatch,
              variant: variant,
              leading: Icon(destination.icon, size: 18),
              center: Align(
                alignment: Alignment.centerLeft,
                child: Text(destination.label),
              ),
            ),
    );
  }
}

/// The page's single, pinned application bar on every window size.
class ToolboxAppBar extends StatelessWidget {
  const ToolboxAppBar({
    required this.child,
    this.scrolledUnder = false,
    super.key,
  });
  final Widget child;
  final bool scrolledUnder;

  @override
  Widget build(BuildContext context) {
    final palette = ThemeProvider.of(context).palette;
    return Semantics(
      container: true,
      header: true,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: EdgeInsets.symmetric(
          horizontal: MediaQuery.sizeOf(context).width < 600 ? 12 : 16,
          vertical: 8,
        ),
        decoration: BoxDecoration(
          color: scrolledUnder ? palette.surface : palette.background,
        ),
        child: child,
      ),
    );
  }
}

class ToolboxPageHeader extends StatelessWidget {
  const ToolboxPageHeader(
    this.title,
    this.description, {
    this.actions = const [],
    this.trailing,
    super.key,
  });
  final String title, description;
  final List<Widget> actions;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    spacing: 6,
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        spacing: 12,
        children: [
          Expanded(child: TitleText(title)),
          ?trailing,
        ],
      ),
      BodyText(description, emphasis: TextEmphasis.secondary),
      if (actions.isNotEmpty)
        Wrap(spacing: 8, runSpacing: 8, children: actions),
    ],
  );
}

/// A compact app-bar action with a named, square hit target.
class ToolboxHeaderAction extends StatelessWidget {
  const ToolboxHeaderAction({
    required this.label,
    required this.icon,
    this.onPressed,
    super.key,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => Tooltip(
    message: Text(label),
    child: Semantics(
      label: label,
      child: SizedBox.square(
        dimension: 36,
        child: Button.custom(
          style: ThemeProvider.of(context).widgets.button
              .resolve(SemanticSwatch.primary, SurfaceVariant.ghost)
              .copyWith(height: 36, padding: EdgeInsets.zero),
          onPressed: onPressed,
          child: Icon(icon, size: 16),
        ),
      ),
    ),
  );
}

/// Reflows cards using their available space, including inside a sidebar shell.
class ToolboxColumns extends StatelessWidget {
  const ToolboxColumns({
    required this.children,
    this.minimumWidth = 320,
    super.key,
  });
  final List<Widget> children;
  final double minimumWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = ((constraints.maxWidth + 16) / (minimumWidth + 16))
          .floor()
          .clamp(1, children.length);
      final width = (constraints.maxWidth - (columns - 1) * 16) / columns;
      return Wrap(
        spacing: 16,
        runSpacing: 16,
        children: [
          for (final child in children) SizedBox(width: width, child: child),
        ],
      );
    },
  );
}

class ToolboxInfoRows extends StatelessWidget {
  const ToolboxInfoRows(this.rows, {super.key});
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final (index, (name, value)) in rows.indexed) ...[
        if (index > 0) const Divider(),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 9),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: CaptionText(name)),
              const SizedBox(width: 12),
              Flexible(child: BodyText(value, textAlign: TextAlign.right)),
            ],
          ),
        ),
      ],
    ],
  );
}

class ToolboxMetrics extends StatelessWidget {
  const ToolboxMetrics(this.values, {super.key});
  final List<(String, String)> values;

  @override
  Widget build(BuildContext context) => ToolboxColumns(
    minimumWidth: 140,
    children: [
      for (final (name, value) in values)
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 7,
          children: [CaptionText(name), BodyText(value)],
        ),
    ],
  );
}

class DeviceSettingsPlaceholder extends StatelessWidget {
  const DeviceSettingsPlaceholder({super.key});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 24,
    children: [
      const Card(
        variant: SurfaceVariant.subtle,
        header: TitleText('Device settings are coming'),
        content: BodyText(
          'This page will use the same settings definitions as Tempo. You’ll be able to load settings from your player, review your edits, and apply them over Wi-Fi or Bluetooth.',
        ),
      ),
      ToolboxColumns(
        children: [
          for (final (icon, title, description) in const [
            (
              LucideIcons.volume2,
              'Sound & playback',
              'Volume, playback preferences, and audio output.',
            ),
            (
              LucideIcons.palette,
              'Appearance & controls',
              'Theme, wallpaper, interface size, and click wheel.',
            ),
            (
              LucideIcons.wifi,
              'Device & storage',
              'Connections, power, and where Tempo keeps its data.',
            ),
          ])
            Card(
              variant: SurfaceVariant.subtle,
              header: Row(
                children: [
                  Icon(icon, size: 18),
                  const SizedBox(width: 10),
                  Expanded(child: BodyText('$title [NYI]')),
                ],
              ),
              content: CaptionText(description),
            ),
        ],
      ),
    ],
  );
}

/// A decorative player thumbnail; the interactive emulator uses DeviceBody.
class PlayerThumbnail extends StatelessWidget {
  const PlayerThumbnail({super.key});
  @override
  Widget build(BuildContext context) => Container(
    width: 100,
    height: 164,
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: const Color(0xff34363b),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      children: [
        Container(
          height: 60,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(5),
            gradient: const LinearGradient(
              colors: [Color(0xff405766), Color(0xff1d2732)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: const Center(
            child: Icon(
              LucideIcons.audioLines,
              color: Color(0xffbae6fd),
              size: 28,
            ),
          ),
        ),
        const SizedBox(height: 14),
        Container(
          width: 60,
          height: 60,
          decoration: const BoxDecoration(
            color: Color(0xff202125),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Container(
              width: 24,
              height: 24,
              decoration: const BoxDecoration(
                color: Color(0xff393b40),
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
