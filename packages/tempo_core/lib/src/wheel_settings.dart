import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

/// Apply firmness once, before jogs reach lists, rails, or captured controls.
abstract final class WheelSettings {
  static final feel = ValueNotifier<WheelFeel>(WheelFeel.standard);

  /// How long the wheel must keep turning one way, in an ordered list,
  /// before the letters open.
  static final letterEntry = ValueNotifier<Duration>(WheelList.letterEntry);

  /// How long the letters stay open after the wheel goes still.
  static final letterIdle = ValueNotifier<Duration>(WheelList.accelerationIdle);

  /// A setting's milliseconds, as a duration; anything else leaves
  /// [fallback] in place.
  static Duration millis(Object? value, Duration fallback) =>
      value is num && value > 0
      ? Duration(milliseconds: value.round())
      : fallback;

  static void setFirmness(String value) {
    final clicks = switch (value) {
      'standard' => 2,
      'firm' => 3,
      _ => 1,
    };
    feel.value = feel.value.copyWith(rowsPerDetent: 1 / clicks);
  }
}
