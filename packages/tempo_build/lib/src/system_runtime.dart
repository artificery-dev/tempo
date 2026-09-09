import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'context.dart';
import 'process.dart';

Future<int> systemRuntimeCommand(
  Repository repo,
  BuildConfig config,
  CommandRunner runner,
  List<String> args,
) async {
  if (args.length != 1 || args.single != 'build') {
    throw BuildFailure('Expected os runtime build', 2);
  }
  final output = ArtifactPaths(repo).os('runtime');
  Directory(output).createSync(recursive: true);
  final sdk = await FlutterSdk.discover(config, runner);
  await runner.run(sdk.dart, [
    'compile',
    'exe',
    '--target-os=linux',
    '--target-arch=arm',
    repo.path('platform/rootfs/tool/runtime.dart'),
    '-o',
    p.join(output, 'tempo-system'),
  ], workingDirectory: repo.root);
  await Toolchain(repo, runner).run([
    'arm-linux-gnueabihf-gcc',
    '-shared',
    '-fPIC',
    '-O2',
    '-Wall',
    '-Wextra',
    '-Werror',
    repo.path('platform/rootfs/native/runtime.c'),
    '-o',
    p.join(output, 'tempo-system.so'),
  ]);
  final hashes = <String, String>{};
  for (final name in ['tempo-system', 'tempo-system.so']) {
    hashes[name] =
        (await sha256.bind(File(p.join(output, name)).openRead()).first)
            .toString();
  }
  File(p.join(output, 'manifest.json')).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(hashes)}\n',
  );
  return 0;
}

Future<Map<String, String>> verifySystemRuntime(String directory) async {
  final manifest = jsonDecode(
    await File(p.join(directory, 'manifest.json')).readAsString(),
  );
  const required = {'tempo-system', 'tempo-system.so'};
  if (manifest is! Map ||
      manifest.length != required.length ||
      !manifest.keys.toSet().containsAll(required)) {
    throw BuildFailure(
      'Incomplete system runtime manifest; run toolbox dev os runtime build',
    );
  }
  final hashes = <String, String>{};
  for (final name in required) {
    final file = File(p.join(directory, name));
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw BuildFailure('System runtime is not a regular file: $name');
    }
    final bytes = await file.readAsBytes();
    if (bytes.length < 20 ||
        bytes[0] != 127 ||
        bytes[1] != 69 ||
        bytes[2] != 76 ||
        bytes[3] != 70 ||
        bytes[4] != 1 ||
        bytes[5] != 1 ||
        bytes[18] != 40 ||
        bytes[19] != 0) {
      throw BuildFailure('System runtime is not ARM32 ELF: $name');
    }
    final hash = sha256.convert(bytes).toString();
    if (manifest[name] != hash)
      throw BuildFailure('System runtime checksum mismatch: $name');
    hashes[name] = hash;
  }
  return hashes;
}
