import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:annotations_shared/app.dart';
import 'fixtures.dart';

void main() {
  testWidgets('a historical post URL never requests the removed posts API', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'annotations.locale': 'th'});
    final requests = <String>[];
    final service = fixtureService(
      handler: (request) async {
        requests.add('${request.method} ${request.url.path}');
        return http.Response('{}', 404);
      },
    );
    await tester.pumpWidget(
      AnnotationsApp(
        trackingEnabled: false,
        service: service,
        initialLocation: '/v1/menu/wilson/rag?lang=en',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('not-found')), findsOneWidget);
    expect(requests, isEmpty);
  });
  testWidgets('missing or private notes show a not-found state', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final service = fixtureService(
      handler: (request) async => http.Response('{"error":"Not found"}', 404),
    );
    await tester.pumpWidget(
      AnnotationsApp(
        trackingEnabled: false,
        service: service,
        initialLocation: '/v1/menu/wilson/private-note',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('not-found')), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
  });
}
