import 'package:annotations_shared/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  testWidgets('legacy provider article routes do not fetch posts or previews', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
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
        initialLocation: '/v1/menu/wilson/chart?lang=en',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('not-found')), findsOneWidget);
    expect(requests, isEmpty);
  });
}
