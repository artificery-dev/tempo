import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'device_snapshot.dart';

/// Reads daemon observations; never falls back to local hardware access.
final class DeviceClient {
  DeviceClient({
    required this.baseUri,
    required this.token,
    this.period = const Duration(seconds: 5),
  });
  final Uri baseUri;
  final String token;
  final Duration period;
  HttpClient? _active;
  final _changes = StreamController<DeviceSnapshot>.broadcast();
  Timer? _timer;
  bool _closed = false;
  Future<void>? _reading;
  DeviceSnapshot snapshot = const DeviceSnapshot();
  Stream<DeviceSnapshot> get changes => _changes.stream;

  void start() {
    if (_closed || _timer != null) return;
    unawaited(refresh());
    _timer = Timer.periodic(period, (_) => unawaited(refresh()));
  }

  Future<void> refresh() =>
      _reading ??= _refresh().whenComplete(() => _reading = null);
  Future<void> _refresh() async {
    if (_closed) return;
    final http = _active = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    DeviceSnapshot next;
    HttpClientRequest? request;
    try {
      next = await (() async {
        request = await http.getUrl(baseUri.resolve('/api/v1/device'));
        request!.headers.set('authorization', 'Bearer $token');
        final response = await request!.close();
        if (response.statusCode != 200) {
          throw const FormatException('Device unavailable');
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 65536) {
            throw const FormatException('Device response too large');
          }
          bytes.addAll(chunk);
        }
        return DeviceSnapshot.fromJson(jsonDecode(utf8.decode(bytes)));
      })().timeout(const Duration(seconds: 4));
    } catch (_) {
      request?.abort();
      next = const DeviceSnapshot();
    } finally {
      http.close(force: true);
      _active = null;
    }
    if (_closed) return;
    snapshot = next;
    _changes.add(next);
  }

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    _active?.close(force: true);
    await _reading;
    await _changes.close();
  }
}
