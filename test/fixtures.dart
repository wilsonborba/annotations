import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:annotations/domain/services/annotations_service.dart';
import 'package:annotations/dal/remote/api_adapter.dart';

AnnotationsService fixtureService({
  Future<http.Response> Function(http.Request)? handler,
}) => AnnotationsService(
  api: ApiAdapter(
    base: 'http://annotations.test',
    client: MockClient(
      handler ??
          (request) async => http.Response(
            jsonEncode(
              request.url.path == '/catalog'
                  ? {'topics': [], 'channels': [], 'languages': []}
                  : {'items': []},
            ),
            200,
            headers: {'content-type': 'application/json'},
          ),
    ),
  ),
);
