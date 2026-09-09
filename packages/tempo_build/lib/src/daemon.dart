import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'context.dart';
import 'process.dart';
import 'daemon_native.dart';
import 'daemon_deploy.dart';
import 'test_runner.dart';

Future<int> daemonCommand(
  Repository repo,
  BuildConfig config,
  CommandRunner runner,
  List<String> args,
) async {
  final action = args.isEmpty ? 'build' : args.removeAt(0);
  if (args.contains('--help') || action == '--help') {
    stdout.writeln('daemon build [--target host|arm] [--dart-only] | test');
    return 0;
  }
  if (['deploy', 'check', 'clean'].contains(action)) {
    return daemonMaintenanceCommand(repo, config, runner, [action, ...args]);
  }
  if (!['build', 'test'].contains(action))
    throw BuildFailure('Expected daemon build or test', 2);
  final version = config
      .get('daemon.dart_version', fallback: '3.13.2')
      .toString();
  final override = Platform.environment['TEMPO_DAEMON_DART'];
  final dart =
      override ??
      (await FlutterSdk.discover(
        config,
        runner,
        version: config
            .get('daemon.toolchain_version', fallback: '3.47.2')
            .toString(),
      )).dart;
  final actual = await runner.capture(dart, ['--version']);
  if (!'${actual.stdout}${actual.stderr}'.contains(
    'Dart SDK version: $version ',
  )) {
    throw BuildFailure(
      'Daemon requires Dart $version; set TEMPO_DAEMON_DART to that SDK executable.',
    );
  }
  if (action == 'test') {
    await daemonHostCargo(repo, runner, ['test', '-p', 'tempod']);
    await daemonHostCargo(repo, runner, ['build', '-p', 'tempod', '--lib']);
    return runDaemonTests(
      repo,
      runner,
      dart,
      args,
      environment: {
        if (File(
          repo.path('build/rust/debug/libtempod_native.so'),
        ).existsSync())
          'TEMPOD_TEST_NATIVE_LIBRARY': repo.path(
            'build/rust/debug/libtempod_native.so',
          ),
      },
    );
  }
  var target = 'host';
  final index = args.indexOf('--target');
  if (index >= 0) {
    if (index + 1 >= args.length)
      throw BuildFailure('--target needs host or arm', 2);
    target = args[index + 1];
    args.removeRange(index, index + 2);
  }
  final dartOnly = args.remove('--dart-only');
  if (args.isNotEmpty || !['host', 'arm'].contains(target))
    throw BuildFailure(
      'Expected daemon build [--target host|arm] [--dart-only]',
      2,
    );
  final output = repo.path('build/os/daemon/$target');
  await runner.run(dart, [
    'build',
    'cli',
    '--packages=${repo.path('.dart_tool/package_config.json')}',
    '--target',
    'bin/tempod.dart',
    if (target == 'arm') ...['--target-os', 'linux', '--target-arch', 'arm'],
    '--output',
    output,
  ], workingDirectory: repo.path('daemon'));
  final bundle = p.join(output, 'bundle');
  final executable = File(p.join(bundle, 'bin/tempod'));
  final header = await executable.open();
  final bytes = await header.read(20);
  await header.close();
  if (target == 'arm' &&
      (bytes.length < 20 ||
          bytes[4] != 1 ||
          bytes[18] != 40 ||
          bytes[19] != 0)) {
    throw BuildFailure('Daemon compiler did not produce an ARM32 executable.');
  }
  if (!dartOnly) {
    final triple = 'armv7-unknown-linux-gnueabihf';
    if (target == 'host') {
      await daemonHostCargo(repo, runner, [
        'build',
        '-p',
        'tempod',
        '--lib',
        '--bin',
        'tempod',
        '--release',
      ]);
    } else {
      await Toolchain(repo, runner).run([
        'env',
        'CARGO_TARGET_DIR=${ArtifactPaths(repo).rust}',
        'TEMPOD_DEFAULT_SOCKET=${config.string('daemon.socket')}',
        'TEMPOD_DEFAULT_STATE_DIR=${config.string('daemon.state_dir')}',
        'TEMPOD_DEFAULT_INTERVAL=${config.get('daemon.sample_interval')}',
        'TEMPOD_DEFAULT_USER_UID=${config.get('user.uid')}',
        'CC_armv7_unknown_linux_gnueabihf=arm-linux-gnueabihf-gcc',
        'PKG_CONFIG_ALLOW_CROSS=1',
        'PKG_CONFIG_PATH_armv7_unknown_linux_gnueabihf=/usr/lib/arm-linux-gnueabihf/pkgconfig',
        'cargo',
        'build',
        '--release',
        '--target',
        triple,
        '-p',
        'tempod',
        '--lib',
        '--bin',
        'tempod',
      ]);
    }
    final native = repo.path(
      'build/rust/${target == 'arm' ? '$triple/' : ''}release/libtempod_native.so',
    );
    Directory(p.join(bundle, 'lib')).createSync(recursive: true);
    await File(native).copy(p.join(bundle, 'lib/libtempod_native.so'));
    await File(
      p.join(p.dirname(native), 'tempod'),
    ).copy(p.join(bundle, 'bin/tempod-native'));
  }
  final hashes = <String, String>{};
  for (final file in Directory(
    bundle,
  ).listSync(recursive: true).whereType<File>()) {
    if (p.basename(file.path) == 'manifest.json') continue;
    hashes[p.relative(file.path, from: bundle)] =
        (await sha256.bind(file.openRead()).first).toString();
  }
  File(p.join(bundle, 'manifest.json')).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({'dart': version, 'target': target, 'native': !dartOnly, 'files': hashes})}\n',
  );
  stdout.writeln('Daemon bundle: $bundle');
  return 0;
}
