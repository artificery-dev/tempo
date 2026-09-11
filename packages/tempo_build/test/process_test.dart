import 'package:tempo_build/src/process.dart';
import 'package:test/test.dart';

void main() {
  test("a child never hears the tool's own Dart root", () {
    final environment = childEnvironment(
      {
        'PATH': '/bin',
        'DART_ROOT': '/opt/dart-sdk',
        'DASH__TOOL': 'dart-tool',
        'DART_SDK': '/opt/dart-sdk',
      },
      {'HOME': '/tmp/home'},
    );
    expect(environment, {
      'PATH': '/bin',
      'DART_SDK': '/opt/dart-sdk',
      'HOME': '/tmp/home',
    });
  });

  test(
    'the runner passes the scrubbed environment to real children',
    () async {
      final result = await CommandRunner().capture(
        'env',
        [],
        environment: {'TEMPO_PROCESS_TEST': 'yes'},
      );
      final lines = (result.stdout as String).split('\n');
      expect(lines, contains('TEMPO_PROCESS_TEST=yes'));
      expect(lines.where((l) => l.startsWith('DART_ROOT=')), isEmpty);
      expect(lines.where((l) => l.startsWith('PATH=')), isNotEmpty);
    },
    testOn: 'linux || mac-os',
  );
}
