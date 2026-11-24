import 'dart:convert';

import 'package:annotations_shared/dal/local/reports_private_cache.dart';
import 'package:annotations_shared/dal/remote/reports_api_adapter.dart';
import 'package:annotations_shared/domain/models/reports_card_reference.dart';
import 'package:annotations_shared/domain/models/reports_embed_data.dart';
import 'package:annotations_shared/domain/services/reports_embed_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('Reports API adapter', () {
    test(
      'search uses the authenticated Reports route and server access fields',
      () async {
        final paths = <String>[];
        final client = MockClient((request) async {
          paths.add(request.url.path);
          expect(request.url.origin, 'https://api.asodya.com');
          expect(request.headers['cookie'], 'sid=session; csrf=csrf');
          if (request.url.path.endsWith('/me')) {
            expect(request.method, 'GET');
            return http.Response(
              jsonEncode({
                'user_id': 'trusted-user',
                'role': 'viewer',
                'is_super_admin': false,
                'admin_projects': [],
              }),
              200,
            );
          }
          expect(
            request.url.path,
            '/apps/reports/v1/me/projects/public/reports',
          );
          expect(request.method, 'GET');
          expect(request.url.queryParameters, {
            'page': '2',
            'page_size': '24',
            'lang': 'th',
            'q': 'sales',
            'tier': 'signed_in',
          });
          return http.Response(
            jsonEncode({
              'items': [
                {
                  'project': 'public',
                  'slug': 'sales',
                  'title': 'Sales',
                  'chart_types': ['bar'],
                  'audience': 'asodya',
                  'can_view': true,
                  'open_in_reports_url':
                      'https://reports.asodya.com/v1/menu/public/sales',
                },
              ],
              'page': 2,
              'page_size': 24,
              'total': 25,
              'language': 'th',
            }),
            200,
          );
        });
        final api = ReportsApiAdapter(
          client: client,
          headersProvider: ({required mutation}) async => {
            'cookie': 'sid=session; csrf=csrf',
            if (mutation) 'x-csrf-token': 'csrf',
          },
        );

        final session = await api.viewerSession();

        expect(session.userId, 'trusted-user');
        final result = await api.searchReports(
          session,
          project: 'public',
          query: ' sales ',
          tier: 'signed_in',
          language: 'th',
          page: 2,
          pageSize: 24,
        );
        final items = (result['items'] as List)
            .map(
              (item) =>
                  ReportsSearchItem.fromJson(item as Map<String, dynamic>),
            )
            .toList();
        expect(items.single.chartTypes, ['bar']);
        expect(items.single.canView, isTrue);
        expect(items.single.audience, 'asodya');
        expect(paths, [
          '/apps/reports/v1/me',
          '/apps/reports/v1/me/projects/public/reports',
        ]);
        expect(
          ReportsApiAdapter.reportsApiBase(
            'https://api.asodya.com/apps/annotations/v1',
          ),
          'https://api.asodya.com/apps/reports/v1',
        );
      },
    );

    test(
      'owner upload uses actual JSON contract, CSRF, idempotency and limits',
      () async {
        final requests = <http.Request>[];
        final client = MockClient((request) async {
          requests.add(request);
          if (request.url.path == '/apps/reports/v1/me') {
            return http.Response(jsonEncode({'user_id': 'trusted-user'}), 200);
          }
          expect(
            request.url.path,
            '/apps/reports/v1/me/projects/annotations/items',
          );
          expect(request.method, 'POST');
          expect(request.headers['x-csrf-token'], 'csrf');
          expect(request.headers['idempotency-key'], 'request-1');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['template_id'], 'bar');
          expect(body['template_version'], 2);
          expect(body['source_app'], 'annotations');
          expect(body['mapping'], {'label': 'name', 'value': 'count'});
          expect(body['rows'], [
            {'name': 'A', 'count': 2},
          ]);
          expect(body.containsKey('owner_id'), isFalse);
          expect(body.containsKey('audience'), isFalse);
          return http.Response(
            jsonEncode({
              'item': {
                'id': 'owner-item',
                'project': 'annotations',
                'report_slug': 'user-report',
                'dataset_id': 'primary',
                'embed_url':
                    '/projects/annotations/showcase/user-report/cards/primary/embed',
              },
              'mapping': body['mapping'],
              'config': body['config'],
              'rows': body['rows'],
            }),
            201,
          );
        });
        final api = ReportsApiAdapter(
          client: client,
          headersProvider: ({required mutation}) async => {
            'cookie': 'sid=session; csrf=csrf',
            if (mutation) 'x-csrf-token': 'csrf',
          },
        );
        final session = await api.viewerSession();
        final result = await api.createOwnerItem(
          session: session,
          project: 'annotations',
          title: 'Counts',
          templateId: 'bar',
          templateVersion: 2,
          mapping: {'label': 'name', 'value': 'count'},
          config: const {},
          rows: const [
            {'name': 'A', 'count': 2},
          ],
          idempotencyKey: 'request-1',
        );

        final reference = ReportsCardReference.tryParse(
          (result['item'] as Map)['embed_url'] as String,
        );
        expect(
          reference?.sourceUrl,
          'https://reports.asodya.com/v1/menu/annotations/user-report/primary',
        );
        expect(requests.map((r) => r.method), ['GET', 'GET', 'POST']);

        await expectLater(
          api.createOwnerItem(
            session: session,
            project: 'annotations',
            title: 'Too many rows',
            templateId: 'bar',
            templateVersion: 2,
            mapping: {'label': 'name'},
            config: const {},
            rows: List.generate(1001, (i) => {'name': '$i'}),
            idempotencyKey: 'request-2',
          ),
          throwsA(isA<ReportsUploadLimitException>()),
        );
      },
    );

    test(
      'snapshot capture is POST with no body and returns fixed snapshot id',
      () async {
        var posted = false;
        final client = MockClient((request) async {
          if (request.url.path == '/apps/reports/v1/me') {
            return http.Response(jsonEncode({'user_id': 'trusted-user'}), 200);
          }
          expect(request.method, 'POST');
          expect(
            request.url.path,
            '/apps/reports/v1/projects/annotations/reports/r/cards/primary/snapshots',
          );
          expect(request.url.queryParameters, {'lang': 'th'});
          expect(request.body, isEmpty);
          expect(request.headers['x-csrf-token'], 'csrf');
          posted = true;
          return http.Response(
            jsonEncode({
              'id': 'snapshot-1',
              'captured_at': '2026-11-24T10:00:00Z',
            }),
            201,
          );
        });
        final api = ReportsApiAdapter(
          client: client,
          headersProvider: ({required mutation}) async => {
            'cookie': 'sid=session; csrf=csrf',
            if (mutation) 'x-csrf-token': 'csrf',
          },
        );
        final session = await api.viewerSession();
        final meta = await api.captureSnapshot(
          session,
          const ReportsCardReference(
            project: 'annotations',
            report: 'r',
            dataset: 'primary',
          ),
          language: 'th',
        );
        expect(posted, isTrue);
        expect(meta['id'], 'snapshot-1');
      },
    );
  });

  group('Reports cache and public note boundary', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    test('account switch and sign-out clear every restricted entry', () async {
      SharedPreferences.setMockInitialValues({});
      final cache = PreferencesReportsPrivateCache();
      final source = ReportsEmbedSource(
        api: ReportsApiAdapter(
          client: MockClient((_) async => http.Response('{}', 500)),
          headersProvider: ({required mutation}) async => const {},
        ),
        cache: cache,
      );
      await cache.write('account-a', 'card', {'payload': 'private'});
      expect(await cache.read('account-a', 'card'), {'payload': 'private'});

      await cache.bindAccount('account-b');
      expect(await cache.readActive('card'), isNull);
      await cache.write('account-b', 'card', {'payload': 'other'});
      expect(await cache.read('account-b', 'card'), {'payload': 'other'});
      await source.clearRestrictedCache();
      expect(await cache.readActive('card'), isNull);
    });

    test(
      'public and restricted projections never request Reports data',
      () async {
        var requestCount = 0;
        final api = ReportsApiAdapter(
          client: MockClient((_) async {
            requestCount++;
            return http.Response('{}', 500);
          }),
          headersProvider: ({required mutation}) async => const {},
        );
        final source = ReportsEmbedSource(
          api: api,
          cache: PreferencesReportsPrivateCache(
            preferences: SharedPreferences.getInstance,
          ),
        );

        final result = await source.loadDocument(const {
          'kind': 'reports_embed',
          'report_id': 'report-1',
          'project_slug': 'private',
          'report_slug': 'report-1',
          'dataset_id': 'card-1',
          'mode': 'live',
          'source': 'link',
        }, publicProjection: true);

        expect(requestCount, 0);
        expect(result.state, ReportsEmbedState.restricted);
        expect(result.page, isNull);
        final projected = await source.loadDocument(const {
          'kind': 'reports_embed',
          'restricted': true,
          'report_id': 'report-1',
          'mode': 'live',
          'source': 'link',
        });
        expect(requestCount, 0);
        expect(projected.state, ReportsEmbedState.restricted);
        expect(projected.page, isNull);
        expect(requestCount, 0);
      },
    );

    test('live link maps the authorized view and complete data page', () async {
      final paths = <String>[];
      final api = ReportsApiAdapter(
        client: MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path.endsWith('/me')) {
            return http.Response(jsonEncode({'user_id': 'reader'}), 200);
          }
          if (request.url.path.endsWith('/reports/sales')) {
            return http.Response(
              jsonEncode({
                'project': 'public',
                'report': 'sales',
                'title': 'Sales',
                'updated_at': '2026-11-24T00:00:00Z',
                'datasets': [
                  {
                    'dataset_id': 'monthly',
                    'title': 'Monthly',
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
          expect(
            request.url.path,
            '/apps/reports/v1/projects/public/reports/sales/datasets/monthly',
          );
          return http.Response(
            jsonEncode({
              'dataset_id': 'monthly',
              'title': 'Monthly',
              'can_view': true,
              'fields': [
                {'name': 'month', 'type': 'string', 'role': 'dimension'},
                {'name': 'sales', 'type': 'integer', 'role': 'measure'},
              ],
              'rows': [
                {'month': 'Jan', 'sales': 11},
              ],
              'offset': 0,
              'limit': 5000,
              'total_rows': 1,
              'lineage': {
                'calculation_id': 'monthly-sales',
                'calculation_version': 3,
                'calculated_at': '2026-11-24T00:00:00Z',
              },
            }),
            200,
          );
        }),
        headersProvider: ({required mutation}) async => const {},
      );
      final source = ReportsEmbedSource(
        api: api,
        cache: PreferencesReportsPrivateCache(
          preferences: SharedPreferences.getInstance,
        ),
      );

      final result = await source.loadDocument(const {
        'kind': 'reports_embed',
        'report_id': 'sales',
        'project_slug': 'public',
        'report_slug': 'sales',
        'dataset_id': 'monthly',
        'mode': 'live',
        'source': 'link',
      }, trustedAccountId: 'reader');

      expect(result.canRender, isTrue);
      expect(result.reportView?.title, 'Sales');
      expect(result.page?.rows, [
        {'month': 'Jan', 'sales': 11},
      ]);
      expect(result.complete, isTrue);
      expect(paths, [
        '/apps/reports/v1/me',
        '/apps/reports/v1/projects/public/reports/sales',
        '/apps/reports/v1/projects/public/reports/sales/datasets/monthly',
        '/apps/reports/v1/me',
      ]);
    });

    test(
      'snapshot uses captured rows without requesting live report data',
      () async {
        final paths = <String>[];
        final api = ReportsApiAdapter(
          client: MockClient((request) async {
            paths.add(request.url.path);
            if (request.url.path.endsWith('/me')) {
              return http.Response(jsonEncode({'user_id': 'reader'}), 200);
            }
            expect(
              request.url.path,
              '/apps/reports/v1/projects/public/reports/sales/cards/monthly/snapshots/snap-1/content',
            );
            return http.Response(
              jsonEncode({
                'id': 'snap-1',
                'captured_at': '2026-11-01T00:00:00Z',
                'total_rows': 2,
                'descriptor': {
                  'dataset_id': 'monthly',
                  'title': 'Monthly',
                  'can_view': true,
                  'fields': [
                    {'name': 'month', 'type': 'string', 'role': 'dimension'},
                    {'name': 'sales', 'type': 'integer', 'role': 'measure'},
                  ],
                },
                'rows': [
                  {'month': 'Jan', 'sales': 7},
                ],
                'open_in_reports_url':
                    'https://reports.asodya.com/v1/menu/public/sales/monthly',
              }),
              200,
            );
          }),
          headersProvider: ({required mutation}) async => const {},
        );
        final source = ReportsEmbedSource(
          api: api,
          cache: PreferencesReportsPrivateCache(
            preferences: SharedPreferences.getInstance,
          ),
        );

        final result = await source.loadDocument(const {
          'kind': 'reports_embed',
          'report_id': '00000000-0000-4000-8000-000000000001',
          'project_slug': 'public',
          'report_slug': 'sales',
          'dataset_id': 'monthly',
          'mode': 'snapshot',
          'source': 'upload',
          'snapshot_id': 'snap-1',
        }, trustedAccountId: 'reader');

        expect(result.canRender, isTrue);
        expect(result.state, ReportsEmbedState.readable);
        expect(result.page?.rows, [
          {'month': 'Jan', 'sales': 7},
        ]);
        expect(result.complete, isFalse);
        expect(result.capturedAt, DateTime.utc(2026, 11, 1));
        expect(paths, [
          '/apps/reports/v1/me',
          '/apps/reports/v1/projects/public/reports/sales/cards/monthly/snapshots/snap-1/content',
          '/apps/reports/v1/me',
        ]);
      },
    );

    test('uploaded chart stores only the Reports owner item id', () async {
      SharedPreferences.setMockInitialValues({});
      final paths = <String>[];
      final id = '00000000-0000-4000-8000-000000000001';
      final api = ReportsApiAdapter(
        client: MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path.endsWith('/me')) {
            return http.Response(jsonEncode({'user_id': 'reader'}), 200);
          }
          expect(request.method, 'POST');
          expect(request.url.path, '/apps/reports/v1/me/projects/public/items');
          return http.Response(
            jsonEncode({
              'item': {
                'id': id,
                'project': 'public',
                'report_slug': 'upload-1',
                'dataset_id': 'primary',
                'embed_url':
                    '/projects/public/showcase/upload-1/cards/primary/embed',
              },
            }),
            201,
          );
        }),
        headersProvider: ({required mutation}) async => const {},
      );
      final source = ReportsEmbedSource(
        api: api,
        cache: PreferencesReportsPrivateCache(
          preferences: SharedPreferences.getInstance,
        ),
      );

      final result = await source.uploadRows(
        project: 'public',
        title: 'Uploaded table',
        templateId: 'bar',
        templateVersion: 2,
        mapping: const {'label': 'name', 'value': 'sales'},
        config: const {},
        rows: const [
          {'name': 'Jan', 'sales': 7},
        ],
        idempotencyKey: 'upload-request',
      );

      expect(result.toDocumentFields(), {
        'report_id': id,
        'project_slug': 'public',
        'report_slug': 'upload-1',
        'dataset_id': 'primary',
        'mode': 'live',
        'source': 'upload',
      });
      expect(paths, [
        '/apps/reports/v1/me',
        '/apps/reports/v1/me',
        '/apps/reports/v1/me/projects/public/items',
        '/apps/reports/v1/me',
      ]);
    });

    test(
      'live cache is shown offline only for the signed-in Reports account',
      () async {
        SharedPreferences.setMockInitialValues({});
        var offline = false;
        final api = ReportsApiAdapter(
          client: MockClient((request) async {
            if (request.url.path.endsWith('/me')) {
              return http.Response(jsonEncode({'user_id': 'reader'}), 200);
            }
            if (offline) return http.Response('{"error":"offline"}', 503);
            if (request.url.path.endsWith('/reports/sales')) {
              return http.Response(
                jsonEncode({
                  'project': 'public',
                  'report': 'sales',
                  'title': 'Sales',
                  'datasets': [
                    {
                      'dataset_id': 'monthly',
                      'title': 'Monthly',
                      'can_view': true,
                    },
                  ],
                }),
                200,
              );
            }
            return http.Response(
              jsonEncode({
                'dataset_id': 'monthly',
                'title': 'Monthly',
                'can_view': true,
                'rows': [
                  {'sales': 11},
                ],
                'offset': 0,
                'limit': 5000,
                'total_rows': 1,
              }),
              200,
            );
          }),
          headersProvider: ({required mutation}) async => const {},
        );
        final source = ReportsEmbedSource(
          api: api,
          cache: PreferencesReportsPrivateCache(
            preferences: SharedPreferences.getInstance,
          ),
          hasStoredViewerSession: () async => true,
        );
        const item = {
          'kind': 'reports_embed',
          'report_id': 'sales',
          'project_slug': 'public',
          'report_slug': 'sales',
          'dataset_id': 'monthly',
          'mode': 'live',
          'source': 'link',
        };

        final online = await source.loadDocument(
          item,
          trustedAccountId: 'reader',
        );
        offline = true;
        final cached = await source.loadDocument(
          item,
          trustedAccountId: 'reader',
        );

        expect(online.state, ReportsEmbedState.readable);
        expect(cached.state, ReportsEmbedState.offline);
        expect(cached.page?.rows, [
          {'sales': 11},
        ]);
        expect(cached.cachedAt, isNotNull);
      },
    );

    test(
      'account switch during a fetch discards the result and private cache',
      () async {
        SharedPreferences.setMockInitialValues({});
        var meCalls = 0;
        final api = ReportsApiAdapter(
          client: MockClient((request) async {
            if (request.url.path.endsWith('/me')) {
              meCalls++;
              return http.Response(
                jsonEncode({'user_id': meCalls == 1 ? 'reader-a' : 'reader-b'}),
                200,
              );
            }
            if (request.url.path.endsWith('/reports/sales')) {
              return http.Response(
                jsonEncode({
                  'project': 'public',
                  'report': 'sales',
                  'title': 'Sales',
                  'datasets': [
                    {
                      'dataset_id': 'monthly',
                      'title': 'Monthly',
                      'can_view': true,
                    },
                  ],
                }),
                200,
              );
            }
            return http.Response(
              jsonEncode({
                'dataset_id': 'monthly',
                'title': 'Monthly',
                'can_view': true,
                'rows': [
                  {'sales': 11},
                ],
                'offset': 0,
                'limit': 5000,
                'total_rows': 1,
              }),
              200,
            );
          }),
          headersProvider: ({required mutation}) async => const {},
        );
        final preferences = await SharedPreferences.getInstance();
        final source = ReportsEmbedSource(
          api: api,
          cache: PreferencesReportsPrivateCache(
            preferences: SharedPreferences.getInstance,
          ),
        );

        final result = await source.loadDocument(const {
          'kind': 'reports_embed',
          'report_id': 'sales',
          'project_slug': 'public',
          'report_slug': 'sales',
          'dataset_id': 'monthly',
          'mode': 'live',
          'source': 'link',
        }, trustedAccountId: 'reader-a');

        expect(result.state, ReportsEmbedState.signInRequired);
        expect(result.page, isNull);
        expect(meCalls, 2);
        expect(
          preferences.getKeys().where(
            (key) => key.startsWith('annotations.reports.restricted.v1.'),
          ),
          isEmpty,
        );
      },
    );
  });
}
