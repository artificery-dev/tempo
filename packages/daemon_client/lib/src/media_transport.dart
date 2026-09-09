import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Authenticated media envelopes, usable by Cadence's transport-independent client.
final class MediaTransport {
  MediaTransport({
    required this.baseUri,
    required this.token,
    this.timeout = const Duration(seconds: 30),
    this.maxResponseBytes = 32 * 1024 * 1024,
  });
  final Uri baseUri;
  final String token;
  final Duration timeout;
  final int maxResponseBytes;
  final _active = <HttpClient>{};
  bool _closed = false;

  Future<Map<String, Object?>> send(Map<String, Object?> envelope) async {
    if (_closed) throw StateError('Media transport is closed.');
    final http = HttpClient()..connectionTimeout = timeout;
    _active.add(http);
    try {
      return await (() async {
        final request = await http.postUrl(baseUri.resolve('/api/v1/media'));
        request.headers.set('authorization', 'Bearer $token');
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(envelope));
        final response = await request.close();
        if (response.statusCode != 200) {
          throw HttpException(
            'Media service returned HTTP ${response.statusCode}.',
          );
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > maxResponseBytes) {
            throw const FormatException('Media response exceeds size limit.');
          }
          bytes.addAll(chunk);
        }
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is! Map<String, Object?> ||
            decoded['id'] != envelope['id'] ||
            decoded['status'] is! int ||
            decoded['body'] is! Map<String, Object?>) {
          throw const FormatException('Invalid media response.');
        }
        return decoded;
      })().timeout(timeout);
    } finally {
      http.close(force: true);
      _active.remove(http);
    }
  }

  Future<void> close() async {
    _closed = true;
    for (final http in _active) {
      http.close(force: true);
    }
    _active.clear();
  }
}
