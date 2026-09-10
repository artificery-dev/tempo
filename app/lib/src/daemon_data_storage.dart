import 'dart:async';

import 'package:daemon_client/daemon_client.dart';
import 'package:player_api/player_api.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tomeui/tomeui.dart';

/// Keeps bootstrap policy out of the settings profile that can move.
final class DaemonDataStorage extends ValueNotifier<DataStorageStatus>
    implements DataStorageController, RetryableDataStorage {
  DaemonDataStorage(this.client, StorageStatus status)
    : remote = status,
      super(_reading(status)) {
    _poll = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(refresh());
    });
  }

  final StorageClient client;
  StorageStatus remote;
  bool _disposed = false;
  bool _changing = false;
  bool _refreshing = false;
  Timer? _poll;

  Future<void> refresh() async {
    if (_disposed || _refreshing || _changing) return;
    _refreshing = true;
    try {
      final next = await client.status();
      if (!_disposed && !_changing) {
        remote = next;
        value = _reading(next);
      }
    } catch (_) {
      // A queued restart briefly removes the HTTP listener. Keep its state.
    } finally {
      _refreshing = false;
    }
  }

  @override
  Future<void> Function()? beforeChange;

  static DataStorageStatus _reading(
    StorageStatus status, {
    bool busy = false,
    String? error,
  }) => DataStorageStatus(
    policy: DataStoragePolicy.values.byName(status.policy),
    cardPresent: status.sdAvailable,
    promptAvailable: status.needsPrompt,
    cardProfileExists: status.sdProfileExists,
    deviceProfileExists: status.deviceProfileExists,
    usingCard: status.location == 'sd',
    available: status.available,
    busy: busy,
    restarting: status.restartPending,
    error: error ?? status.error,
  );

  Future<void> _change(StorageSelection selection) async {
    if (_changing || value.busy || value.restarting) return;
    _changing = true;
    try {
      await beforeChange?.call();
      if (_disposed) return;
      value = _reading(remote, busy: true);
      remote = await client.select(selection);
      if (!_disposed) value = _reading(remote);
    } catch (error) {
      if (!_disposed) value = _reading(remote, error: error.toString());
      rethrow;
    } finally {
      _changing = false;
    }
  }

  @override
  Future<void> retryPending() async {
    if (_changing || _disposed) return;
    _changing = true;
    try {
      value = _reading(remote, busy: true);
      remote = await client.retryPending();
      if (!_disposed) value = _reading(remote);
    } catch (error) {
      if (!_disposed) value = _reading(remote, error: '$error');
      rethrow;
    } finally {
      _changing = false;
    }
  }

  @override
  Future<void> setPolicy(
    DataStoragePolicy policy, {
    bool replaceExisting = false,
    bool adoptExisting = false,
  }) => _change(
    StorageSelection(
      policy: policy.name,
      replaceExisting: replaceExisting,
      adoptExisting: adoptExisting,
    ),
  );

  @override
  Future<void> adoptCardForStartup() =>
      _change(const StorageSelection(policy: 'yes', adoptExisting: true));

  @override
  void skipStartup() {
    unawaited(
      client.dismissOffer().then(
        (status) {
          remote = status;
          if (!_disposed) value = _reading(status);
        },
        onError: (Object error) {
          if (!_disposed) value = _reading(remote, error: error.toString());
        },
      ),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    super.dispose();
  }
}
