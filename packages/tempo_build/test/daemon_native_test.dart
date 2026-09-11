import 'dart:io';
import 'package:tempo_build/tempo_build.dart';
import 'package:tempo_build/src/daemon_native.dart';
import 'package:test/test.dart';

class RecordingRunner extends CommandRunner {
  final calls = <List<String>>[];
  int status = 0;
  @override
  Future<ProcessResult> capture(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool check = true,
  }) async => ProcessResult(0, 0, '', '');
  @override
  Future<int> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Stream<List<int>>? input,
    bool check = true,
  }) async {
    calls.add([executable, ...arguments]);
    if (status != 0 && check) throw BuildFailure('Cargo failed', status);
    return status;
  }
}

void main() {
  // These describe the host's view of the toolchain, even when the suite
  // itself runs inside the container (as in CI).
  setUpAll(() => Toolchain.insideContainer = false);
  tearDownAll(() => Toolchain.insideContainer = null);
  final repo = Repository('/tmp/daemon project');
  test(
    'Linux host build, test and checks use container with host output path',
    () async {
      final runner = RecordingRunner();
      for (final args in [
        ['build', '-p', 'tempod', '--lib', '--bin', 'tempod', '--release'],
        ['test', '-p', 'tempod'],
        ['fmt', '--all', '--', '--check'],
        ['clippy', '-p', 'tempod', '--all-targets', '--', '-D', 'warnings'],
      ]) {
        await daemonHostCargo(repo, runner, args, operatingSystem: 'linux');
        final call = runner.calls.last;
        expect(call.first, 'podman');
        expect(call, contains('CARGO_TARGET_DIR=${repo.path('build/rust')}'));
        expect(call.sublist(call.length - args.length - 1), ['cargo', ...args]);
        expect(call, isNot(contains('armv7-unknown-linux-gnueabihf')));
      }
    },
  );
  test(
    'aggregate checks preserve status and builds fail on container error',
    () async {
      final runner = RecordingRunner()..status = 9;
      expect(
        await daemonHostCargo(
          repo,
          runner,
          ['clippy'],
          check: false,
          operatingSystem: 'linux',
        ),
        9,
      );
      await expectLater(
        daemonHostCargo(repo, runner, ['build'], operatingSystem: 'linux'),
        throwsA(isA<BuildFailure>()),
      );
    },
  );
  test('unsupported native host ABI is rejected before spawning commands', () {
    for (final host in ['macos', 'windows']) {
      final runner = RecordingRunner();
      expect(
        () => daemonHostCargo(repo, runner, ['build'], operatingSystem: host),
        throwsA(isA<BuildFailure>()),
      );
      expect(runner.calls, isEmpty);
    }
  });
}
