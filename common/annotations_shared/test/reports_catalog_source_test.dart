import 'dart:convert';

import 'package:annotations_shared/dal/remote/reports_api_adapter.dart';
import 'package:annotations_shared/domain/services/reports_embed_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('uses the published project and template discovery contracts', () async {
    SharedPreferences.setMockInitialValues({});
    final requests = <http.Request>[];
    final source = ReportsEmbedSource(
      api: ReportsApiAdapter(
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/me')) {
            return http.Response(jsonEncode({'user_id': 'owner-1'}), 200);
          }
          if (request.url.path.endsWith('/catalog')) {
            expect(request.url.queryParameters, {
              'lang': 'th',
              'page': '1',
              'page_size': '100',
            });
            return http.Response(
              jsonEncode({
                'items': [
                  {
                    'slug': 'actual-project',
                    'name': 'Actual project',
                    'report_count': 3,
                  },
                ],
                'page': 1,
                'page_size': 100,
                'total': 1,
                'language': 'th',
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/projects/actual-project/templates')) {
            expect(request.url.queryParameters['lang'], 'th');
            return http.Response(
              jsonEncode({
                'templates': [
                  {
                    'template_id': 'published-bar',
                    'version': 4,
                    'kind': 'chart',
                    'visual': 'bar',
                    'title': 'Published bar',
                    'slots': [
                      {
                        'slot_name': 'category',
                        'role': 'dimension',
                        'is_required': true,
                        'min_count': 1,
                        'max_count': 1,
                        'accepted_types': ['string'],
                      },
                    ],
                    'options': [
                      {
                        'option_name': 'orientation',
                        'value_type': 'enum',
                        'default_value': 'vertical',
                        'allowed_values': ['vertical', 'horizontal'],
                      },
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
      ),
    );

    final projects = await source.allProjects(language: 'th');
    expect(projects, hasLength(1));
    expect(projects.single.slug, 'actual-project');
    expect(projects.single.reportCount, 3);

    final templates = await source.templatesForProject(
      projects.single.slug,
      language: 'th',
    );
    expect(templates, hasLength(1));
    expect(templates.single.templateId, 'published-bar');
    expect(templates.single.version, 4);
    expect(templates.single.slots.single['slot_name'], 'category');
    expect(templates.single.options.single['allowed_values'], [
      'vertical',
      'horizontal',
    ]);
    expect(
      requests
          .map((request) => request.url.path)
          .where((path) => path.endsWith('/catalog')),
      hasLength(1),
    );
  });
}
