import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'context.dart';
import 'process.dart';
import 'app.dart';
import 'embedder.dart';
import 'daemon.dart';
import 'cadence.dart';
import 'toolbox.dart';
import 'kernel.dart';
import 'rootfs.dart';
import 'bluetooth.dart';
import 'splash.dart';
import 'distribution.dart';
import 'recovery.dart';
import 'device.dart';
import 'system_runtime.dart';
import 'emulator.dart';
import 'diagnostics.dart';
import 'developer_help.dart';
import 'bootstrap.dart';

const developerHelp = """toolbox dev [--repo PATH] <area> <action> [arguments]
  bootstrap [--config FILE] [--build]
  build (complete firmware, including the installer .y2-firmware)
  app build [--release] | deploy [--release] [--dry-run] | attach | clean
  app flutter-pi build|test|engine|rev|clean
  cadence build
  daemon build [--target host|arm] [--dart-only] | deploy [--dry-run] | test|check|clean
  emulator run [Flutter run arguments] | mcp | clean
  workspace get|analyze|test|format
  toolbox build [native|web|cli|linux|macos|windows|apk|ios] | check
  os kernel build|prepare|bootimg|rev|reset|clean
  os recovery build (DA RAM payload and LK recovery.img)
  os rootfs build|stage|shell|plan|clean | stage-plymouth TREE OUTPUT
  os initramfs build|render | runtime build | bluetooth build
  os splash build|assets|info|extract|install|harvest|clean
  diagnostics capture-a2dp [BLUETOOTH_ADDRESS] [OUTPUT_DIRECTORY]
  diagnostics analyze-tone WAV [--silence-db -45] [--minimum-gap-ms 5]
  device ssh|status|link|reboot|poweroff|screenshot|collect-sysinfo
  device flash-boot|flash-logo|install-rootfs
  toolchain build|rebuild|run|shell|info|clean
  dist [--full] [--with-rootfs]
  config get|list|json|has [key] [--raw]
  secrets status|hash|is-hashed
""";

Future<int> runDeveloperCommand(
  List<String> arguments, {
  String? repositoryRoot,
}) async {
  final args = [...arguments];
  try {
    final repoIndex = args.indexOf('--repo');
    if (repoIndex >= 0) {
      if (repoIndex + 1 == args.length)
        throw BuildFailure('--repo requires a path', 2);
      repositoryRoot = args[repoIndex + 1];
      args.removeRange(repoIndex, repoIndex + 2);
    }
    if (args.isEmpty || args.every((arg) => arg == '--help' || arg == '-h')) {
      stdout.write(developerHelp);
      return 0;
    }
    if (args.contains('--help') || args.contains('-h')) {
      try {
        stdout.write(developerCommandHelp(args));
      } on FormatException catch (error) {
        throw BuildFailure(error.message, 2);
      }
      return 0;
    }
    final area = args.removeAt(0);
    final action = args.isEmpty ? '' : args.removeAt(0);
    if (area == 'diagnostics')
      return await diagnosticsCommand([if (action.isNotEmpty) action, ...args]);
    final repository = Repository.locate(explicitRoot: repositoryRoot);
    final runner = CommandRunner();
    Future<int> dispatch(List<String> step) =>
        runDeveloperCommand(step, repositoryRoot: repository.root);
    if (area == 'bootstrap') {
      return await bootstrapCommand(repository, runner, [
        if (action.isNotEmpty) action,
        ...args,
      ], dispatch);
    }
    if (area == 'config')
      return configCommand(BuildConfig.load(repository), action, args);
    if (area == 'secrets')
      return await secretsCommand(repository, runner, action, args);
    if (area == 'toolchain') {
      final toolchain = Toolchain(repository, runner);
      if (action == 'clean')
        return await runner.run('podman', ['rmi', 'tempo-toolchain']);
      if (action == 'info') {
        await runner.run('podman', ['image', 'inspect', 'tempo-toolchain']);
        for (final command in [
          ['arm-linux-gnueabihf-gcc', '--version'],
          ['rustc', '--version'],
          ['dtc', '--version'],
        ])
          await toolchain.run(command);
        return 0;
      }
      return await switch (action) {
        'build' => toolchain.build(args),
        'rebuild' => toolchain.build(['--no-cache', '--pull', ...args]),
        'run' when args.isNotEmpty => toolchain.run(args),
        'shell' => toolchain.run(['zsh', ...args]),
        _ => throw BuildFailure(
          'Expected toolchain build, rebuild, run COMMAND, or shell',
          2,
        ),
      };
    }
    final config = BuildConfig.load(repository);
    if (area == 'build') {
      return await firmwareBuildCommand(repository, config, runner, [
        if (action.isNotEmpty) action,
        ...args,
      ], dispatch);
    }
    if (area == 'device')
      return await deviceCommand(repository, config, runner, [
        if (action.isNotEmpty) action,
        ...args,
      ]);
    if (area == 'dist')
      return await distributionCommand(repository, config, runner, [
        if (action.isNotEmpty) action,
        ...args,
      ]);
    if (area == 'os') {
      if (action == 'runtime')
        return await systemRuntimeCommand(repository, config, runner, args);
      if (action == 'splash' &&
          args.isNotEmpty &&
          ['install', 'harvest'].contains(args.first))
        return await deviceCommand(repository, config, runner, [
          'splash-${args.first}',
          ...args.skip(1),
        ]);
      if (action == 'splash')
        return await splashCommand(repository, config, runner, args);
      if (action == 'rootfs')
        return await rootfsCommand(repository, config, runner, args);
      if (action == 'bluetooth')
        return await bluetoothCommand(repository, config, runner, args);
      if (action == 'recovery' &&
          (args.isEmpty || (args.length == 1 && args.single == 'build'))) {
        await buildRecovery(repository, runner);
        return 0;
      }
      if (action == 'kernel')
        return await kernelCommand(repository, config, runner, args);
      if (action == 'initramfs') {
        if (args.isEmpty || (args.length == 1 && args.single == 'build')) {
          await buildInitramfs(repository, config, runner);
          return 0;
        }
        if (args.length == 1 && args.single == 'render') {
          await renderInitramfs(repository, config, runner);
          return 0;
        }
      }
      throw BuildFailure('Unknown OS component command: $action', 2);
    }
    if (area == 'emulator')
      return await emulatorCommand(repository, config, runner, action, args);
    if (area == 'toolbox')
      return await toolboxCommand(repository, config, runner, action, args);
    if (area == 'cadence')
      return await cadenceCommand(repository, config, runner, [
        action,
        ...args,
      ]);
    if (area == 'daemon')
      return await daemonCommand(repository, config, runner, [
        if (action.isNotEmpty) action,
        ...args,
      ]);
    if (area == 'workspace')
      return await workspaceCommand(repository, config, runner, action, args);
    if (area == 'app') {
      if (action == 'flutter-pi')
        return await embedderCommand(repository, config, runner, args);
      return await appCommand(repository, config, runner, action, args);
    }
    throw BuildFailure(
      'Unknown developer command: $area $action\n$developerHelp',
      2,
    );
  } on BuildFailure catch (error) {
    stderr.writeln(error.message);
    return error.code;
  } on Object catch (error) {
    stderr.writeln(error);
    return 1;
  }
}

int configCommand(BuildConfig config, String action, List<String> args) {
  final raw = args.remove('--raw');
  if (args.length > 1) throw BuildFailure('Expected one configuration key', 2);
  final key = args.firstOrNull;
  final sentinel = Object();
  final value = key == null
      ? config.values
      : config.get(key, fallback: sentinel);
  if (identical(value, sentinel)) {
    if (action == 'has') return 1;
    throw BuildFailure('No such configuration key: $key');
  }
  switch (action) {
    case 'json':
      stdout.writeln(
        const JsonEncoder.withIndent(
          '  ',
        ).convert(raw ? value : config.redacted(key)),
      );
      return 0;
    case 'get':
      if (key == null || value is Map || value is List)
        throw BuildFailure('config get requires a scalar key', 2);
      stdout.writeln(value ?? '');
      return 0;
    case 'list':
      if (key == null || value is! List)
        throw BuildFailure('config list requires a list key', 2);
      for (final entry in value) {
        stdout.writeln(entry ?? '');
      }
      return 0;
    case 'has':
      return value == null ||
              value == '' ||
              (value is List && value.isEmpty) ||
              (value is Map && value.isEmpty)
          ? 1
          : 0;
    default:
      throw BuildFailure('Expected config get, list, json, or has', 2);
  }
}

final cryptPattern = RegExp(r'^\$(y|gy|7|2[abxy]|6|5|1)\$');
Future<int> secretsCommand(
  Repository repository,
  CommandRunner runner,
  String action,
  List<String> args,
) async {
  if (args.isNotEmpty) throw BuildFailure('Unexpected secrets arguments', 2);
  final local = File(repository.path('config.local.yaml'));
  final config = BuildConfig.load(repository, expandKeys: false);
  final password = config.get('user.password')?.toString() ?? '';
  if (action == 'is-hashed') return cryptPattern.hasMatch(password) ? 0 : 1;
  if (action == 'status' || action.isEmpty) {
    stdout.writeln(
      'config.local.yaml: ${local.existsSync() ? 'present' : 'absent'}',
    );
    stdout.writeln(
      '  password: ${password.isEmpty
          ? 'unset'
          : cryptPattern.hasMatch(password)
          ? 'hashed'
          : 'PLAINTEXT'}',
    );
    stdout.writeln(
      '  ssh_keys: ${(config.get('user.ssh_keys') as List?)?.length ?? 0} configured entries',
    );
    return local.existsSync() ? 0 : 1;
  }
  if (action != 'hash')
    throw BuildFailure('Expected secrets status, hash, or is-hashed', 2);
  if (!local.existsSync())
    throw BuildFailure('No config.local.yaml; copy config.local.example.yaml');
  if (password.isNotEmpty && !cryptPattern.hasMatch(password)) {
    // Never put plaintext secrets in argv, logs, or shell code.
    final child = await Process.start('openssl', ['passwd', '-6', '-stdin']);
    final output = child.stdout.transform(utf8.decoder).join();
    final errors = child.stderr.transform(utf8.decoder).join();
    child.stdin.write(password);
    await child.stdin.close();
    final code = await child.exitCode;
    final hash = (await output).trim();
    await errors;
    if (code != 0 || !cryptPattern.hasMatch(hash))
      throw BuildFailure(
        'openssl password hashing failed; local configuration was not changed',
      );
    final source = local.readAsStringSync();
    final pattern = RegExp(r'^(\s*)password\s*:[^\r\n]*', multiLine: true);
    final matches = pattern.allMatches(source).toList();
    if (matches.length != 1)
      throw BuildFailure(
        'Expected exactly one password: line; local configuration was not changed',
      );
    final match = matches.single;
    final replacement =
        "${match.group(1)}password: '${hash.replaceAll("'", "''")}'";
    final temporary = File('${local.path}.tmp.${pid}');
    try {
      temporary.writeAsStringSync('');
      if (!Platform.isWindows)
        await runner.run('chmod', ['600', temporary.path]);
      temporary.writeAsStringSync(
        source.replaceRange(match.start, match.end, replacement),
        flush: true,
      );
      temporary.renameSync(local.path);
    } finally {
      if (temporary.existsSync()) temporary.deleteSync();
    }
  }
  if (!Platform.isWindows) await runner.run('chmod', ['600', local.path]);
  stdout.writeln('Local password is hashed or unset; permissions updated.');
  return 0;
}

Future<int> workspaceCommand(
  Repository repository,
  BuildConfig config,
  CommandRunner runner,
  String action,
  List<String> args,
) async {
  if (!['get', 'analyze', 'test', 'format'].contains(action))
    throw BuildFailure('Expected workspace get, analyze, test, or format', 2);
  final sdk = await FlutterSdk.discover(config, runner);
  final roots = <String>[repository.path('app'), repository.path('daemon')];
  final packages = Directory(repository.path('packages'));
  if (packages.existsSync()) {
    for (final entry in packages.listSync().whereType<Directory>()) {
      if (File(p.join(entry.path, 'pubspec.yaml')).existsSync())
        roots.add(entry.path);
    }
  }
  for (final relative in ['toolbox/app', 'toolbox/cli']) {
    if (File(repository.path('$relative/pubspec.yaml')).existsSync())
      roots.add(repository.path(relative));
  }
  roots.sort();
  if (action == 'format')
    return runner.run(sdk.dart, [
      'format',
      ...args,
      ...roots,
    ], workingDirectory: repository.root);
  final failures = <String>[];
  if (action == 'get') {
    final code = await runner.run(
      sdk.flutter,
      ['pub', 'get', ...args],
      workingDirectory: repository.root,
      check: false,
    );
    if (code != 0) failures.add('.');
  }
  for (final root in roots) {
    final spec = File(p.join(root, 'pubspec.yaml')).readAsStringSync();
    if (action == 'get' &&
        RegExp(r'^resolution:\s*workspace\s*$', multiLine: true).hasMatch(spec))
      continue;
    if (action == 'test' && !Directory(p.join(root, 'test')).existsSync())
      continue;
    var selected = sdk;
    if (root == repository.path('daemon'))
      selected = await FlutterSdk.discover(
        config,
        runner,
        version: config
            .get('daemon.toolchain_version', fallback: '3.47.2')
            .toString(),
      );
    final toolboxPin = File(repository.path('toolbox/app/.fvmrc'));
    if (root == repository.path('toolbox/app') && toolboxPin.existsSync())
      selected = await FlutterSdk.discover(
        config,
        runner,
        version:
            (jsonDecode(toolboxPin.readAsStringSync()) as Map)['flutter']
                as String,
      );
    final flutter = RegExp(
      r'^\s+sdk:\s*flutter\s*$',
      multiLine: true,
    ).hasMatch(spec);
    final executable = flutter ? selected.flutter : selected.dart;
    final command = switch (action) {
      'get' => ['pub', 'get', ...args],
      'analyze' => ['analyze', if (flutter) '--no-pub', ...args],
      _ => ['test', if (flutter) '--no-pub', ...args],
    };
    stdout.writeln('Checking ${p.relative(root, from: repository.root)}');
    if (action == 'test' && root == repository.path('daemon')) {
      try {
        if (await daemonCommand(repository, config, runner, [
              'test',
              ...args,
            ]) !=
            0)
          failures.add('daemon');
      } on BuildFailure {
        failures.add('daemon');
      }
      continue;
    }
    if (await runner.run(
          executable,
          command,
          workingDirectory: root,
          check: false,
        ) !=
        0)
      failures.add(p.relative(root, from: repository.root));
  }
  if (failures.isNotEmpty) {
    stderr.writeln('$action failed: ${failures.join(', ')}');
    return 1;
  }
  return 0;
}
