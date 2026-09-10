import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'cadence_client.dart';

/// HTTP/1.1 over a Unix-domain socket. Closing never cancels server jobs.
class UnixMediaTransport implements MediaTransport {
  UnixMediaTransport(
    String socketPath, {
    this.timeout = const Duration(seconds: 30),
  }) {
    _http.connectionFactory = (uri, proxyHost, proxyPort) =>
        Socket.startConnect(
          InternetAddress(socketPath, type: InternetAddressType.unix),
          0,
        );
    _http.connectionTimeout = timeout;
  }
  final Duration timeout;
  final _http = HttpClient();
  int _id = 0;
  bool _closed = false;
  Future<HttpClientResponse> _open(
    String method,
    String path, [
    Object? body,
  ]) async {
    if (_closed) throw StateError('Client closed');
    final request = await _http.openUrl(
      method,
      Uri.parse('http://localhost$path'),
    );
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    return request.close();
  }

  @override
  Future<Map<String, Object?>> request(
    String method,
    String path, [
    Map<String, Object?>? body,
  ]) => (() async {
    final id = ++_id;
    final response = await _open('POST', '/v1/rpc', {
      'version': 1,
      'id': id,
      'method': method,
      'path': path,
      if (body != null) 'body': body,
    });
    final envelope =
        jsonDecode(await utf8.decoder.bind(response).join()) as Map;
    if (envelope['id'] != id || envelope['version'] != 1) {
      throw MediaError(
        'invalid_response',
        'Protocol correlation mismatch',
        502,
      );
    }
    final result = (envelope['body'] as Map).cast<String, Object?>();
    final status = envelope['status'] as int;
    if (status >= 400) {
      final error = result['error'] as Map;
      throw MediaError(
        error['code'] as String,
        error['message'] as String,
        status,
      );
    }
    return result;
  })().timeout(timeout);
  @override
  Future<List<int>?> artwork(int fileId) => (() async {
    final response = await _open('GET', '/v1/artwork/$fileId');
    if (response.statusCode == 404) {
      await response.drain<void>();
      return null;
    }
    if (response.statusCode != 200) {
      await response.drain<void>();
      throw MediaError(
        'artwork_failed',
        'Artwork unavailable',
        response.statusCode,
      );
    }
    return response.fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk));
  })().timeout(timeout);
  @override
  Stream<Map<String, Object?>> get events async* {
    try {
      final response = await _open('GET', '/v1/events');
      if (response.statusCode != 200)
        throw MediaError(
          'events_failed',
          'Notifications unavailable',
          response.statusCode,
        );
      await for (final line
          in response.transform(utf8.decoder).transform(const LineSplitter())) {
        if (line.startsWith('data: '))
          yield (jsonDecode(line.substring(6)) as Map).cast<String, Object?>();
      }
    } catch (_) {
      if (!_closed) rethrow;
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    _http.close(force: true);
  }
}
