import 'dart:io';
import 'package:tempo_build/tempo_build.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Repository repo;
  void pubspec(String directory, String body) {
    final file = File('${root.path}/$directory/pubspec.yaml');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(body);
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('workspace-component');
    repo = Repository(root.path);
    pubspec('.', 'name: tempo\nworkspace:\n  - app\n  - daemon\n');
    pubspec('app', 'name: tempo_app\nresolution: workspace\n');
    pubspec('daemon', 'name: tempod\nresolution: workspace\n');
    pubspec(
      'packages/tempo_logger',
      'name: tempo_logger\nresolution: workspace\n',
    );
    pubspec('packages/tempo_build', 'name: tempo_build\n');
    pubspec('toolbox/app', 'name: tempo_toolbox\n');
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('roots divide into the app workspace, the daemon and the Toolbox', () {
    expect(workspaceComponent(repo, repo.path('app')), 'app');
    expect(workspaceComponent(repo, repo.path('packages/tempo_logger')), 'app');
    expect(workspaceComponent(repo, repo.path('daemon')), 'daemon');
    expect(
      workspaceComponent(repo, repo.path('packages/tempo_build')),
      'toolbox',
    );
    expect(workspaceComponent(repo, repo.path('toolbox/app')), 'toolbox');
    expect(workspaceComponents, ['app', 'daemon', 'toolbox']);
  });

  test(
    'an unknown component is rejected before any SDK is looked up',
    () async {
      File(
        '${root.path}/config.yaml',
      ).writeAsStringSync('flutter:\n  sdk_version: 0.0.0\n');
      for (final args in [
        ['--component', 'kernel'],
        ['--component'],
      ]) {
        expect(
          await runDeveloperCommand([
            'workspace',
            'test',
            ...args,
          ], repositoryRoot: root.path),
          2,
        );
      }
    },
  );
}
