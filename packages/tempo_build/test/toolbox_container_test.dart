import 'dart:io';
import 'package:tempo_build/tempo_build.dart';
import 'package:tempo_build/src/toolbox.dart';
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
    if (status != 0 && check)
      throw BuildFailure('injected tool failure', status);
    return status;
  }
}

void main() {
  // These describe the host's view of the toolchain, even when the suite
  // itself runs inside the container (as in CI).
  setUpAll(() => Toolchain.insideContainer = false);
  tearDownAll(() => Toolchain.insideContainer = null);
  late Directory temporary;
  late Repository repo;
  setUp(() {
    temporary = Directory.systemTemp.createTempSync(
      'toolbox project with spaces',
    );
    repo = Repository(temporary.path);
  });
  tearDown(() => temporary.deleteSync(recursive: true));
  test(
    'Wasm never invokes host Rust or bindgen and preserves path arguments',
    () async {
      final runner = RecordingRunner();
      final tools = ToolboxBuildTools(repo, runner);
      await tools.cargo([
        'build',
        '--locked',
        '--target',
        'wasm32-unknown-unknown',
      ], wasm: true);
      await tools.bindgen(repo.path('toolbox/app/web/pkg'));
      expect(runner.calls.map((c) => c.first), everyElement('podman'));
      expect(runner.calls.first, contains('CARGO_TARGET_DIR=${tools.output}'));
      expect(runner.calls.first, contains('${tools.rust}/Cargo.toml'));
      expect(runner.calls.last, contains('/usr/local/bin/wasm-bindgen'));
      expect(runner.calls.last.last, repo.path('toolbox/app/web/pkg'));
    },
  );
  test(
    'browser tests resolve and execute beside container Node with local cache',
    () async {
      final runner = RecordingRunner();
      final tools = ToolboxBuildTools(repo, runner);
      const testFile = 'test/browser protocol_test.dart';
      expect(await tools.browserTests([testFile]), 0);
      expect(runner.calls, hasLength(4));
      expect(runner.calls.map((c) => c.first), everyElement('podman'));
      expect(
        runner.calls[2],
        contains('PUB_CACHE=${repo.path('build/toolbox/test-pub-cache')}'),
      );
      expect(runner.calls.last.sublist(runner.calls.last.length - 5), [
        '/opt/toolbox-test/dart-sdk/bin/dart',
        'test',
        '-p',
        'node',
        testFile,
      ]);
    },
  );
  test(
    'container check failures aggregate; build failures remain failures',
    () async {
      final runner = RecordingRunner()..status = 7;
      final tools = ToolboxBuildTools(repo, runner);
      expect(await tools.cargo(['test'], wasm: true, check: false), 7);
      await expectLater(
        tools.cargo(['build'], wasm: true),
        throwsA(isA<BuildFailure>()),
      );
    },
  );
}
