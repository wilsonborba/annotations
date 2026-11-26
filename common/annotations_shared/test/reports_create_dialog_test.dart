import 'dart:convert';
import 'dart:typed_data';

import 'package:annotations_shared/domain/models/reports_embed_data.dart';
import 'package:annotations_shared/domain/services/preferences.dart';
import 'package:annotations_shared/domain/services/reports_chart_data.dart';
import 'package:annotations_shared/domain/services/reports_embed_source.dart';
import 'package:annotations_shared/domain/services/note_reports_service.dart';
import 'package:annotations_shared/domain/services/native_auth_service.dart';
import 'package:annotations_shared/domain/services/reports_xlsx_data.dart';
import 'package:archive/archive.dart';
import 'package:annotations_shared/dal/remote/api_adapter.dart';
import 'package:annotations_shared/presentation/frontend/components/reports_create_dialog.dart';
import 'package:annotations_shared/presentation/frontend/components/scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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

  testWidgets('selects one worksheet and sends its rows through chart mapping', (
    tester,
  ) async {
    final tables = ReportsXlsxData.parse(
      fileId: 'workbook-1',
      name: 'quarterly.xlsx',
      bytes: _twoSheetWorkbook(),
    );
    final template = ReportsTemplateChoice.fromJson({
      'template_id': 'published-bar',
      'version': 2,
      'kind': 'chart',
      'visual': 'bar',
      'title': 'Quarterly sales',
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
      'options': [],
    });
    final preferences = Preferences()..locale = 'en';
    Map<String, Object?>? submitted;
    var requestCount = 0;
    final service = NoteReportsService(
      api: ApiAdapter(
        base: 'https://api.asodya.com/apps/annotations/v1',
        client: MockClient((request) async {
          requestCount++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(request.method, 'POST');
          expect(
            request.url.path,
            '/apps/annotations/v1/me/notes/server-note-1/reports',
          );
          expect(body['mode'], 'create');
          expect(body['project'], 'approved-project');
          expect(body['item'], {
            'title': 'Quarterly sales',
            'source_app': 'annotations',
            'template_id': 'published-bar',
            'template_version': 2,
            'audience': 'personal',
            'mapping': {'category': 'Month', 'value': 'Sales'},
            'config': {},
            'rows': [
              {'Month': 'Jan', 'Sales': 15},
            ],
          });
          final operationKey = body['operation_key'] as String;
          return http.Response(
            jsonEncode({
              'note_id': 'server-note-1',
              'report_item_id': '123e4567-e89b-42d3-a456-426614174000',
              'relation_kind': 'created_for_note',
              'operation_key': operationKey,
              'item': {
                'id': '123e4567-e89b-42d3-a456-426614174000',
                'project': 'approved-project',
                'report_slug': 'quarterly',
                'dataset_id': 'primary',
                'source_app': 'annotations',
                'template_id': 'published-bar',
                'template_version': 2,
                'audience': 'personal',
                'control_authority': 'user_owned',
                'etag': '"receipt"',
                'embed_url':
                    'https://reports.asodya.com/v1/menu/approved-project/quarterly/primary',
              },
            }),
            201,
          );
        }),
      ),
      session: const NativeSession(
        sessionId: 'session',
        csrfToken: 'csrf',
        verifiedUserId: 'owner-1',
      ),
    );
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
                    tables: tables,
                    create: ({required item, required operationKey}) async {
                      submitted = item;
                      return service.createChart(
                        serverNoteId: 'server-note-1',
                        project: 'approved-project',
                        operationKey: operationKey,
                        item: item,
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
    await tester.tap(find.byKey(const Key('reports-create-table')));
    await tester.pumpAndSettle();
    expect(find.text('quarterly.xlsx · Details · 1'), findsOneWidget);
    await tester.tap(find.text('quarterly.xlsx · Details · 1').last);
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(
        const Key(
          'reports-create-slot-published-bar-workbook-1::Details-category',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Month').last);
    await tester.pumpAndSettle();
    final valueField = find.byKey(
      const Key('reports-create-slot-published-bar-workbook-1::Details-value'),
    );
    await tester.ensureVisible(valueField);
    await tester.pumpAndSettle();
    await tester.tap(valueField);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sales').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reports-create-submit')));
    await tester.pumpAndSettle();
    expect((await result)?.reportSlug, 'quarterly');
    expect(submitted?['mapping'], {'category': 'Month', 'value': 'Sales'});
    expect(submitted?['rows'], [
      {'Month': 'Jan', 'Sales': 15},
    ]);
    expect(requestCount, 1);
  });
}

Uint8List _twoSheetWorkbook() {
  final archive = Archive();
  void add(String name, String text) =>
      archive.addFile(ArchiveFile.bytes(name, utf8.encode(text)));
  add(
    'xl/workbook.xml',
    '''
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<sheets><sheet name="Summary" sheetId="1" r:id="rId1"/><sheet name="Details" sheetId="2" r:id="rId2"/></sheets></workbook>''',
  );
  add('xl/_rels/workbook.xml.rels', '''
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>
<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>''');
  add(
    'xl/worksheets/sheet1.xml',
    '''
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>Summary</t></is></c></row><row r="2"><c r="A2" t="inlineStr"><is><t>All</t></is></c></row></sheetData></worksheet>''',
  );
  add(
    'xl/worksheets/sheet2.xml',
    '''
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>Month</t></is></c><c r="B1" t="inlineStr"><is><t>Sales</t></is></c></row><row r="2"><c r="A2" t="inlineStr"><is><t>Jan</t></is></c><c r="B2"><v>15</v></c></row></sheetData></worksheet>''',
  );
  return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
}
