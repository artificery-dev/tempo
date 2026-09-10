import 'dart:async';
import 'dart:io';
import 'package:player_api/player_api.dart';
import 'package:tempo_data/tempo_data.dart';

/// One daemon lifetime owns exactly one resolved profile. Requests only stage
/// intent; migration runs in initialize before any database/settings owner opens.
final class StorageHost {
  StorageHost({
    required this.manager,
    required this.mediaHome,
    required this.restart,
    this.restartDelay = const Duration(milliseconds: 250),
    this.log,
  });
  final TempoStorageManager Function() manager;
  final String mediaHome;
  final Future<void> Function() restart;
  final Duration restartDelay;
  final void Function(String)? log;
  TempoStorageDecision? _active;
  String? _startupError, _restartError;
  bool _dismissed = false,
      _busy = false,
      _closed = false,
      _recoveryBlocked = false;
  Timer? _restartTimer;

  Future<void> initialize() async {
    final store = manager();
    try {
      _active = await store.applyPendingAtStartup();
    } on TempoDatastoreMoveRejected catch (error) {
      _active = await store.resolveStartup();
      _restartError = error.message;
      log?.call(error.message);
    } catch (error) {
      if (store.readPendingRequest()?.started == true) {
        _recoveryBlocked = true;
        _startupError =
            'Library move is incomplete. Reinsert the original card and retry: $error';
        log?.call(_startupError!);
        return;
      }
      // Still before any profile owner opens. Roll back/finish the journal now,
      // never in an authenticated POST while the daemon is serving consumers.
      try {
        await store.recover();
      } catch (failure) {
        _recoveryBlocked = true;
        _startupError =
            'Profile recovery is incomplete. Restore the selected card and its write access, then restart player services: $failure';
      }
      _startupError ??= 'Profile could not be opened: $error';
      log?.call(_startupError!);
    }
  }

  void unavailable(Object error) {
    _startupError = 'Profile could not be opened: $error';
    log?.call(_startupError!);
  }

  StorageStatus get status {
    final store = manager();
    var policy = _active?.policy ?? TempoStoragePolicy.ask;
    var pending = false;
    String? error = _startupError ?? _restartError;
    try {
      policy = _active?.policy ?? store.readSelector();
      pending = store.readPendingRequest() != null;
    } catch (failure) {
      error ??= 'Storage selector unavailable: $failure';
    }
    final sd = store.sdPaths;
    final sdAvailable =
        sd != null && store.fs.directory(store.cardRoot!).existsSync();
    final sdExists = sdAvailable && store.fs.directory(sd.data).existsSync();
    final paths = _active?.activePaths;
    // Device configuration is internal even when Cadence metadata is on an
    // absent card. Losing media must not suspend wallpaper/settings writes.
    final available = _startupError == null && paths != null;
    if (!available && error == null) {
      error =
          'The selected profile is unavailable. Reinsert the selected card or choose the device profile.';
    }
    return StorageStatus(
      policy: policy.name,
      location: _active?.location == TempoStorageLocation.sd ? 'sd' : 'device',
      available: available,
      mediaHome: mediaHome,
      dataPath: available ? paths.data : null,
      configPath: store.devicePaths.config,
      sdAvailable: sdAvailable,
      needsPrompt:
          policy != TempoStoragePolicy.no &&
          _active?.location != TempoStorageLocation.sd &&
          sdAvailable &&
          !_dismissed,
      restartPending: pending,
      error: error,
      deviceProfileExists:
          store.fs.directory(store.devicePaths.data).existsSync() ||
          store.fs.directory(store.devicePaths.config).existsSync(),
      sdProfileExists: sdExists,
    );
  }

  StorageStatus dismissOffer() {
    if (_closed) throw StateError('Storage service closed');
    _dismissed = true;
    return status;
  }

  StorageStatus retryPending() {
    if (_closed || _busy || manager().readPendingRequest() == null) {
      throw StateError('No pending library move can be retried');
    }
    _restartTimer?.cancel();
    _restartError = null;
    _restartTimer = Timer(restartDelay, () async {
      try {
        await restart();
      } catch (error) {
        _restartError =
            'Restart failed; the original library move remains pending.';
        log?.call('Storage retry could not restart services: $error');
      }
    });
    return status;
  }

  Future<StorageStatus> select(StorageSelection selection) async {
    if (_closed || _busy) {
      throw StateError('Storage operation already in progress');
    }
    if (_recoveryBlocked) {
      throw StateError(
        'Profile recovery is incomplete. Restore the selected card and restart player services before selecting another profile.',
      );
    }
    _busy = true;
    final store = manager();
    try {
      final policy = TempoStoragePolicy.values.byName(selection.policy);
      final current = status;
      if (current.available &&
          !current.restartPending &&
          ((current.location == 'device' && policy != TempoStoragePolicy.yes) ||
              (current.policy == policy.name && current.location == 'sd'))) {
        // This changes only the selector, never recovers or touches open data.
        await store.setPolicy(policy);
        _active = TempoStorageDecision(
          policy: policy,
          location: _active!.location,
          activePaths: _active!.activePaths,
          needsPrompt: false,
          sdAvailable: current.sdAvailable,
        );
        _restartError = null;
        return status;
      }
      await store.prepareRequest(
        TempoStorageRequest(
          policy: TempoStoragePolicy.values.byName(selection.policy),
          adoptExisting: selection.adoptExisting,
          replaceExisting: selection.replaceExisting,
        ),
        replacePending: _startupError != null,
      );
      _restartError = null;
      // Return the pending status before handing the restart job to systemd.
      // The selector remains durable if the client disconnects before the reply.
      _restartTimer = Timer(restartDelay, () {
        unawaited(_queueRestart(store));
      });
      return status;
    } finally {
      _busy = false;
    }
  }

  Future<void> _queueRestart(TempoStorageManager store) async {
    if (_closed) return;
    try {
      await restart();
    } catch (error) {
      _restartError = 'Restart was not queued; retry the storage selection.';
      try {
        await store.clearPendingRequest();
      } catch (_) {
        _restartError =
            'Restart failed and the storage request remains pending; restart the player services to retry.';
      }
      log?.call('Storage restart failed (${error.runtimeType}).');
    }
  }

  String? _cardIdentity;
  bool _observedCard = false;
  void observeCard(String? identity) {
    final changed = _observedCard && identity != _cardIdentity;
    _observedCard = true;
    _cardIdentity = identity;
    if (!changed ||
        identity == null ||
        _closed ||
        _busy ||
        status.restartPending ||
        status.policy != 'yes') {
      return;
    }
    _restartTimer?.cancel();
    _restartTimer = Timer(restartDelay, () async {
      try {
        await restart();
      } catch (error) {
        log?.call('Could not reopen card library: $error');
      }
    });
  }

  Future<void> close() async {
    _closed = true;
    _restartTimer?.cancel();
  }
}

/// Both stop jobs precede both start jobs: the UI's Requires/After relation to
/// Tempod ensures migration starts only after the old UI/daemon have stopped.
Future<void> queueStorageRestart() async {
  final result = await Process.run('systemctl', [
    '--no-block',
    'restart',
    'tempod.service',
    'tempo.service',
  ]).timeout(const Duration(seconds: 5));
  if (result.exitCode != 0) throw StateError('Service restart request failed');
}
