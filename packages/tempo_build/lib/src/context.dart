import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'process.dart';

class Repository {
  Repository(String root) : root = p.normalize(p.absolute(root));
  final String root;
  String path(String relative) => p.join(root, relative);

  /// Linked worktrees and their submodules keep Git metadata outside the
  /// mounted checkout. Build-time revision checks need that metadata read-only.
  Iterable<String> get externalGitMetadata sync* {
    final marker = File(path('.git'));
    if (!marker.existsSync()) return;
    final value = marker.readAsStringSync().trim();
    if (!value.startsWith('gitdir: ')) return;
    var metadata = p.normalize(p.join(root, value.substring(8)));
    final common = File(p.join(metadata, 'commondir'));
    if (common.existsSync()) {
      metadata = p.normalize(
        p.join(metadata, common.readAsStringSync().trim()),
      );
    }
    if (metadata != root && !p.isWithin(root, metadata)) yield metadata;
  }

  static bool isRoot(String path) =>
      File(p.join(path, 'config.yaml')).existsSync() &&
      File(p.join(path, 'pubspec.yaml')).existsSync() &&
      Directory(p.join(path, 'app')).existsSync();
  static Repository locate({String? explicitRoot, String? start}) {
    final selected = explicitRoot ?? Platform.environment['TEMPO_REPO'];
    if (selected != null) {
      if (!isRoot(selected))
        throw BuildFailure('Not a Tempo checkout: $selected', 2);
      return Repository(selected);
    }
    final starts = [
      start ?? Directory.current.path,
      if (Platform.script.scheme == 'file')
        p.dirname(Platform.script.toFilePath()),
    ];
    for (var current in starts.map(p.absolute)) {
      while (true) {
        if (isRoot(current)) return Repository(current);
        final parent = p.dirname(current);
        if (parent == current) break;
        current = parent;
      }
    }
    throw BuildFailure(
      'Cannot locate a Tempo checkout; pass --repo PATH or set TEMPO_REPO.',
      2,
    );
  }

  String existing(String target, String legacy) =>
      FileSystemEntity.typeSync(path(target)) != FileSystemEntityType.notFound
      ? path(target)
      : path(legacy);
}

Object? plainYaml(Object? value) {
  if (value is Map)
    return {
      for (final entry in value.entries)
        entry.key.toString(): plainYaml(entry.value),
    };
  if (value is List) return value.map(plainYaml).toList();
  return value;
}

Object? deepMerge(Object? base, Object? overlay) {
  if (base is Map<String, Object?> && overlay is Map<String, Object?>) {
    return {
      ...base,
      for (final entry in overlay.entries)
        entry.key: deepMerge(base[entry.key], entry.value),
    };
  }
  return overlay;
}

class BuildConfig {
  BuildConfig(this.repository, this.values);
  final Repository repository;
  final Map<String, Object?> values;
  factory BuildConfig.load(Repository repository, {bool expandKeys = true}) {
    Map<String, Object?> read(String path) {
      final value = plainYaml(loadYaml(File(path).readAsStringSync()));
      if (value == null) return {};
      if (value is! Map<String, Object?>)
        throw BuildFailure('Configuration must be a mapping: $path');
      return value;
    }

    var values = read(repository.path('config.yaml'));
    final local = repository.path('config.local.yaml');
    if (File(local).existsSync())
      values = deepMerge(values, read(local)) as Map<String, Object?>;
    final config = BuildConfig(repository, values);
    if (expandKeys) config._expandKeys();
    return config;
  }
  Object? get(String key, {Object? fallback}) {
    Object? value = values;
    for (final part in key.split('.')) {
      if (value is! Map || !value.containsKey(part)) return fallback;
      value = value[part];
    }
    return value;
  }

  String string(String key) {
    final value = get(key);
    if (value == null || value is Map || value is List)
      throw BuildFailure('Missing scalar configuration: $key');
    return value.toString();
  }

  Object? redacted([String? key]) {
    final copy = jsonDecode(jsonEncode(values)) as Map<String, dynamic>;
    if (copy['user'] is Map &&
        copy['user']['password'] != null &&
        copy['user']['password'] != '')
      copy['user']['password'] = '<redacted; use --raw>';
    return key == null ? copy : BuildConfig(repository, copy).get(key);
  }

  void _expandKeys() {
    final keys = get('user.ssh_keys');
    if (keys is! List) return;
    final out = <String>[];
    for (final entry in keys) {
      final value = entry.toString().trim();
      if (value.isEmpty) continue;
      if (RegExp(r'^(ssh-|ecdsa-|sk-ssh-|sk-ecdsa-)').hasMatch(value)) {
        out.add(value);
        continue;
      }
      final match = RegExp(
        r'''^\{\{\s*file\(\s*["']?(.+?)["']?\s*\)\s*\}\}$''',
      ).firstMatch(value);
      if (match == null &&
          !value.startsWith('~') &&
          !value.startsWith('/') &&
          !value.startsWith('./'))
        throw BuildFailure(
          'user.ssh_keys entry must be a public key or file reference',
        );
      var file = match?.group(1) ?? value;
      if (file.startsWith('~/'))
        file = p.join(
          Platform.environment['TEMPO_CONFIG_HOME'] ??
              Platform.environment['HOME'] ??
              Platform.environment['USERPROFILE'] ??
              '',
          file.substring(2),
        );
      if (!p.isAbsolute(file)) file = repository.path(file);
      if (!File(file).existsSync())
        throw BuildFailure('SSH public key file is missing: $file');
      out.addAll(
        File(file)
            .readAsLinesSync()
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty && !line.startsWith('#')),
      );
    }
    (values['user'] as Map)['ssh_keys'] = out;
  }
}

class ArtifactPaths {
  ArtifactPaths(this.repository);
  final Repository repository;
  String get app => repository.path('build/app');
  String get bundle => p.join(app, 'flutter_assets');
  String get engine => repository.path('build/app/engine-binaries');
  String get embedder => repository.path('build/app/flutter-pi');
  String get toolbox => repository.path('build/toolbox');
  String get rust => repository.path('build/rust');
  String os(String component) => repository.path('build/os/$component');
}

class FlutterSdk {
  FlutterSdk(this.root);
  final String root;
  String get flutter =>
      p.join(root, 'bin', Platform.isWindows ? 'flutter.bat' : 'flutter');
  String get dart => p.join(
    root,
    'bin/cache/dart-sdk/bin',
    Platform.isWindows ? 'dart.exe' : 'dart',
  );
  static Future<FlutterSdk> discover(
    BuildConfig config,
    CommandRunner runner, {
    String? version,
  }) async {
    version ??= config.string('flutter.sdk_version');
    final candidates = <String>[];
    final override = Platform.environment['TEMPO_FLUTTER_SDK'];
    if (override != null) candidates.add(override);
    candidates.add(config.repository.path('build/sdks/flutter/$version'));
    final rc = File(config.repository.path('.fvmrc'));
    if (version == config.string('flutter.sdk_version') &&
        rc.existsSync() &&
        (jsonDecode(rc.readAsStringSync()) as Map)['flutter'] != version)
      stderr.writeln(
        'warning: .fvmrc differs from configured Flutter $version',
      );
    FlutterSdk? matchingSdk(Iterable<String> roots) {
      for (final root in roots) {
        final sdk = FlutterSdk(root);
        if (!File(sdk.flutter).existsSync()) continue;
        final metadata = File(p.join(root, 'bin/cache/flutter.version.json'));
        if (metadata.existsSync()) {
          final info = jsonDecode(metadata.readAsStringSync()) as Map;
          if (info['frameworkVersion'] != version &&
              info['frameworkRevision'] != version)
            continue;
        }
        return sdk;
      }
      return null;
    }

    final local = matchingSdk(candidates);
    if (local != null) return local;
    candidates.clear();
    try {
      final result = await runner.capture(
        'fvm',
        ['api', 'context'],
        workingDirectory: config.repository.root,
        check: false,
      );
      final cache =
          (jsonDecode(result.stdout as String)
              as Map)['context']['config']['cachePath'];
      if (cache is String && cache.isNotEmpty)
        candidates.add(p.join(cache, 'versions', version));
    } on Object {
      /* Explicit path and conventional cache remain available. */
    }
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home != null) candidates.add(p.join(home, 'fvm/versions', version));
    final cached = matchingSdk(candidates);
    if (cached != null) return cached;
    throw BuildFailure(
      'Flutter $version is missing. Run toolbox dev bootstrap or set TEMPO_FLUTTER_SDK.',
    );
  }
}

class Toolchain {
  Toolchain(this.repository, this.runner);
  final Repository repository;
  final CommandRunner runner;
  Future<int> build(List<String> arguments) => runner.run('podman', [
    'build',
    ...arguments,
    '-t',
    'tempo-toolchain',
    '-f',
    repository.path('platform/toolchain/Containerfile'),
    repository.root,
  ]);
  Future<int> run(
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String> environment = const {},
    Iterable<String> readOnlyPaths = const [],
    bool check = true,
  }) async {
    if (Platform.environment['TEMPO_TOOLCHAIN'] != null)
      return runner.run(
        arguments.first,
        arguments.skip(1).toList(),
        workingDirectory: workingDirectory ?? repository.root,
        environment: environment,
        check: check,
      );
    final exists = await runner.capture('podman', [
      'image',
      'exists',
      'tempo-toolchain',
    ], check: false);
    if (exists.exitCode != 0) await build([]);
    return runner.run('podman', [
      'run',
      '--rm',
      '-i',
      if (stdin.hasTerminal) '-t',
      '-v',
      '${repository.root}:${repository.root}',
      for (final path in {
        ...repository.externalGitMetadata,
        ...readOnlyPaths,
      }) ...['-v', '$path:$path:ro'],
      '-w',
      workingDirectory ?? repository.root,
      '--userns=keep-id',
      '-e',
      'TEMPO_TOOLCHAIN=1',
      '-e',
      'CARGO_HOME=${repository.path('build/cargo')}',
      for (final entry in environment.entries) ...[
        '-e',
        '${entry.key}=${entry.value}',
      ],
      'tempo-toolchain',
      ...arguments,
    ], check: check);
  }
}
