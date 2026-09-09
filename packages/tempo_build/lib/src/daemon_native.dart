import 'dart:io';
import 'context.dart';
import 'process.dart';

/// Builds native artifacts for host Dart diagnostics, never an ARM substitute.
Future<int> daemonHostCargo(
  Repository repo,
  CommandRunner runner,
  List<String> arguments, {
  bool check = true,
  String? operatingSystem,
}) {
  if ((operatingSystem ?? Platform.operatingSystem) != 'linux') {
    throw BuildFailure(
      'Native daemon host builds and checks require Linux. '
      'Use daemon build --target arm for the device, or --dart-only '
      'for a host Dart bundle without the Linux native service.',
      2,
    );
  }
  return Toolchain(repo, runner).run(
    ['cargo', ...arguments],
    environment: {'CARGO_TARGET_DIR': ArtifactPaths(repo).rust},
    check: check,
  );
}
