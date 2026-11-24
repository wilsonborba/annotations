import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../core/log_redactor.dart';
import '../../core/settings.dart';
import 'gzip_body.dart';

class ApiError implements Exception {
  final int status;
  final String message;
  final Map<String, dynamic>? details;
  ApiError(this.status, this.message, {this.details});
  @override
  String toString() => message;
}

class ApiAdapter {
  final http.Client client;
  final String base;

  /// Receives each failed request with its operation, such as `GET /posts`.
  void Function(Object error, StackTrace stack, String operation)? onError;
  ApiAdapter({http.Client? client, String? base})
    : client = client ?? http.Client(),
      base = base ?? Settings.current.apiBase;
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String>? query,
    Map<String, String>? headers,
    bool compress = false,
  }) async {
    try {
      return await _request(
        path,
        method: method,
        body: body,
        query: query,
        headers: headers,
        compress: compress,
      );
    } catch (error, stack) {
      final cleanOp = sanitizeForLog('$method $path');
      onError?.call(error, stack, cleanOp);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _request(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String>? query,
    Map<String, String>? headers,
    bool compress = false,
  }) async {
    final uri = Uri.parse(
      '$base$path',
    ).replace(queryParameters: query?.isEmpty == true ? null : query);
    final request = http.Request(method, uri)
      ..headers['content-type'] = 'application/json';
    if (headers != null) request.headers.addAll(headers);
    if (body != null) {
      final rawJson = jsonEncode(body);
      if (compress) {
        final packed = gzipBody(utf8.encode(rawJson));
        if (packed != null) {
          request.headers['content-encoding'] = 'gzip';
          request.bodyBytes = packed;
        } else {
          request.body = rawJson;
        }
      } else {
        request.body = rawJson;
      }
    }
    final response = await http.Response.fromStream(await client.send(request));
    if (response.statusCode == 204 && response.body.trim().isEmpty) {
      return const <String, dynamic>{};
    }
    Map<String, dynamic> value;
    try {
      value = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw ApiError(
        response.statusCode,
        'The service returned an unreadable response.',
      );
    }
    if (response.statusCode >= 400) {
      throw ApiError(
        response.statusCode,
        (value['error'] ?? value['message'] ?? 'Request failed').toString(),
        details: value,
      );
    }
    return value;
  }
}
