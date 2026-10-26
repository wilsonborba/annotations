import 'dart:convert';
import 'dart:io';
import 'package:annotations/app.dart';
import 'package:annotations/core/tracking_manifest.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'fixtures.dart';

void main() {
  test('committed manifest matches every application element identity', () {
    final manifest =
        jsonDecode(File('tracking_manifest.json').readAsStringSync()) as Map;
    final entries = (manifest['elements'] as List).cast<Map<String, dynamic>>();
    expect(entries.length, annotationElements.length);
    for (final entry in entries) {
      final element = annotationElements[entry['id']]!;
      expect(element.valid, isTrue);
      expect(element.label, entry['label']);
      expect(element.path, entry['path']);
      expect(entry['description'], isNotEmpty);
    }
    for (final file
        in Directory('lib/presentation/frontend')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
      for (final match in RegExp(
        r"track\(\s*'([^']+)'",
      ).allMatches(file.readAsStringSync())) {
        expect(
          annotationElements.containsKey(match[1]),
          isTrue,
          reason: file.path,
        );
      }
    }
  });
  testWidgets(
    'catalog actions emit named clicks and typed text without network dependencies',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final sent = <Map<String, dynamic>>[];
      final tracker = AsodyaTracker(
        appId: 'annotations',
        baseUrl: 'http://tracking.test',
        buildVersion: 'test',
        screens: annotationScreens,
        autoFlush: false,
        client: MockClient((r) async {
          sent.add(jsonDecode(r.body) as Map<String, dynamic>);
          return http.Response('{}', 202);
        }),
      );
      await tester.pumpWidget(
        AnnotationsApp(
          trackingEnabled: false,
          tracker: tracker,
          service: fixtureService(),
          initialLocation: '/v1/menu',
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('theme-toggle')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('catalog-search')),
        'RAG study',
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      await tracker.flush();
      final events = sent
          .where((v) => v.containsKey('events'))
          .expand((v) => (v['events'] as List).cast<Map<String, dynamic>>())
          .toList();
      expect(
        events.any(
          (v) =>
              v['event_type'] == 'click' &&
              v['element_id'] == 'shell.theme.toggle',
        ),
        isTrue,
      );
      expect(
        events.any(
          (v) =>
              v['event_type'] == 'input' &&
              v['element_id'] == 'catalog.search.input' &&
              v['value'] == 'RAG study',
        ),
        isTrue,
      );
      expect(
        events.any(
          (v) => v['event_type'] == 'view' && v['route'] == '/v1/menu',
        ),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('Instant Share room capability is absent from typed telemetry', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final sent = <String>[];
    final tracker = AsodyaTracker(
      appId: 'annotations',
      baseUrl: 'http://tracking.test',
      buildVersion: 'test',
      screens: annotationScreens,
      autoFlush: false,
      client: MockClient((r) async {
        sent.add(r.body);
        return http.Response('{}', 202);
      }),
    );
    await tester.pumpWidget(
      AnnotationsApp(
        trackingEnabled: false,
        tracker: tracker,
        service: fixtureService(),
        initialLocation: '/v1/instant',
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'private-room-token');
    await tracker.flush();
    expect(sent.join(), isNot(contains('private-room-token')));
    expect(sent.join(), contains('instant.room.code'));
    await tester.pumpWidget(const SizedBox());
  });
}
