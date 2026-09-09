import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

/// Apply firmness once, before jogs reach lists, rails, or captured controls.
abstract final class WheelSettings {
  static final feel = ValueNotifier<WheelFeel>(WheelFeel.standard);

  static void setFirmness(String value) {
    final clicks = switch (value) {
      'standard' => 2,
      'firm' => 3,
      _ => 1,
    };
    feel.value = feel.value.copyWith(rowsPerDetent: 1 / clicks);
  }
}
