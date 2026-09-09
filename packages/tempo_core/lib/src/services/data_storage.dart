import 'package:flutter/foundation.dart';

enum DataStoragePolicy { yes, no, ask }

@immutable
class DataStorageStatus {
  const DataStorageStatus({
    this.policy = DataStoragePolicy.ask,
    this.cardPresent = false,
    this.cardProfileExists = false,
    this.deviceProfileExists = false,
    this.promptAvailable = true,
    this.usingCard = false,
    this.busy = false,
    this.restarting = false,
    this.available = true,
    this.error,
  });
  final DataStoragePolicy policy;
  final bool cardPresent,
      cardProfileExists,
      deviceProfileExists,
      promptAvailable,
      usingCard,
      busy,
      restarting,
      available;
  final String? error;
}

/// Bootstrap-owned preference; deliberately independent of SettingsFile.
abstract class DataStorageController
    implements ValueListenable<DataStorageStatus> {
  /// Adapters await this before setting busy or requesting a profile change.
  /// A failure aborts the change. The app flushes its state and suspends writes;
  /// adapters publish an idle status on failure so the app can resume them.
  Future<void> Function()? beforeChange;
  Future<void> setPolicy(
    DataStoragePolicy policy, {
    bool replaceExisting = false,
    bool adoptExisting = false,
  });

  /// Adopt the existing card profile and persist Yes.
  Future<void> adoptCardForStartup();

  /// Decline this startup only; the persisted policy remains Ask.
  void skipStartup();
}
