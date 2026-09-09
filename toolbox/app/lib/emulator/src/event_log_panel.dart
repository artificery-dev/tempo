import 'dart:convert';
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'package:tomeui/tomeui.dart';
import 'package:tempo_logger/tempo_logger.dart';
import 'event_log.dart';

/// Shared bottom drawer; opening it does not resize the page underneath.
class EmulatorLogDock extends StatefulWidget {
  const EmulatorLogDock({required this.log, required this.child, super.key});
  final EmulatorEventLog log;
  final Widget child;
  static const barHeight = 40.0;
  @override
  State<EmulatorLogDock> createState() => _EmulatorLogDockState();
}

class _EmulatorLogDockState extends State<EmulatorLogDock> {
  bool _open = false;
  bool _sourcesOpen = false;
  String? _copyStatus;
  Timer? _copyTimer;

  void _showCopyStatus(String status) {
    if (!mounted) return;
    _copyTimer?.cancel();
    setState(() => _copyStatus = status);
    _copyTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copyStatus = null);
    });
  }

  @override
  void dispose() {
    _copyTimer?.cancel();
    super.dispose();
  }

  final _excludedSources = <String>{};
  final _expanded = <LogRecord>{};
  bool _includes(LogRecord record) =>
      !_excludedSources.contains(EmulatorEventLog.sourceOf(record));
  Future<void> _copy(String value) async {
    try {
      await Clipboard.setData(ClipboardData(text: value));
      _showCopyStatus('Copied');
    } catch (_) {
      _showCopyStatus('Copy failed');
    }
  }

  Widget _copyButton(
    String key,
    String label,
    IconData icon,
    VoidCallback? action,
  ) => Tooltip(
    message: Text(label),
    child: SizedBox.square(
      dimension: 36,
      child: Button.custom(
        key: ValueKey(key),
        style: ThemeProvider.of(context).widgets.button
            .resolve(SemanticSwatch.neutral, SurfaceVariant.ghost)
            .copyWith(height: 36, padding: EdgeInsets.zero),
        onPressed: action,
        child: Semantics(label: label, child: Icon(icon, size: 16)),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => ListenableBuilder(
      listenable: widget.log,
      builder: (context, _) {
        final matching = widget.log.entries.where(_includes).toList();
        _expanded.retainAll(widget.log.entries);
        return Stack(
          children: [
            Positioned.fill(
              bottom: EmulatorLogDock.barHeight,
              child: widget.child,
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: ColoredBox(
                color: ThemeProvider.of(context).palette.surface,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      height: EmulatorLogDock.barHeight,
                      child: Row(
                        children: [
                          Expanded(
                            child: Semantics(
                              expanded: _open,
                              child: Button(
                                key: const ValueKey('emulator-log-toggle'),
                                variant: SurfaceVariant.ghost,
                                swatch: SemanticSwatch.neutral,
                                onPressed: () => setState(() {
                                  _open = !_open;
                                  _sourcesOpen = false;
                                }),
                                leading: const Icon(LucideIcons.list, size: 16),
                                center: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text('Logs (${widget.log.length})'),
                                ),
                                trailing: AnimatedRotation(
                                  turns: _open ? .5 : 0,
                                  duration: const Duration(milliseconds: 200),
                                  child: const Icon(
                                    LucideIcons.chevronUp,
                                    size: 16,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    ClipRect(
                      child: AnimatedAlign(
                        alignment: Alignment.bottomCenter,
                        heightFactor: _open ? 1 : 0,
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeInOut,
                        child: ExcludeFocus(
                          excluding: !_open,
                          child: ExcludeSemantics(
                            excluding: !_open,
                            child: IgnorePointer(
                              ignoring: !_open,
                              child: SizedBox(
                                height: math.max(
                                  0,
                                  math.min(
                                    360,
                                    constraints.maxHeight * .6 - 40,
                                  ),
                                ),
                                child: _contents(matching.reversed.toList()),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    ),
  );

  Widget _sourceDropdown() => Popover(
    open: _sourcesOpen,
    onDismiss: () => setState(() => _sourcesOpen = false),
    side: PopoverSide.top,
    anchor: Button(
      key: const ValueKey('log-source-dropdown'),
      variant: SurfaceVariant.ghost,
      center: Text(
        _excludedSources.isEmpty
            ? 'Source: All'
            : 'Source: ${widget.log.sources.where((source) => !_excludedSources.contains(source)).length}',
      ),
      trailing: const Icon(LucideIcons.chevronDown, size: 14),
      onPressed: () => setState(() => _sourcesOpen = !_sourcesOpen),
    ),
    content: (context, anchor) => SizedBox(
      width: 220,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            if (widget.log.sources.isEmpty)
              const CaptionText('No sources yet.'),
            for (final source in widget.log.sources)
              Checkbox(
                key: ValueKey('log-source-$source'),
                label: Text(source),
                value: !_excludedSources.contains(source),
                onChanged: (selected) => setState(() {
                  selected
                      ? _excludedSources.remove(source)
                      : _excludedSources.add(source);
                  _copyStatus = null;
                }),
              ),
          ],
        ),
      ),
    ),
  );

  Widget _monoSurface(Widget child) {
    final theme = ThemeProvider.of(context);
    final mono = const Typography.recursive().code.copyWith(fontSize: 12);
    return ThemeProvider(
      theme: theme.copyWith(
        typography: theme.typography.copyWith(
          body: mono,
          bodySmall: mono,
          label: mono,
          caption: mono,
          code: mono,
        ),
      ),
      child: DefaultTextStyle(
        style: mono.copyWith(color: theme.palette.text),
        child: child,
      ),
    );
  }

  Color _levelColor(LogLevel level) {
    final palette = ThemeProvider.of(context).palette;
    final dark = palette.brightness == Brightness.dark;
    final swatch = switch (level) {
      LogLevel.trace => palette.neutral,
      LogLevel.debug => palette.accent,
      LogLevel.info => palette.success,
      LogLevel.warning => palette.warning,
      LogLevel.error => palette.error,
    };
    return dark ? swatch.s400 : swatch.s700;
  }

  Widget _columns({
    required Widget toggle,
    required Widget timestamp,
    required Widget tag,
    required Widget level,
    required Widget message,
    required Widget copy,
  }) {
    final line = ThemeProvider.of(context).palette.divider;
    Widget cell(Widget child) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Align(alignment: Alignment.centerLeft, child: child),
    );
    Widget divider() => SizedBox(width: 1, child: ColoredBox(color: line));
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: line)),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: 36, child: Center(child: toggle)),
            divider(),
            SizedBox(width: 256, child: cell(timestamp)),
            divider(),
            SizedBox(width: 200, child: cell(tag)),
            divider(),
            SizedBox(width: 90, child: cell(level)),
            divider(),
            Expanded(child: cell(message)),
            divider(),
            SizedBox(width: 36, child: Center(child: copy)),
          ],
        ),
      ),
    );
  }

  Widget _contents(List<LogRecord> entries) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      DecoratedBox(
        key: const ValueKey('logs-toolbar'),
        decoration: BoxDecoration(
          color: ThemeProvider.of(context).palette.background,
          border: Border.symmetric(
            horizontal: BorderSide(
              color: ThemeProvider.of(context).palette.divider,
            ),
          ),
        ),
        child: SizedBox(
          height: 44,
          child: Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _sourceDropdown(),
                ),
              ),
              SizedBox(
                width: 84,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: _copyStatus == null
                      ? const SizedBox.shrink()
                      : Semantics(
                          key: ValueKey(_copyStatus),
                          liveRegion: true,
                          child: Text(_copyStatus!),
                        ),
                ),
              ),
              _copyButton(
                'emulator-log-copy-text',
                'Copy text',
                LucideIcons.copy,
                entries.isEmpty
                    ? null
                    : () => _copy(
                        entries.reversed.map(formatTextLogRecord).join('\n\n'),
                      ),
              ),
              _copyButton(
                'emulator-log-copy-json',
                'Copy JSONL',
                LucideIcons.braces,
                entries.isEmpty
                    ? null
                    : () => _copy(
                        entries.reversed.map(formatJsonLogRecord).join('\n'),
                      ),
              ),
              _copyButton(
                'logs-clear',
                'Clear logs',
                LucideIcons.trash2,
                widget.log.length == 0
                    ? null
                    : () {
                        _copyTimer?.cancel();
                        setState(() {
                          _copyStatus = null;
                          _expanded.clear();
                          _excludedSources.clear();
                          _sourcesOpen = false;
                        });
                        widget.log.clear();
                      },
              ),
              const SizedBox(width: 12),
            ],
          ),
        ),
      ),
      Expanded(
        child: _monoSurface(
          entries.isEmpty
              ? Center(
                  child: BodyText(
                    widget.log.length == 0
                        ? 'No logs yet.'
                        : 'No logs from selected sources.',
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) => SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: math.max(960, constraints.maxWidth),
                      child: Column(
                        children: [
                          Padding(
                            padding: EdgeInsets.zero,
                            child: _columns(
                              toggle: const SizedBox(),
                              timestamp: const CaptionText('Timestamp'),
                              tag: const CaptionText('Tag'),
                              level: const CaptionText('Level'),
                              message: const CaptionText('Message'),
                              copy: const SizedBox(),
                            ),
                          ),
                          Expanded(
                            child: ListView.builder(
                              key: const ValueKey('emulator-log-entries'),
                              itemCount: entries.length,
                              itemBuilder: (context, index) {
                                final entry = entries[index];
                                final expanded = _expanded.contains(entry);
                                return Column(
                                  key: ObjectKey(entry),
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    _columns(
                                      toggle: Semantics(
                                        expanded: expanded,
                                        child: _copyButton(
                                          'log-expand-$index',
                                          expanded
                                              ? 'Hide metadata'
                                              : 'Show metadata',
                                          expanded
                                              ? LucideIcons.chevronDown
                                              : LucideIcons.chevronRight,
                                          entry.hasMetadata
                                              ? () => setState(() {
                                                  expanded
                                                      ? _expanded.remove(entry)
                                                      : _expanded.add(entry);
                                                })
                                              : null,
                                        ),
                                      ),
                                      timestamp: Text(
                                        entry.timestamp
                                            .toLocal()
                                            .toIso8601String(),
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                      tag: Text(entry.tag),
                                      level: Text(
                                        entry.level.name.toUpperCase(),
                                        style: TextStyle(
                                          color: _levelColor(entry.level),
                                        ),
                                      ),
                                      message: Text(entry.message),
                                      copy: _copyButton(
                                        'log-copy-$index',
                                        'Copy record as JSON',
                                        LucideIcons.copy,
                                        () => _copy(formatJsonLogRecord(entry)),
                                      ),
                                    ),
                                    AnimatedSize(
                                      duration: const Duration(
                                        milliseconds: 180,
                                      ),
                                      alignment: Alignment.topLeft,
                                      child: expanded
                                          ? Padding(
                                              padding:
                                                  const EdgeInsets.fromLTRB(
                                                    36,
                                                    8,
                                                    16,
                                                    12,
                                                  ),
                                              child: Text(
                                                const JsonEncoder.withIndent(
                                                  '  ',
                                                ).convert(entry.metadata),
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                ),
                                              ),
                                            )
                                          : const SizedBox(
                                              width: double.infinity,
                                            ),
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
        ),
      ),
    ],
  );
}
