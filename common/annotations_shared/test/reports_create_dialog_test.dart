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
      final digestByOperationKey = <String, String>{};
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
                        final digest = jsonEncode(item);
                        final previousDigest =
                            digestByOperationKey[operationKey];
                        if (previousDigest != null &&
                            previousDigest != digest) {
                          throw ApiError(409, 'operation_key_conflict');
                        }
                        digestByOperationKey[operationKey] = digest;
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
          Key('reports-create-slot-${template.selectionId}-csv-1-category'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('month').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(
          Key('reports-create-slot-${template.selectionId}-csv-1-value'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          Key('reports-create-slot-${template.selectionId}-csv-1-value'),
        ),
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
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('reports-create-title')))
            .enabled,
        isFalse,
      );
      // Simulate an edit attempt even if a caller retains a TextField handle;
      // an uncertain operation always retries its original payload snapshot.
      tester
              .widget<TextField>(find.byKey(const Key('reports-create-title')))
              .controller!
              .text =
          'Edited while outcome is unknown';

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
        Key(
          'reports-create-slot-${template.selectionId}-workbook-1::Details-category',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Month').last);
    await tester.pumpAndSettle();
    final valueField = find.byKey(
      Key(
        'reports-create-slot-${template.selectionId}-workbook-1::Details-value',
      ),
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

  testWidgets('a known validation rejection permits a new keyed intent', (
    tester,
  ) async {
    final table = ReportsChartSourceTable.parse(
      fileId: 'csv-validation',
      name: 'monthly.csv',
      bytes: Uint8List.fromList(utf8.encode('month,sales\nJan,12\n')),
    );
    final template = ReportsTemplateChoice.fromJson({
      'template_id': 'published-bar',
      'version': 1,
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
      'options': <Map<String, Object?>>[],
    });
    final preferences = Preferences()..locale = 'en';
    final attempts = <({Map<String, Object?> item, String key})>[];
    var rejectedOnce = false;
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
                      attempts.add((item: Map.of(item), key: operationKey));
                      if (!rejectedOnce) {
                        rejectedOnce = true;
                        throw ApiError(
                          422,
                          'invalid_report_item',
                          details: const {'code': 'invalid_report_item'},
                        );
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
    await tester.tap(
      find.byKey(
        Key(
          'reports-create-slot-${template.selectionId}-csv-validation-category',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('month').last);
    await tester.pumpAndSettle();
    final submit = find.byKey(const Key('reports-create-submit'));
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(attempts, hasLength(1));
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('reports-create-title')))
          .enabled,
      isTrue,
    );

    tester
            .widget<TextField>(find.byKey(const Key('reports-create-title')))
            .controller!
            .text =
        'Edited after rejection';
    await tester.pump();
    await tester.tap(submit);
    await tester.pumpAndSettle();

    expect(await result, isNotNull);
    expect(attempts, hasLength(2));
    expect(attempts[0].item['title'], 'Published bar');
    expect(attempts[1].item['title'], 'Edited after rejection');
    expect(attempts[1].key, isNot(attempts[0].key));
  });

  testWidgets('an operation-key conflict is shown without another create', (
    tester,
  ) async {
    final table = ReportsChartSourceTable.parse(
      fileId: 'csv-conflict',
      name: 'monthly.csv',
      bytes: Uint8List.fromList(utf8.encode('month,sales\nJan,12\n')),
    );
    final template = ReportsTemplateChoice.fromJson({
      'template_id': 'published-bar',
      'version': 1,
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
      'options': <Map<String, Object?>>[],
    });
    final preferences = Preferences()..locale = 'en';
    var requests = 0;
    await tester.pumpWidget(
      AppScope(
        preferences: preferences,
        service: fixtureService(),
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showReportsCreateDialog(
                  context,
                  projectName: 'Approved project',
                  templates: [template],
                  tables: [table],
                  create: ({required item, required operationKey}) async {
                    requests++;
                    throw ApiError(
                      409,
                      'operation_key_conflict',
                      details: const {'code': 'operation_key_conflict'},
                    );
                  },
                ),
                child: const Text('Open create dialog'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open create dialog'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        Key(
          'reports-create-slot-${template.selectionId}-csv-conflict-category',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('month').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reports-create-submit')));
    await tester.pumpAndSettle();

    expect(requests, 1);
    expect(
      find.text(
        'This chart request conflicts with an earlier attempt. Check Reports before starting another chart.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('reports-create-submit')), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('reports-create-title')))
          .enabled,
      isFalse,
    );
  });

  testWidgets('selects and creates with the chosen published template version', (
    tester,
  ) async {
    ReportsTemplateChoice choice(
      int version,
      String title,
      String orientation,
    ) => ReportsTemplateChoice.fromJson({
      'template_id': 'shared-template',
      'version': version,
      'kind': 'chart',
      'visual': 'bar',
      'title': title,
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
          'default_value': orientation,
          'allowed_values': ['vertical', 'horizontal'],
        },
      ],
    });

    final first = choice(1, 'Published bar', 'vertical');
    final second = choice(2, 'Published bar', 'horizontal');
    expect(first.templateId, second.templateId);
    expect(first.selectionId, isNot(second.selectionId));
    final table = ReportsChartSourceTable.parse(
      fileId: 'csv-version',
      name: 'monthly.csv',
      bytes: Uint8List.fromList(utf8.encode('month,sales\nJan,12\n')),
    );
    Map<String, Object?>? postedItem;
    var requestCount = 0;
    final service = NoteReportsService(
      api: ApiAdapter(
        base: 'https://api.asodya.com/apps/annotations/v1',
        client: MockClient((request) async {
          requestCount++;
          expect(request.method, 'POST');
          expect(
            request.url.path,
            '/apps/annotations/v1/me/notes/server-note-1/reports',
          );
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          postedItem = Map<String, Object?>.from(body['item'] as Map);
          expect(body['mode'], 'create');
          expect(body['project'], 'approved-project');
          final item = body['item'] as Map<String, dynamic>;
          expect(item['template_id'], 'shared-template');
          expect(item['template_version'], 2);
          expect(item['title'], 'Published bar');
          expect(item['config'], {'orientation': 'horizontal'});
          return http.Response(
            jsonEncode({
              'note_id': 'server-note-1',
              'report_item_id': '123e4567-e89b-42d3-a456-426614174000',
              'relation_kind': 'created_for_note',
              'operation_key': body['operation_key'],
              'item': {
                'id': '123e4567-e89b-42d3-a456-426614174000',
                'project': 'approved-project',
                'report_slug': 'versioned-report',
                'dataset_id': 'primary',
                'source_app': 'annotations',
                'template_id': item['template_id'],
                'template_version': item['template_version'],
                'audience': 'personal',
                'control_authority': 'user_owned',
                'etag': '"receipt"',
                'embed_url':
                    'https://reports.asodya.com/v1/menu/approved-project/versioned-report/primary',
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
    final preferences = Preferences()..locale = 'en';
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
                    templates: [first, second],
                    tables: [table],
                    create: ({required item, required operationKey}) =>
                        service.createChart(
                          serverNoteId: 'server-note-1',
                          project: 'approved-project',
                          operationKey: operationKey,
                          item: item,
                        ),
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
    await tester.tap(find.byKey(const Key('reports-create-template')));
    await tester.pumpAndSettle();
    expect(find.text('Published bar · v1'), findsWidgets);
    expect(find.text('Published bar · v2'), findsWidgets);
    await tester.tap(find.text('Published bar · v2'));
    await tester.pumpAndSettle();

    final categoryField = find.byKey(
      Key('reports-create-slot-${second.selectionId}-csv-version-category'),
    );
    await tester.tap(categoryField);
    await tester.pumpAndSettle();
    await tester.tap(find.text('month').last);
    await tester.pumpAndSettle();
    final valueField = find.byKey(
      Key('reports-create-slot-${second.selectionId}-csv-version-value'),
    );
    await tester.ensureVisible(valueField);
    await tester.pumpAndSettle();
    await tester.tap(valueField);
    await tester.pumpAndSettle();
    await tester.tap(find.text('sales').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reports-create-submit')));
    await tester.pumpAndSettle();

    expect((await result)?.reportSlug, 'versioned-report');
    expect(postedItem?['template_id'], 'shared-template');
    expect(postedItem?['template_version'], 2);
    expect(postedItem?['title'], 'Published bar');
    expect(postedItem?['config'], {'orientation': 'horizontal'});
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
