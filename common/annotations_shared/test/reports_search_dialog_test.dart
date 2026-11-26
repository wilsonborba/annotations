import 'dart:convert';

import 'package:annotations_shared/dal/remote/reports_api_adapter.dart';
import 'package:annotations_shared/domain/models/reports_embed_data.dart';
import 'package:annotations_shared/domain/services/annotations_service.dart';
import 'package:annotations_shared/domain/services/preferences.dart';
import 'package:annotations_shared/dal/remote/api_adapter.dart';
import 'package:annotations_shared/domain/services/reports_embed_source.dart';
import 'package:annotations_shared/presentation/frontend/components/reports_search_dialog.dart';
import 'package:annotations_shared/presentation/frontend/components/scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pumpFrames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('search filters access and adds the selected live dataset', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final requests = <http.Request>[];
    final api = ReportsApiAdapter(
      client: MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/me')) {
          return http.Response(jsonEncode({'user_id': 'viewer-1'}), 200);
        }
        if (request.url.path.endsWith('/projects/work/reports')) {
          expect(request.method, 'GET');
          expect(request.url.queryParameters['q'], 'sales');
          return http.Response(
            jsonEncode({
              'items': [
                {
                  'project': 'work',
                  'slug': 'sales',
                  'title': 'Sales overview',
                  'chart_types': ['bar'],
                  'audience': 'personal',
                  'can_view': true,
                  'open_in_reports_url':
                      'https://reports.asodya.com/v1/menu/work/sales',
                },
                {
                  'project': 'work',
                  'slug': 'hidden',
                  'title': 'HIDDEN REPORT',
                  'chart_types': ['table'],
                  'audience': 'personal',
                  'can_view': false,
                  'open_in_reports_url': '',
                },
              ],
              'page': 1,
              'page_size': 12,
              'total': 2,
              'language': 'en',
            }),
            200,
          );
        }
        if (request.url.path.endsWith('/projects/work/reports/sales')) {
          expect(request.method, 'GET');
          return http.Response(
            jsonEncode({
              'project': 'work',
              'report': 'sales',
              'title': 'Sales overview',
              'datasets': [
                {
                  'dataset_id': 'monthly',
                  'title': 'Monthly sales',
                  'can_view': true,
                  'fields': [
                    {'name': 'month', 'type': 'string', 'role': 'dimension'},
                    {'name': 'sales', 'type': 'integer', 'role': 'measure'},
                  ],
                },
              ],
            }),
            200,
          );
        }
        throw StateError('Unexpected Reports request: ${request.url.path}');
      }),
      headersProvider: ({required mutation}) async => const {
        'cookie': 'session=fixture',
      },
    );
    final source = ReportsEmbedSource(api: api);
    final preferences = Preferences()..locale = 'en';
    Future<ReportsEmbedReference?>? result;

    await tester.pumpWidget(
      AppScope(
        preferences: preferences,
        service: AnnotationsService(
          api: ApiAdapter(
            client: MockClient((_) async => throw StateError('unused app API')),
          ),
        ),
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  result = showReportsSearchDialog(
                    context,
                    source: source,
                    project: 'work',
                    language: 'en',
                  );
                },
                child: const Text('Open Reports search'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open Reports search'));
    await _pumpFrames(tester);
    await tester.enterText(
      find.byKey(const Key('reports-search-query')),
      'sales',
    );
    await tester.tap(find.byKey(const Key('reports-search-submit')));
    await _pumpFrames(tester);

    expect(find.text('Sales overview'), findsOneWidget);
    expect(find.text('HIDDEN REPORT'), findsNothing);
    expect(find.textContaining('Personal'), findsOneWidget);

    await tester.tap(find.byKey(const Key('reports-search-result-sales')));
    await _pumpFrames(tester);
    expect(find.text('Monthly sales'), findsOneWidget);
    await tester.tap(find.byKey(const Key('reports-dataset-monthly')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('reports-mode-live')));
    await tester.pump();
    final addButton = tester.widget<FilledButton>(
      find.byKey(const Key('reports-add-embed')),
    );
    expect(addButton.onPressed, isNotNull);
    await tester.tap(find.byKey(const Key('reports-add-embed')));
    await _pumpFrames(tester);

    final selected = await result!.timeout(const Duration(seconds: 2));
    expect(selected, isNotNull);
    expect(selected!.toDocumentFields(), {
      'report_id': 'sales',
      'project_slug': 'work',
      'report_slug': 'sales',
      'dataset_id': 'monthly',
      'mode': 'live',
      'source': 'link',
    });
    expect(
      requests.any((r) => r.url.path.endsWith('/projects/work/reports/hidden')),
      isFalse,
    );
  });

  testWidgets('snapshot mode records the captured identity and time', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/me')) {
        return http.Response(jsonEncode({'user_id': 'viewer-1'}), 200);
      }
      if (request.url.path.endsWith('/projects/work/reports')) {
        return http.Response(
          jsonEncode({
            'items': [
              {
                'project': 'work',
                'slug': 'sales',
                'title': 'Sales',
                'chart_types': ['bar'],
                'audience': 'public',
                'can_view': true,
                'open_in_reports_url':
                    'https://reports.asodya.com/v1/menu/work/sales',
              },
            ],
            'page': 1,
            'page_size': 12,
            'total': 1,
            'language': 'en',
          }),
          200,
        );
      }
      if (request.url.path.endsWith('/projects/work/reports/sales')) {
        return http.Response(
          jsonEncode({
            'project': 'work',
            'report': 'sales',
            'title': 'Sales',
            'datasets': [
              {
                'dataset_id': 'monthly',
                'title': 'Monthly sales',
                'can_view': true,
                'fields': [
                  {'name': 'month', 'type': 'string', 'role': 'dimension'},
                  {'name': 'sales', 'type': 'integer', 'role': 'measure'},
                ],
              },
            ],
          }),
          200,
        );
      }
      if (request.url.path.endsWith('/snapshots')) {
        expect(request.method, 'POST');
        expect(request.body, isEmpty);
        return http.Response(
          jsonEncode({
            'id': '00000000-0000-4000-8000-000000000001',
            'project': 'work',
            'report': 'sales',
            'dataset_id': 'monthly',
            'captured_at': '2026-11-24T10:00:00Z',
          }),
          201,
        );
      }
      throw StateError('Unexpected Reports request: ${request.url.path}');
    });
    final source = ReportsEmbedSource(
      api: ReportsApiAdapter(
        client: client,
        headersProvider: ({required mutation}) async => const {
          'cookie': 'session=fixture',
          'x-csrf-token': 'fixture',
        },
      ),
    );
    final preferences = Preferences()..locale = 'en';
    Future<ReportsEmbedReference?>? result;
    await tester.pumpWidget(
      AppScope(
        preferences: preferences,
        service: AnnotationsService(
          api: ApiAdapter(
            client: MockClient((_) async => throw StateError('unused app API')),
          ),
        ),
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  result = showReportsSearchDialog(
                    context,
                    source: source,
                    project: 'work',
                    language: 'en',
                  );
                },
                child: const Text('Open Reports search'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open Reports search'));
    await _pumpFrames(tester);
    await tester.enterText(
      find.byKey(const Key('reports-search-query')),
      'sales',
    );
    await tester.tap(find.byKey(const Key('reports-search-submit')));
    await _pumpFrames(tester);
    await tester.tap(find.byKey(const Key('reports-search-result-sales')));
    await _pumpFrames(tester);
    await tester.tap(find.byKey(const Key('reports-dataset-monthly')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('reports-mode-snapshot')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('reports-add-embed')));
    await _pumpFrames(tester);

    final selected = await result!.timeout(const Duration(seconds: 2));
    expect(selected?.mode, 'snapshot');
    expect(selected?.snapshotId, '00000000-0000-4000-8000-000000000001');
    expect(
      selected?.capturedAt,
      DateTime.utc(2026, 11, 24, 10).millisecondsSinceEpoch ~/ 1000,
    );
  });
}
