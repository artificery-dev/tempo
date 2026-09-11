import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:player_api/player_api.dart';

/// Authenticated profile control. An accepted selection is pending until restart.
final class StorageClient {
  StorageClient({required this.baseUri, required this.token});
  final Uri baseUri;
  final String token;
  Future<StorageStatus> status() => _request('GET');
  Future<StorageStatus> select(StorageSelection selection) =>
      _request('POST', selection.toJson());
  Future<StorageStatus> dismissOffer() =>
      _request('POST', {'dismissOffer': true});
  Future<StorageStatus> retryPending() => _request('POST', {'retry': true});
  Future<Map<String, Object?>> cardMaintenance({
    required String action,
    required String datastoreId,
    required String generation,
    required String mountId,
    required String cardId,
  }) => _requestJson(
    'POST',
    {
      'action': action,
      'datastoreId': datastoreId,
      'generation': generation,
      'mountId': mountId,
      'cardId': cardId,
    },
    path: '/api/v1/storage/card',
    timeout: const Duration(minutes: 2),
  );

  Future<StorageStatus> _request(
    String method, [
    Map<String, Object?>? body,
  ]) async => StorageStatus.fromJson(await _requestJson(method, body));

  Future<Map<String, Object?>> _requestJson(
    String method,
    Map<String, Object?>? body, {
    String path = '/api/v1/storage',
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      return await (() async {
        final request = await http.openUrl(method, baseUri.resolve(path));
        request.headers.set('authorization', 'Bearer $token');
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(body));
        }
        final response = await request.close();
        final bytes = <int>[];
        await for (final part in response) {
          if (bytes.length + part.length > 64 * 1024) {
            throw const FormatException('Storage response exceeds limit.');
          }
          bytes.addAll(part);
        }
        if (response.statusCode != 200 && response.statusCode != 202) {
          String? message;
          try {
            final body = jsonDecode(utf8.decode(bytes));
            if (body is Map &&
                body['error'] is Map &&
                body['error']['message'] is String) {
              message = body['error']['message'] as String;
            }
          } on FormatException {
            /* Keep the status if the peer sent invalid JSON. */
          }
          throw HttpException(
            message ?? 'Storage service returned HTTP ${response.statusCode}.',
          );
        }
        return Map<String, Object?>.from(jsonDecode(utf8.decode(bytes)) as Map);
      })().timeout(timeout);
    } finally {
      http.close(force: true);
    }
  }
}
