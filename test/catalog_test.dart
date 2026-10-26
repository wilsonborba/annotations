import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:annotations/app.dart';
import 'fixtures.dart';

void main() {
  testWidgets('catalog sends route query and renders public results', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    String? query;
    final service = fixtureService(
      handler: (request) async {
        if (request.url.path == '/catalog') {
          return http.Response('{"topics":[],"channels":[]}', 200);
        }
        query = request.url.queryParameters['q'];
        return http.Response(
          jsonEncode({
            'items': [
              {
                'title': 'Retrieval basics',
                'summary': 'Example',
                'slug': 'rag',
                'language': 'en',
                'channels': ['wilson'],
                'topics': ['rag'],
              },
            ],
          }),
          200,
        );
      },
    );
    await tester.pumpWidget(
      AnnotationsApp(service: service, initialLocation: '/v1/menu?q=retrieval'),
    );
    await tester.pumpAndSettle();
    expect(query, 'retrieval');
    expect(find.text('Retrieval basics'), findsOneWidget);
    expect(find.byKey(const Key('catalog-search')), findsOneWidget);
  });
}
