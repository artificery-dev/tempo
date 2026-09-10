import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:tempo_build/src/cadence.dart';
import 'package:tempo_build/src/context.dart';
import 'package:tempo_build/src/process.dart';
import 'package:test/test.dart';

void main() {
  late Directory bundle;
  late Map<String, String> hashes;
  void manifest() => File('${bundle.path}/manifest.json').writeAsStringSync(
    jsonEncode({'target': 'arm', 'sourceCommit': 'a' * 40, 'files': hashes}),
  );
  setUp(() {
    bundle = Directory.systemTemp.createTempSync('cadence-bundle-');
    hashes = {};
    for (final path in [
      'bin/cadenced',
      'lib/libcadence_probe.so',
      'lib/libsqlite3.so',
      'LICENSE',
    ]) {
      final bytes = path == 'LICENSE'
          ? utf8.encode('MIT')
          : <int>[127, 69, 76, 70, 1, 1, ...List.filled(12, 0), 40, 0];
      final file = File('${bundle.path}/$path');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(bytes);
      hashes[path] = sha256.convert(bytes).toString();
    }
    manifest();
  });
  tearDown(() => bundle.deleteSync(recursive: true));
  test('verifies complete ARM bundle and license', () async {
    expect(await verifyCadenceBundle(bundle.path), hashes);
  });
  test('rejects x64 runtime even when its checksum matches', () async {
    final file = File('${bundle.path}/bin/cadenced');
    final bytes = file.readAsBytesSync()
      ..[4] = 2
      ..[18] = 62;
    file.writeAsBytesSync(bytes);
    hashes['bin/cadenced'] = sha256.convert(bytes).toString();
    manifest();
    await expectLater(
      verifyCadenceBundle(bundle.path),
      throwsA(isA<BuildFailure>()),
    );
  });
  test('rejects missing native library and modified payload', () async {
    File('${bundle.path}/lib/libcadence_probe.so').deleteSync();
    await expectLater(
      verifyCadenceBundle(bundle.path),
      throwsA(isA<BuildFailure>()),
    );
    hashes.remove('lib/libcadence_probe.so');
    manifest();
    await expectLater(
      verifyCadenceBundle(bundle.path),
      throwsA(isA<BuildFailure>()),
    );
  });
  test('rejects paths outside the bundle', () async {
    hashes['../outside'] = 'a' * 64;
    manifest();
    await expectLater(
      verifyCadenceBundle(bundle.path),
      throwsA(isA<BuildFailure>()),
    );
  });
  group('release', _releaseTests);
}

void _releaseTests() {
  late Directory root;
  late Repository repo;
  late Map<String, String> hashes;
  late List<int> tarball;
  late String digest;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('cadence-release-');
    repo = Repository(root.path);
    final source = Directory('${root.path}/source/cadenced')
      ..createSync(recursive: true);
    hashes = {};
    for (final path in [
      'bin/cadenced',
      'lib/libcadence_probe.so',
      'lib/libsqlite3.so',
      'LICENSE',
    ]) {
      final bytes = path == 'LICENSE'
          ? utf8.encode('MIT')
          : <int>[127, 69, 76, 70, 1, 1, ...List.filled(12, 0), 40, 0];
      final file = File('${source.path}/$path');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(bytes);
      hashes[path] = sha256.convert(bytes).toString();
    }
    File('${source.path}/manifest.json').writeAsStringSync(
      jsonEncode({'target': 'arm', 'sourceCommit': 'b' * 40, 'files': hashes}),
    );
    final result = await Process.run('tar', [
      '-czf',
      '${root.path}/bundle.tar.gz',
      '-C',
      '${root.path}/source',
      'cadenced',
    ]);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    tarball = File('${root.path}/bundle.tar.gz').readAsBytesSync();
    digest = sha256.convert(tarball).toString();
  });
  tearDown(() => root.deleteSync(recursive: true));

  BuildConfig config({String? sha, String tag = 'v1.2.3'}) =>
      BuildConfig(repo, {
        'cadence': {
          'repository': 'https://forge.example/artificery/cadence',
          'release': tag,
          'bundle_sha256': sha ?? digest,
        },
      });
  Map<String, Object?> release({
    List<String> names = const ['cadenced-1.2.3-linux-armhf.tar.gz'],
  }) => {
    'tag_name': 'v1.2.3',
    'assets': [
      for (final name in [
        'cadenced-1.2.3-linux-amd64.tar.gz',
        'cadenced_1.2.3_armhf.deb',
        ...names,
      ])
        {
          'name': name,
          'browser_download_url':
              'https://forge.example/artificery/cadence/releases/download/v1.2.3/$name',
        },
    ],
  };
  Fetch fake(Map<String, Object?> document, {List<Uri>? log}) => (uri) async {
    log?.add(uri);
    if (uri.path.endsWith('/releases/tags/v1.2.3')) {
      expect(
        uri.toString(),
        'https://forge.example/api/v1/repos/artificery/cadence/releases/tags/v1.2.3',
      );
      return utf8.encode(jsonEncode(document));
    }
    if (uri.path.endsWith('-linux-armhf.tar.gz')) return tarball;
    throw StateError('Unexpected fetch $uri');
  };

  test('installs and verifies the armhf bundle from the release', () async {
    final log = <Uri>[];
    final bundle = await fetchCadenceBundle(
      repo,
      config(),
      CommandRunner(),
      fetch: fake(release(), log: log),
    );
    expect(bundle, repo.path('build/os/cadence/arm/bundle'));
    expect(await verifyCadenceBundle(bundle), hashes);
    expect(log.length, 2);
    // A second fetch reuses the verified tarball without downloading again.
    log.clear();
    await fetchCadenceBundle(
      repo,
      config(),
      CommandRunner(),
      fetch: fake(release(), log: log),
    );
    expect(log.length, 1);
  });

  test('rejects a tarball that does not match the pinned checksum', () async {
    await expectLater(
      fetchCadenceBundle(
        repo,
        config(sha: 'a' * 64),
        CommandRunner(),
        fetch: fake(release()),
      ),
      throwsA(isA<BuildFailure>()),
    );
    expect(
      Directory(repo.path('build/os/cadence/arm/bundle')).existsSync(),
      isFalse,
    );
  });

  test('requires exactly one armhf bundle asset', () async {
    for (final names in [
      <String>[],
      [
        'cadenced-1.2.3-linux-armhf.tar.gz',
        'cadenced-1.2.4-linux-armhf.tar.gz',
      ],
    ]) {
      await expectLater(
        fetchCadenceBundle(
          repo,
          config(),
          CommandRunner(),
          fetch: fake(release(names: names)),
        ),
        throwsA(isA<BuildFailure>()),
      );
    }
  });

  test('configuration must name an https repository and a hex checksum', () {
    expect(
      () => CadenceRelease.fromConfig(config(sha: 'nope')),
      throwsA(isA<BuildFailure>()),
    );
    expect(
      () => CadenceRelease.fromConfig(
        BuildConfig(repo, {
          'cadence': {
            'repository': 'ssh://forge/x/y',
            'release': 'v1',
            'bundle_sha256': 'a' * 64,
          },
        }),
      ),
      throwsA(isA<BuildFailure>()),
    );
    final parsed = CadenceRelease.fromConfig(config());
    expect(
      parsed.api.toString(),
      'https://forge.example/api/v1/repos/artificery/cadence/releases/tags/v1.2.3',
    );
  });
}
