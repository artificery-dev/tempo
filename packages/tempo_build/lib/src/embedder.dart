import 'dart:io';

import 'package:path/path.dart' as p;

import 'context.dart';
import 'process.dart';

Future<int> embedderCommand(
  Repository repo,
  BuildConfig config,
  CommandRunner runner,
  List<String> args,
) async {
  if (args.length != 1 ||
      !['engine', 'build', 'test', 'clean', 'rev'].contains(args.single))
    throw BuildFailure('Expected app flutter-pi engine, build, or test', 2);
  final paths = ArtifactPaths(repo);
  if (args.single == 'clean') {
    final out = Directory(paths.embedder);
    if (out.existsSync()) out.deleteSync(recursive: true);
    return 0;
  }
  if (args.single == 'rev')
    return runner.run('git', [
      '-C',
      repo.path('app/flutter-pi/flutter-pi'),
      'log',
      '-1',
      '--format=%H %d %s',
    ]);
  if (args.single == 'engine') {
    final destination = paths.engine;
    final commit = config.string('flutter.engine_binaries.commit');
    final files = [
      'arm/libflutter_engine.so.release',
      'arm/libflutter_engine.so.debug',
      'arm/icudtl.dat',
      'arm/gen_snapshot_linux_x64_release',
      'arm/engine.version',
      'arm/flutter.version',
      'arm/dart-sdk.version',
    ];
    if (Directory(p.join(destination, '.git')).existsSync()) {
      final head = await runner.capture('git', [
        '-C',
        destination,
        'rev-parse',
        'HEAD',
      ], check: false);
      if (head.stdout.toString().trim() == commit &&
          files.every(
            (file) =>
                File(p.join(destination, file)).existsSync() &&
                File(p.join(destination, file)).lengthSync() > 0,
          ))
        return 0;
    }
    final temporary = Directory('$destination.fetch-$pid');
    if (temporary.existsSync())
      throw BuildFailure(
        'Engine fetch directory already exists: ${temporary.path}',
      );
    temporary.createSync(recursive: true);
    try {
      Future<ProcessResult> git(List<String> args) =>
          runner.capture('git', ['-C', temporary.path, ...args]);
      await git(['init', '-q']);
      await git([
        'remote',
        'add',
        'origin',
        config.string('flutter.engine_binaries.repo'),
      ]);
      await git(['config', 'core.sparseCheckout', 'true']);
      File(p.join(temporary.path, '.git/info/sparse-checkout'))
          .writeAsStringSync('${files.map((f) => '/$f').join('\n')}\n');
      await git([
        'fetch',
        '-q',
        '--depth',
        '1',
        '--filter=blob:none',
        'origin',
        commit,
      ]);
      await git([
        '-c',
        'advice.detachedHead=false',
        'checkout',
        '-q',
        '--detach',
        'FETCH_HEAD',
      ]);
      final head = await git(['rev-parse', 'HEAD']);
      if (head.stdout.toString().trim() != commit ||
          !files.every(
            (f) =>
                File(p.join(temporary.path, f)).existsSync() &&
                File(p.join(temporary.path, f)).lengthSync() > 0,
          ))
        throw BuildFailure(
          'Fetched engine is incomplete or does not match the configured commit',
        );
      if (Directory(destination).existsSync())
        Directory(destination).deleteSync(recursive: true);
      temporary.renameSync(destination);
    } finally {
      if (temporary.existsSync()) temporary.deleteSync(recursive: true);
    }
    stdout.writeln('Engine binaries: $destination');
    return 0;
  }
  final owner = repo.path('app/flutter-pi');
  final source = p.join(owner, 'flutter-pi');
  final toolchain = Toolchain(repo, runner);
  final output = paths.embedder;
  final socket = config.string('daemon.socket');
  if (!File(p.join(source, 'CMakeLists.txt')).existsSync())
    throw BuildFailure('Initialize the flutter-pi submodule first');
  final head = await runner.capture('git', ['-C', source, 'rev-parse', 'HEAD']);
  if (head.stdout.toString().trim() !=
      config.string('flutter.flutter_pi.commit'))
    throw BuildFailure(
      'flutter-pi submodule does not match flutter.flutter_pi.commit',
    );
  Directory(output).createSync(recursive: true);
  if (args.single == 'test') {
    if (!File(p.join(output, 'config.h')).existsSync())
      throw BuildFailure('Build flutter-pi before running its native tests');
    final binary = p.join(output, 'tests/handoff_client_test');
    Directory(p.dirname(binary)).createSync(recursive: true);
    await toolchain.run([
      'gcc',
      '-std=gnu11',
      '-Wall',
      '-Wextra',
      '-Wno-sign-compare',
      '-DNDEBUG',
      '-DTEMPOD_SOCKET="$socket"',
      '-I',
      p.join(owner, 'plugins'),
      '-I',
      p.join(source, 'src'),
      '-I',
      p.join(source, 'third_party/flutter_embedder_header/include'),
      '-I',
      '/usr/include/libdrm',
      '-I',
      output,
      p.join(owner, 'tests/handoff_client_test.c'),
      p.join(source, 'src/platformchannel.c'),
      p.join(source, 'src/util/collection.c'),
      '-lpthread',
      '-o',
      binary,
    ]);
    return toolchain.run([binary]);
  }
  final patches =
      Directory(p.join(owner, 'patches'))
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.patch'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final patch in patches) {
    final check = await runner.capture(
      'git',
      ['apply', '--check', patch.path],
      workingDirectory: source,
      check: false,
    );
    if (check.exitCode == 0) {
      await runner.run('git', ['apply', patch.path], workingDirectory: source);
    } else {
      final reverse = await runner.capture(
        'git',
        ['apply', '--reverse', '--check', patch.path],
        workingDirectory: source,
        check: false,
      );
      if (reverse.exitCode != 0)
        throw BuildFailure(
          'Patch neither applies nor is already applied: ${patch.path}',
        );
    }
  }
  File(p.join(owner, 'plugins/plymouth_handoff.c'))
      .copySync(p.join(source, 'src/plugins/plymouth_handoff.c'));
  await toolchain.run([
    'cmake',
    '-S',
    source,
    '-B',
    output,
    '-DCMAKE_TOOLCHAIN_FILE=${p.join(owner, 'toolchain-armhf.cmake')}',
    '-DCMAKE_BUILD_TYPE=Release',
    '-DCMAKE_C_FLAGS=-DTEMPOD_SOCKET=\\"$socket\\"',
    '-DENABLE_OPENGL=ON',
    '-DTRY_ENABLE_OPENGL=OFF',
    '-DENABLE_VULKAN=OFF',
    '-DENABLE_SESSION_SWITCHING=OFF',
    '-DBUILD_TEXT_INPUT_PLUGIN=ON',
    '-DBUILD_RAW_KEYBOARD_PLUGIN=ON',
    '-DBUILD_GSTREAMER_AUDIO_PLAYER_PLUGIN=OFF',
    '-DBUILD_GSTREAMER_VIDEO_PLAYER_PLUGIN=ON',
    '-DTRY_BUILD_GSTREAMER_VIDEO_PLAYER_PLUGIN=OFF',
    '-DBUILD_TEST_PLUGIN=OFF',
    '-DBUILD_SENTRY_PLUGIN=OFF',
  ]);
  await toolchain.run([
    'cmake',
    '--build',
    output,
    '-j${Platform.numberOfProcessors}',
  ]);
  if (!File(p.join(output, 'flutter-pi')).existsSync())
    throw BuildFailure('flutter-pi was not produced');
  return 0;
}
