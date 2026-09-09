import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:toolbox_core/toolbox_core.dart';
import 'package:toolbox_core/live_device.dart';
import 'package:toolbox_core/support_diagnostics.dart';
import 'package:tempo_build/tempo_build.dart';

import '../lib/command_help.dart';

const help = '''Tempo Toolbox
Usage: toolbox [--json] <command>
  device list|info       Discover and probe a connected player
  partitions            Observe the vendor MBR/EBR address convention
  fetch NAME OUTPUT     Read one anchored vendor or boot partition
  backup OUTPUT.gz      Back up eMMC; --resume DIRECTORY reuses saved chunks
  install FILE          Validate and install a .y2-firmware package
  inspect FILE          Validate firmware without a device
  inspect-raw NAME FILE  Validate BOOTIMG, LOGO or wrapped BOOT1
  install-raw NAME FILE SAFETY  Guarded BOOTIMG/LOGO; --dry-run available
  doctor                Check bundled USB engine and resources
  diagnose              Read-only support report from a running player
                        [--host ADDRESS] [--user USER]; --usb probes boot mode
  restore INPUT         Restore gzip backup or legacy mtkclient folder
  dev                   Developer tools (see toolbox dev --help)
Install requires --yes; preloader writes additionally require --allow-preloader.
Use --loader DA.img to override the agent; --preloader FILE supplies Y2 BROM EMI.
Progress goes to stderr; --json writes one final JSON result to stdout.''';

Future<void> main(List<String> arguments) async {
  final args = [...arguments];
  final json = args.remove('--json');
  if (args.isEmpty || args.first == '--help' || args.first == '-h') {
    stdout.writeln(help);
    return;
  }
  var operations = ToolboxOperations();
  StreamSubscription<ProcessSignal>? interrupt;
  void report(EngineEvent event) => stdout.writeln(
    json
        ? jsonEncode(event)
        : event['message'] ?? const JsonEncoder.withIndent('  ').convert(event),
  );
  void progress(EngineEvent event) => stderr.writeln(
    json
        ? jsonEncode(event)
        : event['message'] ??
              '${event['event']}: ${event['completed'] ?? ''}/${event['total'] ?? ''}',
  );
  try {
    final command = args.removeAt(0);
    if (command == 'dev') {
      exitCode = await runDeveloperCommand(args);
      return;
    }
    if (args.contains('--help') || args.contains('-h')) {
      final usage = endUserHelp[command];
      if (usage == null)
        throw ArgumentError('Unknown command: $command. Use toolbox --help.');
      stdout.writeln(usage);
      return;
    }
    String? option(String name) {
      final index = args.indexOf(name);
      if (index < 0) return null;
      if (index + 1 >= args.length)
        throw ArgumentError('$name requires a value.');
      final value = args.removeAt(index + 1);
      args.removeAt(index);
      return value;
    }

    if (command == 'diagnose' && !args.contains('--usb')) {
      final host = option('--host') ?? '10.42.0.1';
      final user = option('--user') ?? 'tempo';
      if (args.isNotEmpty)
        throw ArgumentError('Unexpected diagnose arguments: ${args.join(' ')}');
      final diagnostics = SupportDiagnostics(
        SshDeviceTransport(host: host, user: user),
        onProgress: (message) =>
            progress({'event': 'progress', 'message': message}),
      );
      interrupt = ProcessSignal.sigint.watch().listen(
        (_) => unawaited(diagnostics.cancel()),
      );
      try {
        final result = await diagnostics.collect();
        report(result);
        exitCode = result['cancelled'] == true
            ? 130
            : result['healthy'] == true
            ? 0
            : 1;
      } finally {
        await diagnostics.cancel();
      }
      return;
    }
    operations = ToolboxOperations(
      agent: option('--loader'),
      preloader: option('--preloader'),
    );
    final status = await operations.initialize();
    if (command == 'doctor') {
      if (args.isNotEmpty) throw ArgumentError('doctor accepts no arguments.');
      report(status);
      exitCode = status['supported'] == true ? 0 : 69;
      return;
    }
    if (status['engine_available'] != true)
      throw StateError(status['message'] as String);
    interrupt = ProcessSignal.sigint.watch().listen((_) {
      unawaited(operations.cancel());
    });
    EngineEvent result;
    switch (command) {
      case 'device':
        if (args.length != 1 || !['list', 'info'].contains(args.single))
          throw ArgumentError('Usage: toolbox device list|info');
        result = await operations.probe(
          seconds: args.single == 'list' ? 1 : 30,
          onEvent: progress,
        );
      case 'diagnose':
        args.remove('--usb');
        if (args.isNotEmpty)
          throw ArgumentError('Usage: toolbox diagnose --usb');
        result = await operations.probe(onEvent: progress);
      case 'inspect-raw':
        if (args.length != 2)
          throw ArgumentError(
            'Usage: toolbox inspect-raw BOOTIMG|LOGO|BOOT1 FILE',
          );
        result = await operations.inspectRaw(args[0], args[1]);
      case 'install-raw':
        final dryRun = args.remove('--dry-run');
        final yes = args.remove('--yes');
        final forceBootHeader = args.remove('--force-boot-header');
        if (args.length != 3 || (!dryRun && !yes))
          throw ArgumentError(
            'Usage: toolbox install-raw BOOTIMG|LOGO FILE SAFETY-BACKUP --dry-run|--yes [--force-boot-header]',
          );
        result = await operations.installRaw(
          args[0],
          args[1],
          args[2],
          dryRun: dryRun,
          forceBootHeader: forceBootHeader,
          onEvent: progress,
        );
      case 'inspect':
        if (args.length != 1)
          throw ArgumentError('Usage: toolbox inspect FILE');
        result = await operations.inspectFirmware(args.single);
      case 'partitions':
        if (args.isNotEmpty)
          throw ArgumentError('partitions accepts no arguments.');
        result = await operations.partitions(onEvent: progress);
      case 'fetch':
        if (args.length != 2)
          throw ArgumentError('Usage: toolbox fetch PARTITION OUTPUT');
        result = await operations.fetch(args[0], args[1], onEvent: progress);
      case 'backup':
        final resumeInput = option('--resume');
        if (args.length != 1)
          throw ArgumentError(
            'Usage: toolbox backup OUTPUT.gz [--resume LEGACY_DIRECTORY]',
          );
        result = resumeInput == null
            ? await operations.backup(args.single, onEvent: progress)
            : await operations.resumeBackup(
                resumeInput,
                args.single,
                onEvent: progress,
              );
      case 'restore':
        final yes = args.remove('--yes');
        final preloader = args.remove('--allow-preloader');
        final resume = args.remove('--resume');
        if (args.length != 1 || !yes)
          throw ArgumentError(
            'Usage: toolbox restore BACKUP.gz|DIRECTORY --yes [--allow-preloader] [--resume]',
          );
        result = await operations.restore(
          args.single,
          allowPreloader: preloader,
          resume: resume,
          onEvent: progress,
        );
      case 'install':
        final yes = args.remove('--yes');
        final preloader = args.remove('--allow-preloader');
        final resume = args.remove('--resume');
        if (args.length != 1 || !yes)
          throw ArgumentError(
            'Usage: toolbox install FILE --yes [--allow-preloader] [--resume]',
          );
        result = await operations.install(
          args.single,
          allowPreloader: preloader,
          resume: resume,
          onEvent: progress,
        );
      default:
        throw ArgumentError('Unknown command: $command. Use toolbox --help.');
    }
    report(result);
    exitCode = result['event'] == 'cancelled'
        ? 130
        : result['event'] == 'error'
        ? 1
        : 0;
  } on ArgumentError catch (error) {
    report({'event': 'error', 'message': error.message.toString()});
    exitCode = 64;
  } catch (error) {
    report({'event': 'error', 'message': '$error'});
    exitCode = 1;
  } finally {
    await interrupt?.cancel();
    await operations.cancel();
  }
}
