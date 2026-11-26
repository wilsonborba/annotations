import 'dart:convert';
import 'dart:typed_data';

import 'package:annotations_shared/domain/models/reports_embed_data.dart';
import 'package:annotations_shared/domain/services/preferences.dart';
import 'package:annotations_shared/domain/services/reports_chart_data.dart';
import 'package:annotations_shared/domain/services/reports_embed_source.dart';
import 'package:annotations_shared/presentation/frontend/components/reports_create_dialog.dart';
import 'package:annotations_shared/presentation/frontend/components/scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

void main() {
  testWidgets(
    'maps actual table columns and retries with the same receipt key',
    (tester) async {
      final table = ReportsChartSourceTable.parse(
        fileId: 'csv-1',
        name: 'monthly.csv',
        bytes: Uint8List.fromList(utf8.encode('month,sales\nJan,12\nFeb,14\n')),
      );
      final template = ReportsTemplateChoice.fromJson({
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
          {
            'slot_name': 'value',
            'role': 'measure',
            'is_required': true,
            'min_count': 1,
            'max_count': 1,
            'accepted_types': ['integer', 'float'],
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
      });
      final preferences = Preferences()..locale = 'en';
      final calls = <({Map<String, Object?> item, String key})>[];
      var attempt = 0;
      Future<ReportsEmbedReference?>? result;

      await tester.pumpWidget(
        AppScope(
          preferences: preferences,
          service: fixtureService(),
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () {
                    result = showReportsCreateDialog(
                      context,
                      projectName: 'Approved project',
                      templates: [template],
                      tables: [table],
                      create: ({required item, required operationKey}) async {
                        calls.add((item: item, key: operationKey));
                        if (attempt++ == 0) {
                          throw StateError('retryable request failure');
                        }
                        return const ReportsEmbedReference(
                          reportId: '123e4567-e89b-42d3-a456-426614174000',
                          projectSlug: 'approved-project',
                          reportSlug: 'created-report',
                          datasetId: 'primary',
                          mode: 'live',
                          source: 'upload',
                        );
                      },
                    );
                  },
                  child: const Text('Open create dialog'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open create dialog'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reports-create-submit')), findsOneWidget);

      await tester.tap(
        find.byKey(
          const Key('reports-create-slot-published-bar-csv-1-category'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('month').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('reports-create-slot-published-bar-csv-1-value')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('reports-create-slot-published-bar-csv-1-value')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('sales').last);
      await tester.pumpAndSettle();

      final submit = find.byKey(const Key('reports-create-submit'));
      expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reports-create-error')), findsOneWidget);
      expect(calls, hasLength(1));

      await tester.tap(submit);
      await tester.pumpAndSettle();
      final created = await result;
      expect(created?.reportSlug, 'created-report');
      expect(calls, hasLength(2));
      expect(calls[1].key, calls[0].key);
      expect(calls[0].item, {
        'title': 'Published bar',
        'source_app': 'annotations',
        'template_id': 'published-bar',
        'template_version': 4,
        'audience': 'personal',
        'mapping': {'category': 'month', 'value': 'sales'},
        'config': {'orientation': 'vertical'},
        'rows': [
          {'month': 'Jan', 'sales': 12},
          {'month': 'Feb', 'sales': 14},
        ],
      });
      expect(calls[1].item, calls[0].item);
    },
  );
}
