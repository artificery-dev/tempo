/// Hardware observations owned by the daemon. Null means unknown/unavailable.
final class DeviceSnapshot {
  const DeviceSnapshot({
    this.batteryPercent,
    this.charging = false,
    this.cardPath,
  });
  final int? batteryPercent;
  final bool charging;
  final String? cardPath;

  factory DeviceSnapshot.fromJson(Object? input) {
    if (input is! Map<String, dynamic> ||
        (input['batteryPercent'] != null &&
            (input['batteryPercent'] is! int ||
                input['batteryPercent'] < 0 ||
                input['batteryPercent'] > 100)) ||
        input['charging'] is! bool ||
        (input['cardPath'] != null && input['cardPath'] is! String)) {
      throw const FormatException('Invalid device snapshot.');
    }
    return DeviceSnapshot(
      batteryPercent: input['batteryPercent'] as int?,
      charging: input['charging'] as bool,
      cardPath: input['cardPath'] as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'batteryPercent': batteryPercent,
    'charging': charging,
    'cardPath': cardPath,
  };
}
