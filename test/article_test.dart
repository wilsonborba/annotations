import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:annotations/app.dart';
import 'fixtures.dart';

void main() {
  testWidgets('Thai interface and English body have independent selectors', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'annotations.locale': 'th'});
    final requested = <String?>[];
    final service = fixtureService(
      handler: (request) async {
        requested.add(request.url.queryParameters['lang']);
        return http.Response(
          jsonEncode({
            'title': 'Retrieval basics',
            'summary': 'A demonstration',
            'slug': 'rag',
            'owner_id': 'wilson',
            'language': 'en',
            'available_languages': ['en', 'pt-BR'],
            'updated_at': 0,
            'topics': [],
            'body': {
              'blocks': [
                {'type': 'paragraph', 'text': 'A plain readable paragraph.'},
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
        initialLocation: '/v1/menu/wilson/rag?lang=en',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('ภาษาของเนื้อหา'), findsOneWidget);
    expect(find.text('A plain readable paragraph.'), findsOneWidget);
    expect(requested, ['en']);
    expect(find.byKey(const Key('content-language-en')), findsOneWidget);
    expect(find.byKey(const Key('content-language-pt-BR')), findsOneWidget);
    expect(find.text('Português'), findsOneWidget);
    expect(find.textContaining('ASODYA'), findsNothing);
    expect(find.byKey(const Key('footer-about')), findsOneWidget);
    expect(find.byKey(const Key('footer-api')), findsOneWidget);
  });
}
