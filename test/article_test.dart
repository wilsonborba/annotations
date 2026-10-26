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
            'author': {
              'id': 'wilson',
              'name': 'Wilson Borba',
              'url': 'https://wilsonborba.com/',
            },
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
    expect(find.text('ภาษาของเนื้อหา'), findsOneWidget);
    expect(find.text('A plain readable paragraph.'), findsOneWidget);
    expect(requested, ['en']);
    final selector = tester.widget<DropdownButton<String>>(
      find.byKey(const Key('content-language-dropdown')),
    );
    expect(selector.items!.map((i) => i.value), ['en', 'pt-BR']);
    expect(selector.value, 'en');
    final th = tester.widget<Container>(
      find.descendant(
        of: find.byKey(const Key('language-th')),
        matching: find.byType(Container),
      ),
    );
    expect((th.decoration as BoxDecoration).color, isNot(Colors.transparent));
    expect(find.byKey(const Key('author-link')), findsOneWidget);
    expect(find.text('Wilson Borba'), findsWidgets);
    expect(find.text('wilsonborba.com'), findsOneWidget);
    expect(find.textContaining('ASODYA'), findsNothing);
    expect(find.byKey(const Key('footer-about')), findsOneWidget);
    expect(find.byKey(const Key('footer-api')), findsOneWidget);
  });
}
