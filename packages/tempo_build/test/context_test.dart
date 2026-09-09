import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:tempo_build/tempo_build.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late Repository repo;
  setUp(() {
    temporary = Directory.systemTemp.createTempSync('tempo build test ');
    repo = Repository(temporary.path);
    Directory(repo.path('app')).createSync();
    File(
      repo.path('pubspec.yaml'),
    ).writeAsStringSync('name: tempo_workspace\n');
    File(repo.path('config.yaml')).writeAsStringSync(
      'user:\n  name: tempo\n  password: base\n  groups: [audio, video]\nflutter:\n  sdk_version: 3.44.9\n',
    );
  });
  tearDown(() => temporary.deleteSync(recursive: true));
  test('container revision checks can reach linked worktree metadata', () {
    final common = Directory.systemTemp.createTempSync('tempo git metadata ');
    try {
      final metadata = Directory(p.join(common.path, 'worktrees', 'test'))
        ..createSync(recursive: true);
      File(p.join(metadata.path, 'commondir')).writeAsStringSync('../..\n');
      File(repo.path('.git')).writeAsStringSync('gitdir: ${metadata.path}\n');
      expect(repo.externalGitMetadata.toList(), [common.path]);
      File(repo.path('.git')).deleteSync();
      Directory(repo.path('.git')).createSync();
      expect(repo.externalGitMetadata, isEmpty);
    } finally {
      common.deleteSync(recursive: true);
    }
  });
  test('locates arbitrary descendants without old toolchain marker', () {
    final deep = Directory(repo.path('build/arbitrary directory/nested'))
      ..createSync(recursive: true);
    expect(Repository.locate(start: deep.path).root, repo.root);
    expect(
      () => Repository.locate(explicitRoot: deep.path),
      throwsA(isA<BuildFailure>()),
    );
  });
  test('local maps merge and lists and null replace', () {
    File(
      repo.path('config.local.yaml'),
    ).writeAsStringSync('user:\n  password: null\n  groups: [custom]\n');
    final cfg = BuildConfig.load(repo);
    expect(cfg.get('user.name'), 'tempo');
    expect(cfg.get('user.groups'), ['custom']);
    expect(cfg.get('user.password'), isNull);
  });
  test('redaction includes directly selected secrets and preserves source', () {
    final cfg = BuildConfig.load(repo);
    expect(cfg.redacted('user.password'), '<redacted; use --raw>');
    expect((cfg.redacted('user') as Map)['password'], '<redacted; use --raw>');
    expect(cfg.get('user.password'), 'base');
  });
  test('expands public keys relative to repository with comments', () {
    File(
      repo.path('key.pub'),
    ).writeAsStringSync('# comment\nssh-ed25519 test fixture\n\n');
    File(
      repo.path('config.local.yaml'),
    ).writeAsStringSync('user:\n  ssh_keys: ["{{ file(./key.pub) }}"]\n');
    expect(BuildConfig.load(repo).get('user.ssh_keys'), [
      'ssh-ed25519 test fixture',
    ]);
  });
  test('rejects malformed configuration and missing key references', () {
    File(
      repo.path('config.local.yaml'),
    ).writeAsStringSync('user:\n  ssh_keys: [./missing.pub]\n');
    expect(() => BuildConfig.load(repo), throwsA(isA<BuildFailure>()));
    File(repo.path('config.local.yaml')).writeAsStringSync('[not, a, map]\n');
    expect(() => BuildConfig.load(repo), throwsA(isA<BuildFailure>()));
  });
  test('process preserves argument boundaries and failure exit code', () async {
    final runner = CommandRunner();
    final script = File(repo.path('args.dart'))
      ..writeAsStringSync(
        'import "dart:io"; void main(List<String> args) { stdout.write(args.single); }',
      );
    const argument = 'space and dollar \$() and single quote \' and `ticks`';
    final result = await runner.capture(Platform.resolvedExecutable, [
      script.path,
      argument,
    ]);
    expect(result.stdout, argument);
    final failure = File(repo.path('exit.dart'))
      ..writeAsStringSync('import "dart:io"; void main() { exit(23); }');
    await expectLater(
      runner.run(Platform.resolvedExecutable, [failure.path]),
      throwsA(isA<BuildFailure>().having((e) => e.code, 'code', 23)),
    );
  });
  test(
    'dispatcher keeps dev dependencies lazy for help and catches async failures',
    () async {
      expect(
        await runDeveloperCommand(['--help'], repositoryRoot: '/missing'),
        0,
      );
      expect(
        await runDeveloperCommand(['app', 'deploy'], repositoryRoot: repo.root),
        1,
      );
      expect(
        await runDeveloperCommand(['nonsense'], repositoryRoot: repo.root),
        2,
      );
    },
  );
  test('secret hashing preserves surrounding bytes and is idempotent', () async {
    if (Platform.isWindows) return;
    final file = File(repo.path('config.local.yaml'));
    file.writeAsStringSync(
      '# header\nuser:\n  # password comment\n  password: "test password"\n  groups: [audio] # keep\n',
    );
    expect(
      await runDeveloperCommand(['secrets', 'hash'], repositoryRoot: repo.root),
      0,
    );
    final first = file.readAsStringSync();
    expect(first, startsWith('# header\nuser:\n  # password comment\n'));
    expect(first, endsWith('  groups: [audio] # keep\n'));
    expect(first, isNot(contains('test password')));
    expect(file.statSync().mode & 0x1ff, 0x180);
    expect(
      await runDeveloperCommand(['secrets', 'hash'], repositoryRoot: repo.root),
      0,
    );
    expect(file.readAsStringSync(), first);
  });
  test('clean preserves runtime artifacts and unrelated outputs', () async {
    final paths = ArtifactPaths(repo);
    for (final dir in [
      paths.bundle,
      paths.engine,
      paths.embedder,
      paths.toolbox,
    ])
      Directory(dir).createSync(recursive: true);
    expect(
      await runDeveloperCommand(['app', 'clean'], repositoryRoot: repo.root),
      0,
    );
    expect(Directory(paths.bundle).existsSync(), false);
    for (final dir in [paths.engine, paths.embedder, paths.toolbox])
      expect(Directory(dir).existsSync(), true);
    expect(p.isWithin(repo.root, paths.app), true);
  });
}
