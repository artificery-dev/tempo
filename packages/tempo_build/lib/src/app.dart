import 'dart:io';
import 'dart:async';
import 'package:path/path.dart' as p;
import 'context.dart';
import 'process.dart';
import 'device.dart' show deviceTransport;
import 'package:toolbox_core/live_device.dart';

Future<int> appCommand(
  Repository repo,
  BuildConfig config,
  CommandRunner runner,
  String action,
  List<String> args,
) async {
  final paths = ArtifactPaths(repo);
  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln(
      'app build [--release] | deploy [--release] [--dry-run] | attach [--dry-run] | clean',
    );
    return 0;
  }
  final allowed = switch (action) {
    'build' => ['--release'],
    'deploy' => ['--release', '--dry-run'],
    'attach' => ['--dry-run'],
    'clean' => <String>[],
    _ => throw BuildFailure('Unknown app action: $action', 2),
  };
  for (final arg in args) {
    if (!allowed.contains(arg))
      throw BuildFailure('Unexpected app $action argument: $arg', 2);
  }
  if (action == 'clean') {
    // Runtime engine/embedder artifacts are independent of the Flutter bundle.
    for (final entry in [paths.bundle, p.join(paths.app, 'tempo.aot.dill')]) {
      if (FileSystemEntity.isDirectorySync(entry)) {
        Directory(entry).deleteSync(recursive: true);
      } else if (File(entry).existsSync()) {
        File(entry).deleteSync();
      }
    }
    return 0;
  }
  if (action == 'deploy')
    return deployApp(
      repo,
      config,
      runner,
      release: args.contains('--release'),
      dryRun: args.contains('--dry-run'),
    );
  if (action == 'attach') {
    final host =
        Platform.environment['TEMPO_DEVICE_HOST'] ??
        config.string('networking.usb_gadget.address').split('/').first;
    final url = Uri(
      scheme: 'http',
      host: host,
      port: int.parse(config.string('flutter.vm_service_port')),
      path: '/',
    ).toString();
    if (args.contains('--dry-run')) {
      stdout.writeln(
        'flutter attach --debug-url $url (in ${repo.path('app')})',
      );
      return 0;
    }
    final sdk = await FlutterSdk.discover(config, runner);
    return runner.run(sdk.flutter, [
      'attach',
      '--debug-url',
      url,
    ], workingDirectory: repo.path('app'));
  }
  final sdk = await FlutterSdk.discover(config, runner);
  final release = args.contains('--release');
  final engine = repo.existing(
    'build/app/engine-binaries/arm',
    'build/engine-binaries/arm',
  );
  final gen = p.join(engine, 'gen_snapshot_linux_x64_release');
  if (release) {
    if (!Platform.isLinux)
      throw BuildFailure(
        'The pinned ARMv7 gen_snapshot is a Linux x64 executable; run this build on Linux.',
      );
    if (!File(gen).existsSync())
      throw BuildFailure('Missing $gen; run toolbox dev app flutter-pi engine');
    final want = File(p.join(sdk.root, 'bin/internal/engine.version'));
    final have = File(p.join(engine, 'flutter.version'));
    if (!want.existsSync() ||
        !have.existsSync() ||
        want.readAsStringSync().trim() != have.readAsStringSync().trim())
      throw BuildFailure(
        'Engine and SDK version mismatch; re-fetch the configured engine before compiling AOT.',
      );
  }
  Directory(paths.app).createSync(recursive: true);
  await runner.run(sdk.flutter, [
    'pub',
    'get',
  ], workingDirectory: repo.path('app'));
  await runner.run(sdk.flutter, [
    'build',
    'bundle',
    // Tempo runs under flutter-pi on Linux. Flutter's default bundle target
    // is android-arm, which makes it run every dependency's build hook for
    // Android and demand an NDK. The bundle itself is target-independent
    // (its Dart code becomes app.so through the pinned gen_snapshot below),
    // so the target only picks which native assets come along, and the
    // device uses none of them: it preloads the system SQLite.
    '--target-platform=linux-x64',
    '--asset-dir=${paths.bundle}',
  ], workingDirectory: repo.path('app'));
  final snapshot = File(p.join(paths.bundle, 'app.so'));
  // Remove stale release output before compiling too, so a failed AOT build
  // cannot leave yesterday's executable beside today's assets.
  if (snapshot.existsSync()) snapshot.deleteSync();
  if (release) {
    final dill = p.join(paths.app, 'tempo.aot.dill');
    await runner.run(
      p.join(sdk.root, 'bin/cache/dart-sdk/bin/dartaotruntime'),
      [
        p.join(
          sdk.root,
          'bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot',
        ),
        '--sdk-root',
        '${p.join(sdk.root, 'bin/cache/artifacts/engine/common/flutter_patched_sdk_product')}/',
        '--target=flutter',
        '--aot',
        '--tfa',
        '-Ddart.vm.product=true',
        '--packages',
        repo.path('.dart_tool/package_config.json'),
        '--output-dill',
        dill,
        'package:tempo/main.dart',
      ],
      workingDirectory: repo.path('app'),
    );
    await runner.run(gen, [
      '--deterministic',
      '--snapshot_kind=app-aot-elf',
      '--elf=${snapshot.path}',
      '--strip',
      dill,
    ], workingDirectory: repo.path('app'));
  }
  stdout.writeln(
    'Bundle: ${paths.bundle} (${release ? 'release ARMv7' : 'debug'})',
  );
  return 0;
}

Future<int> deployApp(
  Repository repo,
  BuildConfig config,
  CommandRunner runner, {
  required bool release,
  required bool dryRun,
}) async {
  final transport = deviceTransport(config);
  final signals = <StreamSubscription<ProcessSignal>>[];
  int? interrupted;
  if (!Platform.isWindows) {
    for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
      signals.add(
        signal.watch().listen((_) {
          interrupted = signal == ProcessSignal.sigint ? 130 : 143;
          unawaited(transport.cancel());
        }),
      );
    }
  }
  try {
    await LiveDeviceOperations(
      transport,
      onProgress: stdout.writeln,
    ).deployBundle(
      Directory(ArtifactPaths(repo).bundle),
      release: release,
      dryRun: dryRun,
      destination: config.string('flutter.install.bundle'),
      flutterPi: config.string('flutter.install.flutter_pi'),
      engineDirectory: config.string('flutter.install.engine_dir'),
      pixelFormat: config.string('flutter.pixel_format'),
      vmServicePort: int.parse(config.string('flutter.vm_service_port')),
    );
    return 0;
  } catch (error) {
    if (interrupted != null) {
      stderr.writeln(error);
      return interrupted!;
    }
    rethrow;
  } finally {
    for (final subscription in signals) {
      await subscription.cancel();
    }
    await transport.cancel();
  }
}
