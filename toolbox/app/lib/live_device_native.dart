import 'toolbox_ui.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:tomeui/tomeui.dart';
import 'package:toolbox_core/live_device.dart';
import 'package:toolbox_core/support_diagnostics.dart';

bool get livePlayerAvailable =>
    Platform.isLinux || Platform.isMacOS || Platform.isWindows;
Future<void> openLivePlayer(BuildContext context) =>
    Navigator.of(context).push<void>(
      PageRouteBuilder(pageBuilder: (_, _, _) => const LivePlayerPage()),
    );

/// Native desktop presentation; operations and transactional policy stay shared.
class LivePlayerPage extends StatefulWidget {
  const LivePlayerPage({
    super.key,
    this.transportFactory,
    this.chooseBundle,
    this.chooseReport,
    this.operationsFactory,
  });
  final DeviceTransport Function(String host, String user)? transportFactory;
  final Future<String?> Function()? chooseBundle;
  final Future<String?> Function()? chooseReport;
  final LiveDeviceOperations Function(
    DeviceTransport transport,
    void Function(String) progress,
  )?
  operationsFactory;
  @override
  State<LivePlayerPage> createState() => _LivePlayerPageState();
}

class _LivePlayerPageState extends State<LivePlayerPage> {
  final _scroll = ScrollController();
  final _host = TextEditingController(text: '10.42.0.1');
  final _user = TextEditingController(text: 'tempo');
  DeviceTransport? _transport;
  SupportDiagnostics? _diagnostics;
  bool _busy = false, _deploying = false, _cancelled = false;
  String _status =
      'Connect using an authorized SSH key. SSH must be installed on this computer.';
  String? _report;
  void _progress(String value) {
    if (mounted && !_cancelled) setState(() => _status = value);
  }

  DeviceTransport _connect() {
    final host = _host.text.trim(), user = _user.text.trim();
    return widget.transportFactory?.call(host, user) ??
        SshDeviceTransport(host: host, user: user);
  }

  LiveDeviceOperations _operations(DeviceTransport transport) =>
      widget.operationsFactory?.call(transport, _progress) ??
      LiveDeviceOperations(transport, onProgress: _progress);
  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _cancelled = false;
    });
    try {
      await operation();
    } catch (error) {
      if (mounted) {
        setState(
          () => _status = _cancelled && !_deploying ? 'Cancelled.' : '$error',
        );
      }
    } finally {
      try {
        await _transport?.cancel();
      } catch (_) {}
      _transport = null;
      _diagnostics = null;
      if (mounted) {
        setState(() {
          _busy = false;
          _deploying = false;
        });
      }
    }
  }

  Future<void> _check() => _run(() async {
    _transport = _connect();
    _progress('Checking SSH connection…');
    await _operations(_transport!).check();
    if (!_cancelled) {
      _progress('Connected to ${_user.text.trim()}@${_host.text.trim()}.');
    }
  });
  Future<void> _collect() => _run(() async {
    _transport = _connect();
    _diagnostics = SupportDiagnostics(_transport!, onProgress: _progress);
    final result = await _diagnostics!.collect();
    if (!mounted) return;
    setState(() {
      _report = const JsonEncoder.withIndent('  ').convert(result);
      _status = result['cancelled'] == true || _cancelled
          ? 'Diagnostics cancelled; partial report retained.'
          : result['healthy'] == true
          ? 'Support checks passed.'
          : 'Support report needs attention.';
    });
  });
  Future<void> _save() => _run(() async {
    final path =
        await (widget.chooseReport?.call() ??
            getSaveLocation(
              suggestedName: 'tempo-support.json',
            ).then((location) => location?.path));
    if (path == null || _cancelled) return;
    await File(path).writeAsString(_report!, flush: true);
    _progress('Support report saved.');
  });
  Future<void> _deploy() => _run(() async {
    final path =
        await (widget.chooseBundle?.call() ??
            getDirectoryPath(confirmButtonText: 'Choose built app bundle'));
    if (path == null || _cancelled || !mounted) return;
    final bundle = Directory(path);
    final release = File('$path/app.so').existsSync();
    if (!File('$path/AssetManifest.bin').existsSync() ||
        (!release && !File('$path/kernel_blob.bin').existsSync())) {
      throw const FormatException(
        'Choose a built Flutter asset bundle with AssetManifest.bin and app.so or kernel_blob.bin.',
      );
    }
    // Validate the complete selection locally before presenting a concrete review.
    final transport = _connect();
    _transport = transport;
    final operations = _operations(transport);
    await operations.deployBundle(
      bundle,
      release: release,
      destination: '/opt/tempo/flutter_assets',
      flutterPi: '/usr/local/bin/flutter-pi',
      engineDirectory: '/usr/lib',
      pixelFormat: 'RGB565',
      vmServicePort: 41200,
      dryRun: true,
    );
    if (_cancelled || !mounted) return;
    final confirmed = await showDialog<bool>(
      context,
      builder: (context) => Dialog(
        title: const TitleText('Deploy app bundle?'),
        content: BodyText(
          'Player: ${_user.text.trim()}@${_host.text.trim()}\nBundle: $path\nMode: ${release ? 'Release (app.so)' : 'Debug'}\nDestination: /opt/tempo/flutter_assets\n\nThis replaces the player app and restarts playback. The existing bundle is retained until startup is verified. Stop cancels forward deployment and waits for any necessary rollback.',
        ),
        actions: [
          Button(
            onPressed: () => Navigator.of(context).pop(false),
            center: const Text('Cancel deployment'),
          ),
          Button(
            onPressed: () => Navigator.of(context).pop(true),
            center: const Text('Deploy'),
          ),
        ],
      ),
    );
    if (confirmed != true || _cancelled || !mounted) {
      _progress('Deployment not started.');
      return;
    }
    setState(() => _deploying = true);
    await operations.deployBundle(
      bundle,
      release: release,
      destination: '/opt/tempo/flutter_assets',
      flutterPi: '/usr/local/bin/flutter-pi',
      engineDirectory: '/usr/lib',
      pixelFormat: 'RGB565',
      vmServicePort: 41200,
    );
    if (mounted) {
      setState(
        () => _status =
            'App deployed and startup verified.${_cancelled ? ' Stop completed after the safe transaction boundary.' : ''}',
      );
    }
  });
  Future<void> _cancel() async {
    if (!_busy || _cancelled) return;
    setState(() {
      _cancelled = true;
      _status = _deploying
          ? 'Cancelling; restoring the previous app if needed…'
          : 'Cancelling…';
    });
    try {
      if (_diagnostics != null) {
        await _diagnostics!.cancel();
      } else {
        await _transport?.cancel();
      }
    } catch (error) {
      if (mounted) setState(() => _status = 'Cancellation failed: $error');
    }
  }

  @override
  void dispose() {
    _cancelled = true;
    // Shared deployment owns an independent rollback/cleanup transport.
    unawaited(_transport?.cancel().catchError((Object _) {}) ?? Future.value());
    _scroll.dispose();
    _host.dispose();
    _user.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            ListenableBuilder(
              listenable: _scroll,
              builder: (context, _) => ToolboxAppBar(
                scrolledUnder: _scroll.hasClients && _scroll.offset > 0,
                child: ToolboxPageHeader(
                  'Live Player',
                  'Connect to and inspect your running player.',
                  trailing: ToolboxHeaderAction(
                    label: 'Back to Toolbox',
                    icon: LucideIcons.arrowLeft,
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  ),
                ),
              ),
            ),
            Expanded(
              child: ListView(
                controller: _scroll,
                padding: const EdgeInsets.all(16),
                children: [
                  TextField(
                    controller: _host,
                    label: const Text('Host'),
                    enabled: !_busy,
                  ),
                  TextField(
                    controller: _user,
                    label: const Text('Account'),
                    enabled: !_busy,
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      Button(
                        onPressed: _busy ? null : _check,
                        center: const Text('Check connection'),
                      ),
                      Button(
                        onPressed: _busy ? null : _collect,
                        center: const Text('Collect support report'),
                      ),
                      Button(
                        onPressed: _busy ? null : _deploy,
                        center: const Text('Choose app bundle'),
                      ),
                      Button(
                        onPressed: _busy || _report == null ? null : _save,
                        center: const Text('Save report'),
                      ),
                      if (_busy)
                        Button(
                          onPressed: _cancelled ? null : _cancel,
                          center: const Text('Stop'),
                        ),
                      Button(
                        onPressed: _busy
                            ? null
                            : () => Navigator.of(context).pop(),
                        center: const Text('Back to Toolbox'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(_status, key: const ValueKey('live-status')),
                  if (_report != null) ...[
                    const SizedBox(height: 16),
                    Text(_report!, key: const ValueKey('live-report')),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
