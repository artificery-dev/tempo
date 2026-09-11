import '../../services/storage_host.dart';
import '../../services/card_host.dart';
import 'package:tempo_data/tempo_data.dart';
import '../../services/radio_host.dart';
import 'package:daemon_client/daemon_client.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io' show InternetAddress, SecurityContext;

import 'package:player_api/player_api.dart';
import 'package:relic/relic.dart';

import '../../services/device_monitor.dart';
import '../../services/settings_host.dart';
import '../../services/remote_player.dart';
import 'owner_connection.dart';
import 'event_client.dart';
import 'http_failure.dart';

/// Relic adapter over one authoritative player service, on one isolate.
final class PlayerServer {
  PlayerServer({
    required this.player,
    required String token,
    Set<String> allowedOrigins = const {},
    this.ackTimeout = const Duration(seconds: 15),
    this.maxClients = 16,
    this.onError,
    String? ownerToken,
    this.deviceMonitor,
    this.settingsHost,
    this.radios,
    this.storageHost,
    this.cardHost,
  }) : _ownerToken = ownerToken == null ? null : utf8.encode(ownerToken),
       _token = utf8.encode(token),
       _allowedOrigins = Set.unmodifiable(allowedOrigins) {
    if (ownerToken != null &&
        (ownerToken.trim().isEmpty ||
            ownerToken == token ||
            player is! RemotePlayer)) {
      throw ArgumentError(
        'A separate owner token and RemotePlayer are required.',
      );
    }
    if (token.trim().isEmpty) throw ArgumentError('An API token is required.');
    if (ackTimeout <= Duration.zero || maxClients < 1) {
      throw ArgumentError('Connection limits must be positive.');
    }
    _router
      ..get('/api/v1/owner', _ownerUpgrade)
      ..get(
        '/api/v1/device',
        (_) => deviceMonitor == null
            ? _error(
                503,
                'device_unavailable',
                'Device monitoring is disabled.',
              )
            : _json(200, deviceMonitor!.snapshot.toJson()),
      )
      ..get('/api/v1/player', (_) => _json(200, player.snapshot.toJson()))
      ..post('/api/v1/commands', _command)
      ..get('/api/v1/settings', _settingsRead)
      ..put('/api/v1/settings', _settingsWrite)
      ..post('/api/v1/radios', _radioCommand)
      ..get('/api/v1/storage', _storageRead)
      ..post('/api/v1/storage', _storageSelect)
      ..post('/api/v1/storage/card', _cardCommand)
      ..get('/api/v1/events', _upgrade)
      ..fallback = (_) => _error(404, 'not_found', 'Unknown API route.');
  }

  static const maxBodyBytes = 64 * 1024;
  final PlayerService player;
  final DeviceMonitor? deviceMonitor;
  final SettingsHost? settingsHost;
  final RadioHost? radios;
  final StorageHost? storageHost;
  final CardHost? cardHost;
  final List<int>? _ownerToken;
  OwnerConnection? _owner;
  final List<int> _token;
  final Set<String> _allowedOrigins;
  final Duration ackTimeout;
  final int maxClients;
  final void Function(Object, StackTrace)? onError;
  final _router = RelicRouter();
  final _clients = <EventClient>{};
  RelicServer? _server;
  bool _closing = false;
  bool _started = false;
  Future<void>? _closeFuture;

  int get port => _server!.port;
  int get clientCount => _clients.length;

  Future<void> start({
    InternetAddress? address,
    int port = 0,
    SecurityContext? securityContext,
  }) async {
    if (_started || _closing) throw StateError('Server already used.');
    _started = true;
    final adapter = await IOAdapter.bind(
      address ?? InternetAddress.loopbackIPv4,
      port: port,
      context: securityContext,
    );
    final server = RelicServer(() => adapter);
    _server = server;
    if (_closing) {
      await server.close(force: true);
      throw StateError('Server was closed during startup.');
    }
    try {
      await server.mountAndStart(_handle);
    } catch (_) {
      await server.close(force: true);
      rethrow;
    }
  }

  Future<Result> _handle(Request request) async {
    if (_closing) return _error(503, 'shutting_down', 'Server is stopping.');
    // Never accept tokens in URLs: URLs commonly end up in logs/history.
    final ownerRequest = request.url.path == '/api/v1/owner';
    final expectedToken = ownerRequest ? _ownerToken : _token;
    if (expectedToken == null) {
      return _error(404, 'not_found', 'Unknown API route.');
    }
    if (!_authorized(request, expectedToken)) {
      return _error(401, 'unauthorized', 'A valid bearer token is required.');
    }
    final origins = request.headers['origin'];
    if (origins != null &&
        (origins.length != 1 || !_allowedOrigins.contains(origins.single))) {
      return _error(403, 'origin_denied', 'Browser origin is not allowed.');
    }
    try {
      return await _router.asHandler(request);
    } on HttpFailure catch (error) {
      return _error(error.status, error.code, error.message);
    } on PlayerFailure catch (error) {
      return _error(
        error.code == 'player_unavailable' ? 503 : 409,
        error.code,
        error.message,
      );
    } catch (error, stack) {
      onError?.call(error, stack);
      return _error(500, 'internal_error', 'The operation failed.');
    }
  }

  Future<Response> _storageRead(Request request) async => storageHost == null
      ? _error(503, 'storage_unavailable', 'Profile selection is disabled.')
      : _json(200, storageHost!.status.toJson());

  Future<Response> _cardCommand(Request request) async {
    final host = cardHost;
    if (host == null) {
      return _error(
        503,
        'card_unavailable',
        'Card maintenance is unavailable.',
      );
    }
    final type = request.headers['content-type'];
    if (type == null ||
        type.length != 1 ||
        type.single.split(';').first.trim().toLowerCase() !=
            'application/json') {
      return _error(415, 'unsupported_media_type', 'Use application/json.');
    }
    try {
      return _json(
        200,
        await host.execute(jsonDecode(await _readBody(request))),
      );
    } on FormatException {
      return _error(
        400,
        'invalid_request',
        'Invalid card maintenance request.',
      );
    } on StateError catch (error) {
      return _error(409, 'card_busy', error.message.toString());
    }
  }

  Future<Response> _storageSelect(Request request) async {
    final storage = storageHost;
    if (storage == null) {
      return _error(
        503,
        'storage_unavailable',
        'Profile selection is disabled.',
      );
    }
    final type = request.headers['content-type'];
    if (type == null ||
        type.length != 1 ||
        type.single.split(';').first.trim().toLowerCase() !=
            'application/json') {
      return _error(415, 'unsupported_media_type', 'Use application/json.');
    }
    try {
      final body = jsonDecode(await _readBody(request));
      if (body is Map && body.length == 1 && body['retry'] == true) {
        return _json(202, storage.retryPending().toJson());
      }
      if (body is Map && body.length == 1 && body['dismissOffer'] == true) {
        return _json(200, storage.dismissOffer().toJson());
      }
      final status = await storage.select(StorageSelection.fromJson(body));
      return _json(status.restartPending ? 202 : 200, status.toJson());
    } on FormatException {
      return _error(400, 'invalid_request', 'Invalid storage selection.');
    } on TempoProfileConflict catch (error) {
      return _error(409, 'profile_conflict', error.message);
    } on StateError catch (error) {
      return _error(409, 'storage_unavailable', error.message.toString());
    }
  }

  Future<Response> _settingsRead(Request request) async {
    if (settingsHost == null) {
      return _error(
        503,
        'settings_unavailable',
        'Settings service is disabled.',
      );
    }
    return _json(200, await settingsHost!.read());
  }

  Future<Response> _settingsWrite(Request request) async {
    if (settingsHost == null) {
      return _error(
        503,
        'settings_unavailable',
        'Settings service is disabled.',
      );
    }
    final type = request.headers['content-type'];
    if (type == null ||
        type.length != 1 ||
        type.single.split(';').first.trim().toLowerCase() !=
            'application/json') {
      throw const HttpFailure(
        415,
        'unsupported_media_type',
        'Use application/json.',
      );
    }
    try {
      final decoded = jsonDecode(await _readBody(request));
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('Expected settings object.');
      }
      await settingsHost!.write(decoded);
    } on FormatException {
      throw const HttpFailure(
        400,
        'invalid_request',
        'Invalid settings object.',
      );
    }
    return _json(200, {'saved': true});
  }

  Future<Response> _radioCommand(Request request) async {
    if (radios == null) {
      return _error(503, 'radio_unavailable', 'Radio service is disabled.');
    }
    final types = request.headers['content-type'];
    if (types == null ||
        types.length != 1 ||
        types.single.split(';').first.trim().toLowerCase() !=
            'application/json') {
      throw const HttpFailure(
        415,
        'unsupported_media_type',
        'Use application/json.',
      );
    }
    try {
      return _json(
        200,
        await radios!.execute(jsonDecode(await _readBody(request))),
      );
    } on FormatException {
      throw const HttpFailure(400, 'invalid_request', 'Invalid radio command.');
    } on RadioFailure catch (error) {
      throw HttpFailure(409, 'radio_failed', error.message);
    }
  }

  Future<Response> _command(Request request) async {
    final contentTypes = request.headers['content-type'];
    if (contentTypes == null ||
        contentTypes.length != 1 ||
        contentTypes.single.split(';').first.trim().toLowerCase() !=
            'application/json') {
      throw const HttpFailure(
        415,
        'unsupported_media_type',
        'Use application/json.',
      );
    }
    final PlayerCommand command;
    try {
      command = PlayerCommand.fromJson(jsonDecode(await _readBody(request)));
    } on FormatException {
      throw const HttpFailure(
        400,
        'invalid_request',
        'Invalid JSON or command fields.',
      );
    }
    final state = await player.execute(command);
    return _json(200, {'state': state.toJson()});
  }

  Future<String> _readBody(Request request) async {
    if ((request.body.contentLength ?? 0) > maxBodyBytes) {
      throw const HttpFailure(
        413,
        'body_too_large',
        'Request body is too large.',
      );
    }
    final bytes = <int>[];
    final iterator = StreamIterator(request.body.read());
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    try {
      while (true) {
        final remaining = deadline.difference(DateTime.now());
        if (remaining <= Duration.zero) throw TimeoutException('Request body');
        if (!await iterator.moveNext().timeout(remaining)) break;
        if (bytes.length + iterator.current.length > maxBodyBytes) {
          throw const HttpFailure(
            413,
            'body_too_large',
            'Request body is too large.',
          );
        }
        bytes.addAll(iterator.current);
      }
    } on TimeoutException {
      throw const HttpFailure(
        408,
        'request_timeout',
        'Request body timed out.',
      );
    } finally {
      await iterator.cancel();
    }
    return utf8.decode(bytes);
  }

  Result _upgrade(Request request) {
    if (_clients.length >= maxClients) {
      return _error(503, 'connection_limit', 'Too many event subscribers.');
    }
    final upgrades = request.headers['upgrade'];
    if (upgrades?.length != 1 ||
        upgrades!.single.toLowerCase() != 'websocket') {
      return _error(400, 'upgrade_required', 'Use a WebSocket connection.');
    }
    return WebSocketUpgrade((socket) {
      // The handshake is asynchronous; recheck both gates after it completes.
      if (_closing || _clients.length >= maxClients) {
        unawaited(socket.tryClose(4003, 'Server unavailable'));
        return;
      }
      final client = EventClient(
        player: player,
        socket: socket,
        ackTimeout: ackTimeout,
        maxMessageBytes: maxBodyBytes,
        onClosed: (client) => _clients.remove(client),
      );
      _clients.add(client);
      try {
        client.start();
      } catch (error, stack) {
        unawaited(client.close(4004, 'Player service failed'));
        onError?.call(error, stack);
      }
    });
  }

  bool _authorized(Request request, List<int> expectedToken) {
    final values = request.headers['authorization'];
    final authorization = values?.length == 1 ? values!.single : '';
    final supplied = authorization.startsWith('Bearer ')
        ? utf8.encode(authorization.substring(7))
        : <int>[];
    var difference = supplied.length ^ expectedToken.length;
    for (var i = 0; i < expectedToken.length; i++) {
      difference |= expectedToken[i] ^ (i < supplied.length ? supplied[i] : 0);
    }
    return difference == 0;
  }

  Result _ownerUpgrade(Request request) {
    final token = _ownerToken;
    if (token == null || !_authorized(request, token)) {
      return _error(401, 'unauthorized', 'An owner credential is required.');
    }
    final upgrades = request.headers['upgrade'];
    if (upgrades?.length != 1 ||
        upgrades!.single.toLowerCase() != 'websocket') {
      return _error(400, 'upgrade_required', 'Use a WebSocket connection.');
    }
    if (_owner != null) {
      return _error(
        409,
        'owner_connected',
        'A playback owner is already connected.',
      );
    }
    return WebSocketUpgrade((socket) {
      if (_closing || _owner != null) {
        unawaited(socket.tryClose(4003, 'Owner unavailable'));
        return;
      }
      final owner = OwnerConnection(
        player: player as RemotePlayer,
        socket: socket,
        onClosed: () => _owner = null,
      );
      _owner = owner;
      owner.start();
    });
  }

  Future<void> close() => _closeFuture ??= _close();
  Future<void> _close() async {
    _closing = true;
    await _owner?.close();
    await Future.wait(
      _clients.toList().map((c) => c.close(4001, 'Server stopping')),
    );
    // Closing upgraded sockets is our responsibility, separate from HTTP.
    await _server?.close(force: true);
  }

  static Response _json(int status, Map<String, Object?> value) => Response(
    status,
    body: Body.fromString(jsonEncode(value), mimeType: MimeType.json),
    headers: Headers.fromMap({
      'cache-control': ['no-store'],
      'x-content-type-options': ['nosniff'],
    }),
  );
  static Response _error(int status, String code, String message) =>
      _json(status, {
        'error': {'code': code, 'message': message},
      });
}
