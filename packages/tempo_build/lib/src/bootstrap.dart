import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'bootstrap_sdk.dart';
import 'context.dart';
import 'process.dart';
import 'rootfs_container.dart';

typedef DeveloperStep = Future<int> Function(List<String> arguments);

/// Dependency order matters: the rootfs supplies Plymouth to the initramfs.
const firmwareBuildSteps = <List<String>>[
  ['app', 'flutter-pi', 'engine'],
  ['app', 'flutter-pi', 'build'],
  ['app', 'build', '--release'],
  ['daemon', 'build', '--target', 'arm'],
  ['cadence', 'fetch'],
  ['os', 'splash', 'assets'],
  ['os', 'splash', 'build'],
  ['os', 'rootfs', 'build'],
  ['os', 'kernel', 'build'],
  ['dist'],
];

Future<int> firmwareBuildCommand(
  Repository repo,
  BuildConfig config,
  CommandRunner runner,
  List<String> args,
  DeveloperStep dispatch,
) async {
  if (args.isNotEmpty) throw BuildFailure('Expected toolbox dev build', 2);
  await requireFirmwareHost(runner);
  await validateFirmwareInputs(repo, config);
  // binfmt registrations are kernel state and may disappear after a reboot.
  await RootfsContainer(repo, config, runner).checkPrerequisites();
  for (final step in firmwareBuildSteps) {
    stdout.writeln('\n== toolbox dev ${step.join(' ')} ==');
    final code = await dispatch([...step]);
    if (code != 0) return code;
  }
  return 0;
}

Future<void> requireFirmwareHost(CommandRunner runner) async {
  if (!Platform.isLinux ||
      (await runner.capture('uname', ['-m'])).stdout.toString().trim() !=
          'x86_64') {
    throw BuildFailure(
      'The complete firmware build currently requires Linux x64 (ARMv7 '
      'gen_snapshot and rootful Podman). Run bootstrap in a Linux x64 checkout.',
    );
  }
}

/// Validate local credentials before downloads or a rootfs rebuild.
Future<void> validateFirmwareInputs(Repository repo, BuildConfig config) async {
  final missing = <String>[];
  final password = config.get('user.password')?.toString() ?? '';
  final keys = config.get('user.ssh_keys') as List? ?? [];
  if (password.isEmpty && keys.isEmpty) {
    missing.add(
      'Set user.ssh_keys or user.password in config.local.yaml '
      '(see config.local.example.yaml; bootstrap --config FILE imports it).',
    );
  }
  if (password == 'change-me') {
    missing.add(
      'Replace the example user.password in config.local.yaml, '
      'or use an SSH public key with a locked password.',
    );
  }
  if (missing.isNotEmpty) {
    throw BuildFailure(
      'Firmware inputs need setup:\n${missing.map((s) => '  - $s').join('\n')}',
    );
  }
}

/// Explicit imports never replace machine configuration in place.
Future<void> importBootstrapInputs(
  Repository repo,
  CommandRunner runner, {
  String? configuration,
}) async {
  if (configuration != null) {
    final source = File(p.absolute(configuration));
    final destination = File(repo.path('config.local.yaml'));
    if (!source.existsSync())
      throw BuildFailure('Missing configuration: ${source.path}', 2);
    if (destination.existsSync()) {
      if (destination.readAsStringSync() != source.readAsStringSync()) {
        throw BuildFailure(
          'config.local.yaml already exists; merge your settings there before rerunning bootstrap.',
        );
      }
    } else {
      // Preserve the user's original YAML and comments.
      await runner.run('install', ['-m', '600', source.path, destination.path]);
    }
  }
}

Future<int> bootstrapCommand(
  Repository repo,
  CommandRunner runner,
  List<String> arguments,
  DeveloperStep dispatch,
) async {
  final args = [...arguments];
  String? option(String flag) {
    final index = args.indexOf(flag);
    if (index < 0) return null;
    if (index + 1 == args.length || args[index + 1].startsWith('--')) {
      throw BuildFailure('$flag requires a path', 2);
    }
    final value = args[index + 1];
    args.removeRange(index, index + 2);
    return value;
  }

  final configuration = option('--config');
  final build = args.remove('--build');
  if (args.isNotEmpty)
    throw BuildFailure('Unexpected bootstrap arguments: ${args.join(' ')}', 2);
  await requireFirmwareHost(runner);
  final directory = Directory(repo.path('build/bootstrap'))
    ..createSync(recursive: true);
  final lock = File(
    p.join(directory.path, 'lock'),
  ).openSync(mode: FileMode.append);
  try {
    try {
      lock.lockSync(FileLock.exclusive);
    } on FileSystemException {
      throw BuildFailure('Bootstrap is already running in this checkout.', 73);
    }
    await importBootstrapInputs(repo, runner, configuration: configuration);
    final config = BuildConfig.load(repo);
    await validateFirmwareInputs(repo, config);
    await runner.run('git', ['--version']);
    await runner.run('podman', ['info', '--format', '{{.Host.Arch}}']);
    // This may prompt through sudo's own terminal; rootfs uses this same access.
    final uid = (await runner.capture('id', ['-u'])).stdout.toString().trim();
    await runner.run(uid == '0' ? 'podman' : 'sudo', [
      if (uid != '0') 'podman',
      'info',
      '--format',
      '{{.Host.Arch}}',
    ]);
    stdout.writeln('\nInitializing pinned submodules and firmware blobs');
    await runner.run('git', [
      'submodule',
      'update',
      '--init',
      '--recursive',
      '--depth',
      '1',
    ], workingDirectory: repo.root);
    stdout.writeln('\nBuilding the shared toolchain');
    await Toolchain(repo, runner).build([]);
    await provisionFirmwareLfs(repo, runner);
    stdout.writeln('\nProvisioning pinned SDKs');
    await bootstrapSdks(repo, config, runner);
    stdout.writeln('\nChecking rootfs container privileges and ARM execution');
    await RootfsContainer(repo, config, runner).checkPrerequisites();
    stdout.writeln(
      '\nResolving dependencies (including the private Cadence repository)',
    );
    final get = await dispatch(['workspace', 'get']);
    if (get != 0) {
      throw BuildFailure(
        'Dependency resolution failed. Ensure your Git/SSH credentials can access '
        'the private dependencies listed in the pubspecs, then rerun bootstrap.',
        get,
      );
    }
    for (final step in [
      ['app', 'flutter-pi', 'engine'],
      ['toolbox', 'build', 'cli'],
    ]) {
      final code = await dispatch(step);
      if (code != 0) return code;
    }
    stdout.writeln(
      '\nBootstrap complete. CLI: ${repo.path('build/toolbox/cli/toolbox')}\n'
      'Run build/toolbox/cli/toolbox dev build from the checkout to produce '
      'the installer .y2-firmware under build/dist/.',
    );
    return build ? await dispatch(['build']) : 0;
  } finally {
    lock.closeSync();
  }
}

Future<void> provisionFirmwareLfs(Repository repo, CommandRunner runner) async {
  // Hydrate both the legacy transfer DA and the Rockbox DA used to pack
  // Tempo Recovery's RAM boot wrapper. Both are production build inputs.
  // Run the container-supplied standalone LFS client on the host so it uses
  // existing Git/SSH authentication without sharing private keys with Podman.
  final staging = Directory(repo.path('build/bootstrap/bin'))
    ..createSync(recursive: true);
  final staged = p.join(staging.path, 'git-lfs');
  await Toolchain(repo, runner).run(['cp', '/usr/bin/git-lfs', staged]);
  final metadata = (await runner.capture('git', [
    'rev-parse',
    '--git-common-dir',
  ], workingDirectory: repo.root)).stdout.toString().trim();
  // Filters must still work after build/ is cleaned or a worktree is removed.
  // Keep their small standalone client with the shared repository metadata.
  final bin = Directory(
    p.join(p.normalize(p.join(repo.root, metadata)), 'tempo', 'bin'),
  )..createSync(recursive: true);
  final lfs = p.join(bin.path, 'git-lfs');
  final temporary = await File(staged).copy('$lfs.$pid');
  try {
    temporary.renameSync(lfs);
  } finally {
    if (temporary.existsSync()) temporary.deleteSync();
  }
  final environment = {
    'PATH': '${bin.path}:${Platform.environment['PATH'] ?? ''}',
  };
  await runner.run(
    'git',
    ['config', '--local', 'filter.lfs.required', 'true'],
    workingDirectory: repo.root,
    environment: environment,
  );
  // Future ordinary Git operations also find this checkout's client. Configure
  // filters directly: `lfs install` rejects this absolute executable on reruns
  // and attempts to replace existing hooks, which bootstrap must preserve.
  for (final action in ['clean', 'smudge', 'process']) {
    await runner.run('git', [
      'config',
      '--local',
      'filter.lfs.$action',
      '${shellQuote(lfs)} ${action == 'process' ? 'filter-process' : '$action -- %f'}',
    ], workingDirectory: repo.root);
  }
  await runner.run(
    lfs,
    ['pull', '--include=platform/firmware/**', '--exclude='],
    workingDirectory: repo.root,
    environment: environment,
  );
  final files = await runner.capture(
    lfs,
    ['ls-files', '--name-only'],
    workingDirectory: repo.root,
    environment: environment,
  );
  for (final relative in const LineSplitter().convert(
    files.stdout.toString(),
  )) {
    if (!relative.startsWith('platform/firmware/')) continue;
    final file = File(repo.path(relative));
    if (!file.existsSync() || file.lengthSync() == 0) {
      throw BuildFailure('Missing Git LFS firmware: $relative');
    }
    final input = file.openSync();
    try {
      final header = utf8.decode(input.readSync(128), allowMalformed: true);
      if (header.startsWith('version https://git-lfs.github.com/spec/v1')) {
        throw BuildFailure('Firmware is still a Git LFS pointer: $relative');
      }
    } finally {
      input.closeSync();
    }
  }
}
