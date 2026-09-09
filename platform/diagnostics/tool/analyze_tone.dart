#!/usr/bin/env dart

import 'dart:io';
import 'package:tempo_build/tempo_build.dart';

Future<void> main(List<String> args) async => exitCode =
    await runDeveloperCommand(['diagnostics', 'analyze-tone', ...args]);
