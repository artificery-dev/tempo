import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'context.dart';
import 'process.dart';

/// Bytes from a URL. Tests substitute a fake; the build uses [httpFetch].
typedef Fetch = Future<List<int>> Function(Uri uri);

/// The Cadence daemon ships as a release of its public repository. Tempo
/// installs the armhf bundle tarball from the configured release, verified
/// against the pinned tarball checksum and then the bundle's own manifest.
class CadenceRelease {
  CadenceRelease({
    required this.repository,
    required this.tag,
    required this.bundleSha256,
  });

  factory CadenceRelease.fromConfig(BuildConfig config) {
    final repository = Uri.tryParse(config.string('cadence.repository'));
    if (repository == null ||
        !repository.isScheme('https') ||
        repository.pathSegments.where((s) => s.isNotEmpty).length != 2) {
      throw BuildFailure(
        'cadence.repository must be an https URL of the form '
        'https://host/owner/name',
      );
    }
    final sha = config.string('cadence.bundle_sha256').toLowerCase();
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(sha)) {
      throw BuildFailure('cadence.bundle_sha256 must be a SHA-256 hex digest');
    }
    return CadenceRelease(
      repository: repository,
      tag: config.string('cadence.release'),
      bundleSha256: sha,
    );
  }

  final Uri repository;
  final String tag;
  final String bundleSha256;

  /// The Forgejo/Gitea release endpoint for [tag].
  Uri get api {
    final segments = repository.pathSegments.where((s) => s.isNotEmpty);
    return repository.replace(
      pathSegments: [
        'api',
        'v1',
        'repos',
        ...segments,
        'releases',
        'tags',
        tag,
      ],
    );
  }
}

/// The armhf bundle asset of a release document, as (name, download URL).
(String, Uri) cadenceArmhfAsset(Object? release) {
  if (release is! Map || release['assets'] is! List) {
    throw BuildFailure('Cadence release document has no assets');
  }
  final matches = <(String, Uri)>[];
  for (final asset in release['assets'] as List) {
    if (asset is! Map) continue;
    final name = asset['name'];
    final url = asset['browser_download_url'];
    if (name is! String || url is! String) continue;
    if (RegExp(r'^cadenced-[^/]+-linux-armhf\.tar\.gz$').hasMatch(name)) {
      final uri = Uri.tryParse(url);
      if (uri == null || !uri.isScheme('https')) {
        throw BuildFailure('Cadence asset $name has no https download URL');
      }
      matches.add((name, uri));
    }
  }
  if (matches.length != 1) {
    throw BuildFailure(
      'Expected exactly one cadenced armhf bundle in the release, '
      'found ${matches.length}',
    );
  }
  return matches.single;
}

Future<List<int>> httpFetch(Uri uri) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    request.followRedirects = true;
    final response = await request.close();
    if (response.statusCode != 200) {
      await response.drain<void>();
      throw BuildFailure('GET $uri failed: HTTP ${response.statusCode}');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  } finally {
    client.close(force: true);
  }
}

/// Install the configured Cadence release's armhf bundle under
/// build/os/cadence/arm/bundle, where rootfs staging expects it.
Future<int> cadenceCommand(
  Repository repo,
  BuildConfig config,
  CommandRunner runner,
  List<String> args, {
  Fetch fetch = httpFetch,
}) async {
  if (args.length != 1 || args.single != 'fetch') {
    throw BuildFailure('Expected cadence fetch', 2);
  }
  await fetchCadenceBundle(repo, config, runner, fetch: fetch);
  return 0;
}

Future<String> fetchCadenceBundle(
  Repository repo,
  BuildConfig config,
  CommandRunner runner, {
  Fetch fetch = httpFetch,
}) async {
  final release = CadenceRelease.fromConfig(config);
  final document = jsonDecode(utf8.decode(await fetch(release.api)));
  final (name, url) = cadenceArmhfAsset(document);
  final archive = File(repo.path('build/os/cadence/armhf/$name'));
  Future<String> digestOf(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();
  if (!archive.existsSync() ||
      await digestOf(archive) != release.bundleSha256) {
    archive.parent.createSync(recursive: true);
    await archive.writeAsBytes(await fetch(url), flush: true);
  }
  final digest = await digestOf(archive);
  if (digest != release.bundleSha256) {
    throw BuildFailure(
      'Cadence bundle $name does not match cadence.bundle_sha256 '
      '(expected ${release.bundleSha256}, got $digest). Pin the checksum '
      'of the release you intend to ship.',
    );
  }
  final bundle = repo.path('build/os/cadence/arm/bundle');
  final directory = Directory(bundle);
  if (directory.existsSync()) directory.deleteSync(recursive: true);
  directory.createSync(recursive: true);
  // The tarball carries one top-level cadenced/ directory.
  await runner.run('tar', [
    '-xzf',
    archive.path,
    '--strip-components=1',
    '-C',
    bundle,
  ]);
  if (!File(p.join(bundle, 'manifest.json')).existsSync()) {
    throw BuildFailure(
      'Cadence bundle $name has no top-level cadenced/manifest.json',
    );
  }
  await verifyCadenceBundle(bundle);
  final manifest = jsonDecode(
    File(p.join(bundle, 'manifest.json')).readAsStringSync(),
  );
  stdout.writeln(
    'Cadence bundle: $bundle (${release.tag}, '
    '${(manifest as Map)['sourceCommit']})',
  );
  return bundle;
}

Future<Map<String, String>> verifyCadenceBundle(String directory) async {
  final manifest = File(p.join(directory, 'manifest.json'));
  if (!manifest.existsSync())
    throw BuildFailure(
      'Fetch Cadence (toolbox dev cadence fetch) before staging rootfs',
    );
  final document = jsonDecode(manifest.readAsStringSync());
  if (document is! Map ||
      document['target'] != 'arm' ||
      document['sourceCommit'] is! String ||
      !RegExp(r'^[a-f0-9]{40}$').hasMatch(document['sourceCommit'] as String) ||
      document['files'] is! Map) {
    throw BuildFailure('Invalid Cadence ARM bundle manifest');
  }
  final files = <String, String>{};
  for (final entry in (document['files'] as Map).entries) {
    if (entry.key is! String || entry.value is! String) {
      throw BuildFailure('Invalid Cadence bundle entry');
    }
    final relative = entry.key as String;
    if (p.isAbsolute(relative) ||
        relative.split(RegExp(r'[/\\]')).contains('..') ||
        RegExp(r'[\x00-\x1f]').hasMatch(relative) ||
        relative == 'manifest.json') {
      throw BuildFailure('Invalid Cadence bundle path: $relative');
    }
    final path = p.join(directory, relative);
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
            FileSystemEntityType.file ||
        (await sha256.bind(File(path).openRead()).first).toString() !=
            entry.value) {
      throw BuildFailure('Cadence bundle checksum failed: $relative');
    }
    files[relative] = entry.value as String;
  }
  for (final required in [
    'bin/cadenced',
    'lib/libsqlite3.so',
    'lib/libcadence_probe.so',
    'LICENSE',
  ]) {
    if (!files.containsKey(required)) {
      throw BuildFailure('Cadence bundle is missing $required');
    }
  }
  for (final relative in files.keys) {
    if (!relative.startsWith('bin/') && !relative.endsWith('.so')) continue;
    final header = File(p.join(directory, relative)).openSync();
    try {
      final bytes = header.readSync(20);
      // ELF, 32-bit, little-endian, e_machine ARM (0x28).
      if (bytes.length < 20 ||
          bytes[0] != 0x7f ||
          bytes[1] != 0x45 ||
          bytes[2] != 0x4c ||
          bytes[3] != 0x46 ||
          bytes[4] != 1 ||
          bytes[5] != 1 ||
          bytes[18] != 0x28 ||
          bytes[19] != 0) {
        throw BuildFailure('Cadence bundle $relative is not a 32-bit ARM ELF');
      }
    } finally {
      header.closeSync();
    }
  }
  if (!File(p.join(directory, 'LICENSE')).readAsStringSync().contains('MIT')) {
    throw BuildFailure('Cadence bundle LICENSE must be the MIT license');
  }
  return files;
}
