import 'dart:io';

import 'package:tempo_build/tempo_build.dart';

Future<void> main(List<String> args) async {
  exitCode = await runDeveloperCommand(['app', 'flutter-pi', 'build', ...args]);
}
