import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The daemon acknowledges a settings write only after it has reached disk.
final class SettingsClient {
  SettingsClient({required this.baseUri, required this.token});
  final Uri baseUri;
  final String token;
  static const timeout = Duration(seconds: 10);

  Future<Map<String, Object?>> read() => _request('GET');
  Future<void> write(Map<String, Object?> values) async {
    await _request('PUT', values);
  }

  Future<Map<String, Object?>> _request(
    String method, [
    Map<String, Object?>? values,
  ]) async {
    final http = HttpClient()..connectionTimeout = timeout;
    try {
      return await (() async {
        final request = await http.openUrl(
          method,
          baseUri.resolve('/api/v1/settings'),
        );
        request.headers.set('authorization', 'Bearer $token');
        if (values != null) {
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(values));
        }
        final response = await request.close();
        if (response.statusCode != 200) {
          throw HttpException(
            'Settings service returned HTTP ${response.statusCode}.',
          );
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 64 * 1024) {
            throw const FormatException(
              'Settings response exceeds size limit.',
            );
          }
          bytes.addAll(chunk);
        }
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is! Map<String, Object?>) {
          throw const FormatException('Invalid settings response.');
        }
        return decoded;
      })().timeout(timeout);
    } finally {
      http.close(force: true);
    }
  }
}
