import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'context.dart';
import 'process.dart';
import 'modem_protocol.dart';

Future<int> bluetoothCommand(
  Repository repo,
  BuildConfig config,
  CommandRunner runner,
  List<String> args,
) async {
  if (args.isNotEmpty && (args.length != 1 || args.single != 'build'))
    throw BuildFailure('Expected os bluetooth build', 2);
  final source = repo.path('platform/bluetooth');
  final firmware = repo.path('platform/firmware/stock/modem_1_2g_n.img');
  if (!File(firmware).existsSync() ||
      (await sha256.bind(File(firmware).openRead()).first).toString() !=
          modemFirmwareHash) {
    throw BuildFailure(
      'Missing or changed Y2 vendor modem firmware: $firmware',
    );
  }
  final output = ArtifactPaths(repo).os('bluetooth');
  Directory(output).createSync(recursive: true);
  final retiredFixture = Directory(p.join(output, 'fixture'));
  if (retiredFixture.existsSync()) retiredFixture.deleteSync(recursive: true);
  await Toolchain(repo, runner).run([
    'arm-linux-gnueabihf-gcc',
    '-shared',
    '-fPIC',
    '-O2',
    '-Wall',
    '-Wextra',
    '-Werror',
    p.join(source, 'mmio.c'),
    '-o',
    p.join(output, 'mmio.so'),
  ]);
  final sdk = await FlutterSdk.discover(config, runner);
  await runner.run(sdk.dart, [
    'compile',
    'exe',
    '--target-os=linux',
    '--target-arch=arm',
    repo.path('platform/bluetooth/tool/bootstrap.dart'),
    '-o',
    p.join(output, 'bootstrap'),
  ], workingDirectory: repo.root);
  final retired = File(p.join(output, 'native-bootstrap.py'));
  if (retired.existsSync()) retired.deleteSync();
  for (final name in ['tempo-modem-bootstrap.service'])
    File(p.join(source, name)).copySync(p.join(output, name));
  File(firmware).copySync(p.join(output, 'modem_1_2g_n.img'));
  final files =
      Directory(output)
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => p.basename(file.path) != 'build-manifest.json')
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final hashes = <String, String>{};
  for (final file in files)
    hashes[p.relative(file.path, from: output)] =
        (await sha256.bind(file.openRead()).first).toString();
  File(p.join(output, 'build-manifest.json')).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(hashes)}\n',
  );
  return 0;
}
