import 'dart:convert';
import 'dart:io';

import 'context.dart';
import 'process.dart';

Future<int> emulatorCommand(
  Repository repo,
  BuildConfig config,
  CommandRunner runner,
  String action,
  List<String> args,
) async {
  if (action == 'clean') {
    if (args.isNotEmpty)
      throw BuildFailure('emulator clean accepts no arguments', 2);
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Platform.environment['LOCALAPPDATA'];
    for (final path in [
      if (Platform.environment['TEMPO_EMULATOR_VM_FILE'] case final file?) file,
      if (home != null) '$home/.cache/tempo/emulator-vm.url',
      if (home != null) '$home/.cache/tempo/emulator.log',
    ]) {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    }
    final output = Directory(repo.path('build/toolbox/emulator'));
    if (output.existsSync()) output.deleteSync(recursive: true);
    return 0;
  }
  if (!['run', 'mcp'].contains(action))
    throw BuildFailure(
      'Expected emulator run [Flutter arguments], mcp, or clean',
      2,
    );
  final pin =
      jsonDecode(File(repo.path('toolbox/app/.fvmrc')).readAsStringSync())
          as Map;
  final sdk = await FlutterSdk.discover(
    config,
    runner,
    version: pin['flutter'] as String,
  );
  if (action == 'mcp')
    return runner.run(sdk.dart, [
      repo.path('toolbox/tool/emulator/emulator_mcp.dart'),
      ...args,
    ], workingDirectory: repo.root);
  final deviceSelected = args.any(
    (arg) =>
        arg == '-d' || arg == '--device-id' || arg.startsWith('--device-id='),
  );
  return runner.run(
    sdk.flutter,
    [
      'run',
      '--dart-define=TEMPO_TOOLBOX_EMULATOR=true',
      if (!deviceSelected) ...['-d', Platform.operatingSystem],
      ...args,
    ],
    workingDirectory: repo.path('toolbox/app'),
    environment: {'TEMPO_TOOLBOX_EMULATOR': '1'},
  );
}
