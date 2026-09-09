import 'package:flutter/services.dart';

/// Operations scoped to the emulator's Flutter view, including secondary views.
abstract final class NativeEmulatorWindow {
  static const _channel = MethodChannel('tempo/emulator_window');

  static Future<void> configure(int viewId) =>
      _channel.invokeMethod<void>('configure', {'viewId': viewId});

  static Future<void> setSize(int viewId, Size size) =>
      _channel.invokeMethod<void>('setSize', {
        'viewId': viewId,
        'width': size.width,
        'height': size.height,
      });

  static Future<void> close(int viewId) =>
      _channel.invokeMethod<void>('close', {'viewId': viewId});

  static Future<void> startDrag(int viewId) =>
      _channel.invokeMethod<void>('startDrag', {'viewId': viewId});
}
