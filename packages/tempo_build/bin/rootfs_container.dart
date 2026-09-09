import 'dart:convert';
import 'dart:io';

import 'package:tempo_build/src/context.dart';
import 'package:tempo_build/src/process.dart';
import 'package:tempo_build/src/rootfs.dart';

/// Internal entry point; its configuration is already expanded on the host.
Future<void> main(List<String> arguments) async {
  if (arguments.length < 3 ||
      Platform.environment['TEMPO_ROOTFS_HOST'] != '1') {
    stderr.writeln(
      'Use toolbox dev os rootfs, not the internal container entry point.',
    );
    exitCode = 2;
    return;
  }
  try {
    final repo = Repository(arguments[0]);
    final config = BuildConfig(
      repo,
      (jsonDecode(File(arguments[1]).readAsStringSync()) as Map)
          .cast<String, Object?>(),
    );
    exitCode = await rootfsCommand(
      repo,
      config,
      CommandRunner(),
      arguments.sublist(2),
    );
  } on BuildFailure catch (error) {
    stderr.writeln(error.message);
    exitCode = error.code;
  }
}
