import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'context.dart';
import 'process.dart';

/// Installs every SDK needed by firmware and toolbox builds, without FVM.
Future<Map<String, FlutterSdk>> bootstrapSdks(
  Repository repository,
  BuildConfig config,
  CommandRunner runner,
) async {
  final appVersion = config.string('flutter.sdk_version');
  final daemonVersion = config
      .get('daemon.toolchain_version', fallback: '3.47.2')
      .toString();
  final toolboxPin =
      jsonDecode(File(repository.path('toolbox/app/.fvmrc')).readAsStringSync())
          as Map;
  final toolboxVersion = toolboxPin['flutter'];
  if (toolboxVersion is! String) {
    throw BuildFailure('toolbox/app/.fvmrc must contain a Flutter pin.');
  }
  final result = <String, FlutterSdk>{};
  for (final version in {appVersion, daemonVersion, toolboxVersion}) {
    result[version] = await provisionFlutterSdk(
      repository,
      config,
      runner,
      version,
    );
  }
  final expectedDart = config
      .get('daemon.dart_version', fallback: '3.13.2')
      .toString();
  final daemonDart = await runner.capture(result[daemonVersion]!.dart, [
    '--version',
  ]);
  if (!'${daemonDart.stdout}${daemonDart.stderr}'.contains(
    'Dart SDK version: $expectedDart ',
  )) {
    throw BuildFailure(
      'Flutter $daemonVersion does not bundle required daemon Dart $expectedDart.',
    );
  }
  for (final version in {appVersion, toolboxVersion}) {
    await Toolchain(repository, runner).run([
      result[version]!.flutter,
      'precache',
      '--linux',
    ], environment: _environment(repository));
  }
  _linkSdk(repository.path('.fvm/flutter_sdk'), result[appVersion]!.root);
  _linkSdk(
    repository.path('toolbox/app/.fvm/flutter_sdk'),
    result[toolboxVersion]!.root,
  );
  return result;
}

/// Only complete, version-checked SDKs are published under the cache path.
Future<FlutterSdk> provisionFlutterSdk(
  Repository repository,
  BuildConfig config,
  CommandRunner runner,
  String version, {
  bool useCachedSdk = true,
}) async {
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(version)) {
    throw BuildFailure('Invalid Flutter SDK pin: $version');
  }
  final destination = repository.path('build/sdks/flutter/$version');
  final installed = FlutterSdk(destination);
  if (Directory(destination).existsSync()) {
    await _validateSdk(repository, installed, version, runner);
    return installed;
  }
  Directory(p.dirname(destination)).createSync(recursive: true);
  final staging = Directory(
    p.dirname(destination),
  ).createTempSync('.$version-');
  try {
    FlutterSdk? cached;
    try {
      if (useCachedSdk) {
        cached = await FlutterSdk.discover(config, runner, version: version);
      }
    } on BuildFailure {
      // A clean checkout has no SDK cache; fetch the official pinned source.
    }
    if (cached != null &&
        FileSystemEntity.typeSync(
              p.join(cached.root, '.git'),
              followLinks: false,
            ) !=
            FileSystemEntityType.directory) {
      // Worktree/gitdir pointers would escape the copied SDK and its container.
      // Download an independent checkout instead of publishing a broken copy.
      cached = null;
    }
    if (cached != null) {
      stdout.writeln('Copying Flutter $version into the checkout SDK cache.');
      await _copyDirectory(
        Directory(cached.root).resolveSymbolicLinksSync(),
        staging.path,
      );
    } else {
      stdout.writeln('Downloading Flutter $version.');
      await runner.run('git', ['init', staging.path]);
      await runner.run('git', [
        '-C',
        staging.path,
        'remote',
        'add',
        'origin',
        'https://github.com/flutter/flutter.git',
      ]);
      await runner.run('git', [
        '-C',
        staging.path,
        'fetch',
        '--depth=1',
        'origin',
        RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(version)
            ? version
            : 'refs/tags/$version:refs/tags/$version',
      ]);
      await runner.run('git', [
        '-C',
        staging.path,
        'checkout',
        '--detach',
        'FETCH_HEAD',
      ]);
    }
    await _validateSdk(repository, FlutterSdk(staging.path), version, runner);
    staging.renameSync(destination);
    // Flutter cache metadata and package_config can refer to the old location.
    // Running at its final path also verifies that the copied SDK relocates.
    await _validateSdk(repository, installed, version, runner);
    return installed;
  } finally {
    if (staging.existsSync()) staging.deleteSync(recursive: true);
  }
}

Future<void> _validateSdk(
  Repository repository,
  FlutterSdk sdk,
  String version,
  CommandRunner runner,
) async {
  // The container supplies curl, unzip, and other Flutter prerequisites. Its
  // Linux SDK remains directly usable by the supported Linux firmware host.
  final environment = _environment(repository);
  Directory(environment['HOME']!).createSync(recursive: true);
  await Toolchain(repository, runner).run(
    [sdk.flutter, '--version'],
    workingDirectory: sdk.root,
    environment: environment,
  );
  final file = File(p.join(sdk.root, 'bin/cache/flutter.version.json'));
  Map<dynamic, dynamic> metadata;
  try {
    metadata = jsonDecode(file.readAsStringSync()) as Map;
  } on Object {
    throw BuildFailure('Flutter $version did not produce valid SDK metadata.');
  }
  if (metadata['frameworkVersion'] != version &&
      metadata['frameworkRevision'] != version) {
    throw BuildFailure('SDK at ${sdk.root} does not match Flutter $version.');
  }
  if (!File(sdk.dart).existsSync()) {
    throw BuildFailure('Flutter $version is missing its bundled Dart SDK.');
  }
}

Map<String, String> _environment(Repository repository) => {
  'HOME': repository.path('build/bootstrap/home'),
  'CI': 'true',
  'FLUTTER_SUPPRESS_ANALYTICS': 'true',
  'DART_SUPPRESS_ANALYTICS': 'true',
  'PUB_CACHE': repository.path('build/bootstrap/pub-cache'),
};

Future<void> _copyDirectory(String source, String destination) async {
  await for (final entry in Directory(source).list(followLinks: false)) {
    final target = p.join(destination, p.basename(entry.path));
    if (entry is Directory) {
      Directory(target).createSync();
      await _copyDirectory(entry.path, target);
    } else if (entry is Link) {
      Link(target).createSync(entry.targetSync());
    } else if (entry is File) {
      await entry.copy(target);
    }
  }
}

void _linkSdk(String location, String sdkRoot) {
  final type = FileSystemEntity.typeSync(location, followLinks: false);
  if (type != FileSystemEntityType.notFound) {
    // An existing editor/FVM selection is a user preference, not our cache.
    return;
  }
  Directory(p.dirname(location)).createSync(recursive: true);
  try {
    Link(location).createSync(p.relative(sdkRoot, from: p.dirname(location)));
  } on FileSystemException catch (error) {
    throw BuildFailure('Cannot create Flutter SDK link $location: $error');
  }
}
