/// Hardware observations owned by the daemon. Null means unknown/unavailable.
final class DeviceSnapshot {
  const DeviceSnapshot({
    this.batteryPercent,
    this.charging = false,
    this.cardPath,
    this.cardMountId,
    this.cardSourceId,
    this.cardIoBusy,
  });
  final int? batteryPercent;
  final bool charging;
  final String? cardPath;

  /// Kernel mount identity, distinct from both path and Cadence datastore UUID.
  /// Null means unavailable; never infer attachment from directory existence.
  final String? cardMountId;

  /// Physical SD CID when readable. Unlike mount ID, stable across remounts.
  /// Never synthesized from the mount path or directory contents.
  final String? cardSourceId;

  /// Recent or in-flight kernel I/O; null means no trustworthy observation.
  final bool? cardIoBusy;

  factory DeviceSnapshot.fromJson(Object? input) {
    if (input is! Map<String, dynamic> ||
        (input['batteryPercent'] != null &&
            (input['batteryPercent'] is! int ||
                input['batteryPercent'] < 0 ||
                input['batteryPercent'] > 100)) ||
        input['charging'] is! bool ||
        (input['cardPath'] != null && input['cardPath'] is! String) ||
        (input['cardMountId'] != null && input['cardMountId'] is! String) ||
        (input['cardSourceId'] != null && input['cardSourceId'] is! String) ||
        (input['cardIoBusy'] != null && input['cardIoBusy'] is! bool)) {
      throw const FormatException('Invalid device snapshot.');
    }
    return DeviceSnapshot(
      batteryPercent: input['batteryPercent'] as int?,
      charging: input['charging'] as bool,
      cardPath: input['cardPath'] as String?,
      cardMountId: input['cardMountId'] as String?,
      cardSourceId: input['cardSourceId'] as String?,
      cardIoBusy: input['cardIoBusy'] as bool?,
    );
  }

  Map<String, Object?> toJson() => {
    'batteryPercent': batteryPercent,
    'charging': charging,
    'cardPath': cardPath,
    'cardMountId': cardMountId,
    'cardSourceId': cardSourceId,
    'cardIoBusy': cardIoBusy,
  };
}
