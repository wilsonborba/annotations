import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:annotations_shared/app.dart';
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
        // annotations_api public discovery (GET /notes, #40).
        expect(request.url.path, '/notes');
        query = request.url.queryParameters['q'];
        return http.Response(
          jsonEncode({
            'items': [
              {
                'note_id': 'n1',
                'author_id': 'a1',
                'author_name': 'Wilson',
                'title': 'Retrieval basics',
                'summary': 'Example',
                'language': 'en',
                'tags': ['rag'],
                'views': ['original', 'typed'],
                'default_view': 'original',
                'published_at': 1794996000,
              },
            ],
            'next_cursor': null,
            'browse_token': 'b1',
          }),
          200,
        );
      },
    );
    await tester.pumpWidget(
      AnnotationsApp(
        trackingEnabled: false,
        service: service,
        initialLocation: '/v1/menu?q=retrieval',
      ),
    );
    await tester.pumpAndSettle();
    expect(query, 'retrieval');
    expect(find.text('Retrieval basics'), findsOneWidget);
    expect(find.byKey(const Key('catalog-search')), findsOneWidget);
  });
  testWidgets('catalog shows empty and failure states', (tester) async {
    SharedPreferences.setMockInitialValues({});
    var fail = false;
    final service = fixtureService(
      handler: (request) async {
        if (request.url.path == '/catalog') {
          return http.Response('{"topics":[],"channels":[]}', 200);
        }
        return fail
            ? http.Response('{"error":"down"}', 503)
            : http.Response('{"items":[]}', 200);
      },
    );
    await tester.pumpWidget(
      AnnotationsApp(
        trackingEnabled: false,
        service: service,
        initialLocation: '/v1/menu?q=none',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No notes here yet. Try another topic.'), findsOneWidget);
    fail = true;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      AnnotationsApp(
        trackingEnabled: false,
        service: service,
        initialLocation: '/v1/menu?q=down',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('This content could not be loaded.'), findsOneWidget);
  });
}
