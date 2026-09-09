import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'context.dart';
import 'process.dart';
import 'toolbox_linux.dart';

/// Normalize public Unix build products without following links out of a bundle.
/// The checkout's umask must not make a root-owned installation inaccessible.
Future<void> normalizeToolboxPermissions(
  Directory bundle,
  CommandRunner runner,
) async {
  if (Platform.isWindows) return;
  if (FileSystemEntity.typeSync(bundle.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw BuildFailure(
      'Toolbox output must be a real directory: ${bundle.path}',
    );
  }
  await runner.run('chmod', ['755', bundle.path]);
  for (final entry in bundle.listSync(recursive: true, followLinks: false)) {
    if (entry is Link) continue;
    final mode = entry is Directory || entry.statSync().mode & 0x49 != 0
        ? '755'
        : '644';
    await runner.run('chmod', [mode, entry.path]);
  }
}

/// Linux build tools belong to the toolchain image, not the developer's PATH.
final class ToolboxBuildTools {
  ToolboxBuildTools(this.repo, this.runner);
  final Repository repo;
  final CommandRunner runner;
  String get rust => repo.path('packages/tempo_usb/rust');
  String get output => repo.path('build/toolbox/rust');
  Future<int> cargo(List<String> args, {bool wasm = false, bool check = true}) {
    final command = [
      args.first,
      '--manifest-path',
      p.join(rust, 'Cargo.toml'),
      ...args.skip(1),
    ];
    final environment = {'CARGO_TARGET_DIR': output};
    if (Platform.isLinux || wasm) {
      return Toolchain(repo, runner).run(
        ['cargo', ...command],
        workingDirectory: rust,
        environment: environment,
        check: check,
      );
    }
    // A Linux container cannot link a macOS/Windows USB executable. Keep the
    // existing platform-native builder explicit until those builders exist.
    stderr.writeln(
      'Native ${Platform.operatingSystem} USB builds require that platform’s Rust toolchain; the Linux toolchain handles Wasm builds.',
    );
    return runner.run(
      'cargo',
      command,
      workingDirectory: rust,
      environment: environment,
      check: check,
    );
  }

  Future<void> buildWasm() async {
    await cargo([
      'build',
      '--locked',
      '--release',
      '--lib',
      '--target',
      'wasm32-unknown-unknown',
    ], wasm: true);
    await bindgen(repo.path('toolbox/app/web/pkg'));
  }

  Future<int> browserTests(List<String> tests) async {
    // Integration tests import production bindings, including on a clean tree.
    await buildWasm();
    final toolchain = Toolchain(repo, runner);
    final directory = repo.path('packages/tempo_usb');
    final home = Directory(repo.path('build/toolbox/test-home'))
      ..createSync(recursive: true);
    final environment = {
      'PUB_CACHE': repo.path('build/toolbox/test-pub-cache'),
      'HOME': home.path,
      'DART_SUPPRESS_ANALYTICS': 'true',
    };
    const dart = '/opt/toolbox-test/dart-sdk/bin/dart';
    await toolchain.run(
      [dart, 'pub', 'get'],
      workingDirectory: directory,
      environment: environment,
    );
    return toolchain.run(
      [dart, 'test', '-p', 'node', ...tests],
      workingDirectory: directory,
      environment: environment,
      check: false,
    );
  }

  Future<int> bindgen(String outputDirectory) async {
    final result = await Toolchain(repo, runner).run([
      '/usr/local/bin/wasm-bindgen',
      p.join(output, 'wasm32-unknown-unknown/release/tempo_installer.wasm'),
      '--target',
      'web',
      '--out-dir',
      outputDirectory,
    ]);
    // Node 18 requires an explicit ESM marker for generated .js bindings.
    Directory(outputDirectory).createSync(recursive: true);
    File(
      p.join(outputDirectory, 'package.json'),
    ).writeAsStringSync('{"type":"module"}\n');
    return result;
  }
}

Future<int> toolboxCommand(
  Repository repo,
  BuildConfig config,
  CommandRunner runner,
  String action,
  List<String> args,
) async {
  final app = repo.path('toolbox/app');
  final cli = repo.path('toolbox/cli');
  final out = ArtifactPaths(repo).toolbox;
  final cargoOut = p.join(out, 'rust');
  final buildTools = ToolboxBuildTools(repo, runner);
  var version = config.string('flutter.sdk_version');
  final pin = File(p.join(app, '.fvmrc'));
  if (pin.existsSync())
    version = (jsonDecode(pin.readAsStringSync()) as Map)['flutter'] as String;
  final containerBuild =
      Platform.isLinux &&
      action == 'build' &&
      (args.isEmpty || ['native', 'linux', 'cli', 'web'].contains(args.first));
  final linux = containerBuild
      ? LinuxToolboxBuilder(repo, runner, version)
      : null;
  if (linux != null) await linux.prepare(config);
  final sdk =
      linux?.sdk ?? await FlutterSdk.discover(config, runner, version: version);
  Future<int> runSdk(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    bool check = true,
  }) => linux == null
      ? runner.run(
          executable,
          arguments,
          workingDirectory: workingDirectory,
          check: check,
        )
      : linux.run(
          executable,
          arguments,
          workingDirectory: workingDirectory,
          check: check,
        );
  Future<int> cargo(List<String> args, {bool check = true}) =>
      buildTools.cargo(args, check: check);
  if (action == 'check') {
    final failed = <String>[];
    for (final command in [
      ['fmt', '--check'],
      ['test', '--locked'],
      ['clippy', '--all-targets', '--locked', '--', '-D', 'warnings'],
    ]) {
      if (await cargo(command, check: false) != 0)
        failed.add('cargo ${command.first}');
    }
    final usb = repo.path('packages/tempo_usb');
    final browserTests = Directory(p.join(usb, 'test')).existsSync()
        ? Directory(p.join(usb, 'test'))
              .listSync()
              .whereType<File>()
              .where(
                (f) =>
                    p.basename(f.path).startsWith('browser_') &&
                    f.path.endsWith('_test.dart'),
              )
              .map((f) => f.path)
              .toList()
        : <String>[];
    if (browserTests.isNotEmpty &&
        await buildTools.browserTests(browserTests) != 0)
      failed.add('browser tests');
    for (final command in [
      ['analyze', ...args],
      ['test', ...args],
    ]) {
      if (await runSdk(
            sdk.flutter,
            command,
            workingDirectory: app,
            check: false,
          ) !=
          0)
        failed.add('Flutter ${command.first}');
    }
    for (final command in [
      ['analyze'],
      ['test'],
    ]) {
      if (command.first == 'test' &&
          !Directory(p.join(cli, 'test')).existsSync())
        continue;
      if (await runSdk(
            sdk.dart,
            command,
            workingDirectory: cli,
            check: false,
          ) !=
          0)
        failed.add('CLI ${command.first}');
    }
    if (failed.isNotEmpty) {
      stderr.writeln('Toolbox checks failed: ${failed.join(', ')}');
      return 1;
    }
    return 0;
  }
  if (action != 'build')
    throw BuildFailure(
      'Expected toolbox build [native|web|cli|linux|macos|windows|apk|ios] or check',
      2,
    );
  final target = args.isEmpty ? 'native' : args.removeAt(0);
  final platform = target == 'native' ? Platform.operatingSystem : target;
  final guiOnly = args.remove('--gui-only');
  if (guiOnly && !['linux', 'macos', 'windows'].contains(platform)) {
    throw BuildFailure('--gui-only requires a native desktop target', 2);
  }
  if (![
    'web',
    'cli',
    'linux',
    'macos',
    'windows',
    'apk',
    'ios',
  ].contains(platform))
    throw BuildFailure('Unsupported toolbox target: $target', 2);
  final loader = File(repo.path('platform/firmware/DA.img'));
  if (!loader.existsSync())
    throw BuildFailure('Missing firmware download agent: ${loader.path}');
  if (platform == 'web') {
    await buildTools.buildWasm();
    loader.copySync(p.join(app, 'web/DA.img'));
    return runSdk(sdk.flutter, [
      'build',
      'web',
      '--no-web-resources-cdn',
      if (linux != null) '--no-pub',
      ...args,
    ], workingDirectory: app);
  }
  if (platform == 'apk' || platform == 'ios')
    return runSdk(sdk.flutter, [
      'build',
      platform,
      ...args,
    ], workingDirectory: app);
  await cargo(['build', '--locked', '--release', '--bin', 'tempo-usb']);
  final helper = File(
    p.join(
      cargoOut,
      'release',
      Platform.isWindows ? 'tempo-usb.exe' : 'tempo-usb',
    ),
  );
  void copyResources(String directory) {
    Directory(directory).createSync(recursive: true);
    helper.copySync(p.join(directory, p.basename(helper.path)));
    loader.copySync(p.join(directory, 'DA.img'));
    File(
      repo.path('toolbox/linux/70-tempo-recovery.rules'),
    ).copySync(p.join(directory, '70-tempo-recovery.rules'));
    final recovery = Directory(repo.path('build/recovery'));
    final destination = Directory(p.join(directory, 'recovery'));
    destination.createSync(recursive: true);
    for (final name in ['ramboot-DA.bin', 'payload.bin', 'preloader.bin']) {
      final source = File(p.join(recovery.path, name));
      if (!source.existsSync()) {
        throw StateError(
          'Build platform/recovery in the toolchain container before packaging Toolbox: missing $name',
        );
      }
      source.copySync(p.join(destination.path, name));
    }
  }

  final cliOut = p.join(out, 'cli');
  if (!guiOnly) {
    Directory(cliOut).createSync(recursive: true);
    if (linux == null) {
      await runSdk(sdk.dart, ['pub', 'get'], workingDirectory: cli);
    } else {
      linux.dependencyMounts(cli);
    }
    final cliExecutable = p.join(
      cliOut,
      Platform.isWindows ? 'toolbox.exe' : 'toolbox',
    );
    final compiled = File(
      p.join(cliOut, '.toolbox-$pid${Platform.isWindows ? '.exe' : ''}'),
    );
    try {
      await runSdk(sdk.dart, [
        'compile',
        'exe',
        'bin/toolbox.dart',
        '-o',
        compiled.path,
      ], workingDirectory: cli);
      // `toolbox dev toolbox build cli` may be running the previous executable.
      // Publish a complete new inode rather than truncating the running binary.
      compiled.renameSync(cliExecutable);
    } finally {
      if (compiled.existsSync()) compiled.deleteSync();
    }
    copyResources(cliOut);
    await normalizeToolboxPermissions(Directory(cliOut), runner);
  }
  if (platform == 'cli') return 0;
  if (platform != Platform.operatingSystem)
    throw BuildFailure(
      'Build $platform GUI on a $platform host; CLI artifacts are in $cliOut',
    );
  await runSdk(sdk.flutter, [
    'build',
    platform,
    if (linux != null) '--no-pub',
    ...args,
  ], workingDirectory: app);
  final build = Directory(
    p.join(linux?.buildDirectory ?? p.join(app, 'build'), platform),
  );
  final mode = args.contains('--debug')
      ? 'debug'
      : args.contains('--profile')
      ? 'profile'
      : 'release';
  final bundles = <String>[];
  if (platform == 'linux') {
    for (final arch in build.listSync().whereType<Directory>()) {
      final bundle = p.join(arch.path, mode, 'bundle');
      if (Directory(bundle).existsSync()) bundles.add(bundle);
    }
  } else if (platform == 'windows') {
    for (final arch in build.listSync().whereType<Directory>()) {
      final bundle = p.join(arch.path, 'runner', _productMode(mode));
      if (Directory(bundle).existsSync()) bundles.add(bundle);
    }
  } else {
    final products = Directory(
      p.join(build.path, 'Build/Products', _productMode(mode)),
    );
    for (final bundle in products.listSync().whereType<Directory>().where(
      (entry) => entry.path.endsWith('.app'),
    ))
      bundles.add(p.join(bundle.path, 'Contents/MacOS'));
  }
  if (bundles.isEmpty) throw BuildFailure('No $platform GUI bundle produced');
  for (final bundle in bundles) {
    copyResources(bundle);
    final root = platform == 'macos' ? p.dirname(p.dirname(bundle)) : bundle;
    await normalizeToolboxPermissions(Directory(root), runner);
  }
  if (!guiOnly) stdout.writeln('CLI: $cliOut');
  stdout.writeln('GUI: ${bundles.join(', ')}');
  return 0;
}

String _productMode(String mode) =>
    '${mode[0].toUpperCase()}${mode.substring(1)}';
