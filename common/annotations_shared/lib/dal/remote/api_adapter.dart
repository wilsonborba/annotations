import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../core/settings.dart';

class ApiError implements Exception {
  final int status;
  final String message;
  ApiError(this.status, this.message);
  @override
  String toString() => message;
}

class ApiAdapter {
  final http.Client client;
  final String base;
  void Function(Object, StackTrace)? onError;
  ApiAdapter({http.Client? client, this.base = Settings.apiBase})
    : client = client ?? http.Client();
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String>? query,
  }) async {
    try {
      return await _request(path, method: method, body: body, query: query);
    } catch (error, stack) {
      onError?.call(error, stack);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _request(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String>? query,
  }) async {
    final uri = Uri.parse(
      '$base$path',
    ).replace(queryParameters: query?.isEmpty == true ? null : query);
    final request = http.Request(method, uri)
      ..headers['content-type'] = 'application/json';
    if (body != null) request.body = jsonEncode(body);
    final response = await http.Response.fromStream(await client.send(request));
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
      );
    }
    return value;
  }
}
