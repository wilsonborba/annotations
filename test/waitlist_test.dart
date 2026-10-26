import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:annotations/app.dart';
import 'fixtures.dart';

void main() {
  testWidgets('waitlist posts once and restores local registered state', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    var submitted = 0;
    final service = fixtureService(
      handler: (request) async {
        if (request.url.path == '/waitlist') {
          submitted++;
          return http.Response(jsonEncode({'status': 'registered'}), 200);
        }
        return http.Response('{"items":[]}', 200);
      },
    );
    await tester.pumpWidget(
      AnnotationsApp(
        trackingEnabled: false,
        initialLocation: '/v1/home',
        service: service,
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('waitlist-email')));
    await tester.enterText(
      find.byKey(const Key('waitlist-email')),
      'reader@example.com',
    );
    await tester.enterText(
      find.byKey(const Key('waitlist-message')),
      'Interested in sharing notes',
    );
    await tester.ensureVisible(find.byKey(const Key('waitlist-submit')));
    await tester.tap(find.byKey(const Key('waitlist-submit')));
    await tester.pumpAndSettle();
    expect(submitted, 1);
    expect(
      find.text('Your interest is registered. Thank you.'),
      findsOneWidget,
    );
    expect(
      (await SharedPreferences.getInstance()).getString('annotations.waitlist'),
      'registered',
    );
  });
  testWidgets('waitlist shows a backend error and stays unregistered', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final service = fixtureService(
      handler: (request) async => request.url.path == '/waitlist'
          ? http.Response('{"error":"Too many requests"}', 429)
          : http.Response('{"items":[]}', 200),
    );
    await tester.pumpWidget(
      AnnotationsApp(
        trackingEnabled: false,
        initialLocation: '/v1/home',
        service: service,
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('waitlist-email')));
    await tester.enterText(
      find.byKey(const Key('waitlist-email')),
      'reader@example.com',
    );
    await tester.enterText(find.byKey(const Key('waitlist-message')), 'Hello');
    await tester.ensureVisible(find.byKey(const Key('waitlist-submit')));
    await tester.tap(find.byKey(const Key('waitlist-submit')));
    await tester.pumpAndSettle();
    expect(find.text('Too many requests'), findsOneWidget);
    expect(
      (await SharedPreferences.getInstance()).getString('annotations.waitlist'),
      isNull,
    );
  });
}
