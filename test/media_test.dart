import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:annotations/app.dart';
import 'fixtures.dart';

void main() {
  testWidgets('provider cards and one Reports embed render in an article', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final service = fixtureService(
      handler: (request) async {
        if (request.url.path == '/links/preview') {
          return http.Response(
            '{"domain":"drive.google.com","title":"Study PDF","provider":"google-drive","thumbnail":""}',
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'title': 'Sources and a chart',
            'summary': '',
            'owner_id': 'wilson',
            'language': 'en',
            'available_languages': ['en'],
            'updated_at': 0,
            'topics': [],
            'body': {
              'blocks': [
                {
                  'type': 'pdf',
                  'url': 'https://drive.google.com/file/d/example/view',
                },
                {
                  'type': 'reports',
                  'url':
                      'https://reports.asodya.com/v1/embed/cortex/example/chart',
                  'source_url':
                      'https://reports.asodya.com/v1/menu/cortex/example/chart',
                },
              ],
            },
          }),
          200,
        );
      },
    );
    await tester.pumpWidget(
      AnnotationsApp(
        service: service,
        initialLocation: '/v1/menu/wilson/chart',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Study PDF'), findsOneWidget);
    expect(find.byIcon(Icons.picture_as_pdf_outlined), findsOneWidget);
    expect(find.text('Open original'), findsOneWidget);
  });
  testWidgets('a failed link preview falls back to the URL domain', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final service = fixtureService(
      handler: (request) async {
        if (request.url.path == '/links/preview') {
          return http.Response('{"error":"unavailable"}', 502);
        }
        return http.Response(
          jsonEncode({
            'title': 'A source',
            'summary': '',
            'language': 'en',
            'available_languages': ['en'],
            'updated_at': 0,
            'topics': [],
            'body': {
              'blocks': [
                {'type': 'link', 'url': 'https://example.org/paper'},
              ],
            },
          }),
          200,
        );
      },
    );
    await tester.pumpWidget(
      AnnotationsApp(service: service, initialLocation: '/v1/menu/wilson/src'),
    );
    await tester.pumpAndSettle();
    expect(find.text('example.org'), findsWidgets);
  });
}
