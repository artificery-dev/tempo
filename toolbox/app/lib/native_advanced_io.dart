import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:tomeui/tomeui.dart';

import 'engine_native.dart';
import 'workflow_layout.dart';

/// Native-only file configuration and read-only DA operations.
class NativeAdvanced extends StatefulWidget {
  const NativeAdvanced({
    super.key,
    required this.engine,
    required this.busy,
    required this.onBusy,
    this.showConnectionFiles = true,
    this.showDiagnostics = false,
    this.onExit,
  });
  final VoidCallback? onExit;
  final bool showConnectionFiles, showDiagnostics;
  final UsbEngine engine;
  final bool busy;
  final ValueChanged<bool> onBusy;
  @override
  State<NativeAdvanced> createState() => _NativeAdvancedState();
}

class _NativeAdvancedState extends State<NativeAdvanced> {
  String _status = '';
  bool _running = false, _stopping = false;
  bool _finished = false;

  Future<void> _stop() async {
    if (!_running || _stopping) return;
    setState(() {
      _stopping = true;
      _status = 'Stopping diagnostics…';
    });
    try {
      await widget.engine.stop();
    } catch (error) {
      if (mounted) {
        setState(() => _status = 'Could not stop diagnostics: $error');
      }
    } finally {
      if (mounted) {
        setState(() {
          _stopping = false;
          _running = false;
          _finished = true;
        });
        widget.onBusy(false);
      }
    }
  }

  List<String> _partitions = [];

  Future<void> _pick({required bool preloader}) async {
    final file = await openFile(
      confirmButtonText: preloader
          ? 'Use preloader for BROM EMI'
          : 'Use download agent',
    );
    if (file == null || !mounted) return;
    setState(() {
      widget.engine.configure(
        agent: preloader ? widget.engine.agent : file.path,
        preloader: preloader ? file.path : widget.engine.preloader,
      );
    });
  }

  Future<void> _read([String? partition]) async {
    if (_running || _stopping) return;
    setState(() {
      _running = true;
      _finished = false;
    });
    widget.onBusy(true);
    try {
      String? output;
      if (partition != null) {
        output = (await getSaveLocation(suggestedName: '$partition.img'))?.path;
        if (output == null) return;
      }
      if (!mounted || !_running || _stopping) return;
      setState(
        () =>
            _status = 'Connect the powered-off Y2. Waiting up to 300 seconds…',
      );
      final result = partition == null
          ? await widget.engine.partitions()
          : await widget.engine.fetch(partition, output!);
      if (!mounted) return;
      final data = result['partition'];
      setState(() {
        if (result['event'] == 'result' && data is Map) {
          final entries = data['partitions'];
          if (entries is List) {
            _partitions = [
              'boot1',
              'boot2',
              ...entries.whereType<Map>().map((p) => p['name'].toString()),
            ];
          }
          _status = const JsonEncoder.withIndent('  ').convert(data);
        } else {
          _status = result['message']?.toString() ?? 'Operation stopped.';
        }
      });
    } catch (error) {
      if (mounted) setState(() => _status = '$error');
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
          _finished = true;
        });
        if (!_stopping) widget.onBusy(false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 16,
    children: [
      if (widget.showDiagnostics) ...[
        WorkflowStepper(
          labels: const ['Connect', 'Read', 'Result'],
          icons: const [
            LucideIcons.cable,
            LucideIcons.listTree,
            LucideIcons.circleCheck,
          ],
          step: _finished
              ? 2
              : _running
              ? 1
              : 0,
        ),
        if (widget.onExit != null)
          Align(
            alignment: Alignment.centerLeft,
            child: Button(
              onPressed: _running || _stopping ? null : widget.onExit,
              variant: SurfaceVariant.ghost,
              leading: const Icon(LucideIcons.arrowLeft),
              center: const Text('Back'),
            ),
          ),
      ],
      if (widget.showConnectionFiles)
        Card(
          variant: SurfaceVariant.subtle,
          header: const TitleText('Connection files'),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: [
              const BodyText('Download agent'),
              const CaptionText(
                'The RAM-loaded agent used to communicate with the Y2 storage.',
              ),
              Text(widget.engine.agent ?? 'Bundled Y2 agent'),
              Align(
                alignment: Alignment.centerLeft,
                child: Button(
                  onPressed: widget.busy ? null : () => _pick(preloader: false),
                  variant: SurfaceVariant.soft,
                  leading: const Icon(LucideIcons.fileCode),
                  center: const Text('Choose download agent'),
                ),
              ),
              const Divider(),
              const BodyText('BROM memory setup'),
              const CaptionText(
                'Use a preloader file for memory initialization. This does not enable writing the preloader.',
              ),
              Text(widget.engine.preloader ?? 'No custom preloader'),
              Align(
                alignment: Alignment.centerLeft,
                child: Button(
                  onPressed: widget.busy ? null : () => _pick(preloader: true),
                  variant: SurfaceVariant.soft,
                  leading: const Icon(LucideIcons.cpu),
                  center: const Text('Choose BROM preloader'),
                ),
              ),
            ],
          ),
          footer: Button(
            onPressed: widget.busy
                ? null
                : () => setState(() => widget.engine.configure()),
            variant: SurfaceVariant.ghost,
            leading: const Icon(LucideIcons.rotateCcw),
            center: const Text('Reset connection files'),
          ),
        ),
      if (widget.showDiagnostics)
        Card(
          variant: SurfaceVariant.subtle,
          header: const TitleText('Read-only diagnostics'),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: [
              const CaptionText(
                'Read the partition map or export a single partition. Each operation reconnects to the powered-off Y2. Existing files are never overwritten.',
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: Button(
                  onPressed: widget.busy ? null : () => _read(),
                  variant: SurfaceVariant.soft,
                  leading: const Icon(LucideIcons.listTree),
                  center: const Text('Connect and read partition map'),
                ),
              ),
              if (_running || _stopping)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Button(
                    key: const ValueKey('diagnostics-stop'),
                    onPressed: _stopping ? null : _stop,
                    leading: _stopping
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: Progress.spinner(),
                          )
                        : const Icon(LucideIcons.square),
                    center: Text(_stopping ? 'Stopping…' : 'Stop'),
                  ),
                ),
              if (_partitions.isNotEmpty) ...[
                const Divider(),
                const BodyText('Export a partition'),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final name in _partitions.toSet())
                      Button(
                        onPressed: widget.busy ? null : () => _read(name),
                        variant: SurfaceVariant.soft,
                        leading: const Icon(LucideIcons.download),
                        center: Text(name),
                      ),
                  ],
                ),
              ],
              if (_status.isNotEmpty) ...[const Divider(), Text(_status)],
            ],
          ),
        ),
    ],
  );
}
