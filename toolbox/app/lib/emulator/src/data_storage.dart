import 'package:flutter/foundation.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tempo_data/tempo_data.dart';

/// The same profile transaction as the device, with an in-process owner restart.
class EmulatorDataStorage extends ValueNotifier<DataStorageStatus>
    implements DataStorageController {
  EmulatorDataStorage({required this.manager, required this.restart})
    : super(
        const DataStorageStatus(
          available: false,
          busy: true,
          promptAvailable: false,
        ),
      );
  final TempoStorageManager Function() manager;
  final Future<void> Function() restart;
  @override
  Future<void> Function()? beforeChange;
  bool _changing = false;

  void publish(TempoStorageDecision decision, {String? error}) {
    final m = manager();
    value = DataStorageStatus(
      policy: DataStoragePolicy.values.byName(decision.policy.name),
      promptAvailable: decision.needsPrompt,
      cardPresent: decision.sdAvailable,
      cardProfileExists:
          decision.sdAvailable && m.fs.directory(m.sdPaths!.data).existsSync(),
      deviceProfileExists: m.fs.directory(m.devicePaths.data).existsSync(),
      usingCard: decision.location == TempoStorageLocation.sd,
      available: decision.activePaths != null && error == null,
      error: error,
    );
  }

  void failure(Object error, {bool unavailable = false}) {
    value = DataStorageStatus(
      policy: value.policy,
      promptAvailable: value.promptAvailable,
      cardPresent: value.cardPresent,
      cardProfileExists: value.cardProfileExists,
      deviceProfileExists: value.deviceProfileExists,
      usingCard: value.usingCard,
      available: !unavailable && value.available,
      error: error.toString(),
    );
  }

  @override
  Future<void> setPolicy(
    DataStoragePolicy policy, {
    bool replaceExisting = false,
    bool adoptExisting = false,
  }) async {
    if (_changing) throw StateError('Storage change in progress');
    _changing = true;
    try {
      if (value.available && policy == value.policy) return;
      if (value.available &&
          !value.usingCard &&
          policy != DataStoragePolicy.yes) {
        // This selector preference is outside the profile. Keep settings,
        // applets, playback and the current database owner running.
        final m = manager();
        final selected = TempoStoragePolicy.values.byName(policy.name);
        await m.setPolicy(selected);
        publish(
          TempoStorageDecision(
            policy: selected,
            location: TempoStorageLocation.device,
            activePaths: m.devicePaths,
            needsPrompt: false,
            sdAvailable: value.cardPresent,
          ),
        );
        return;
      }
      await beforeChange?.call();
      final m = manager();
      await m.prepareRequest(
        TempoStorageRequest(
          policy: TempoStoragePolicy.values.byName(policy.name),
          replaceExisting: replaceExisting,
          adoptExisting: adoptExisting,
        ),
        replacePending: !value.available,
      );
      value = DataStorageStatus(
        policy: value.policy,
        promptAvailable: value.promptAvailable,
        cardPresent: value.cardPresent,
        cardProfileExists: value.cardProfileExists,
        deviceProfileExists: value.deviceProfileExists,
        usingCard: value.usingCard,
        busy: true,
        restarting: true,
        available: value.available,
      );
      await restart();
    } catch (error) {
      failure(error);
      rethrow;
    } finally {
      _changing = false;
    }
  }

  @override
  Future<void> adoptCardForStartup() =>
      setPolicy(DataStoragePolicy.yes, adoptExisting: true);
  @override
  void skipStartup() {} // The widget owns the once-per-startup prompt latch.
}
