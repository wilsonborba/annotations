import 'dart:convert';

import 'package:annotations_shared/dal/remote/api_adapter.dart';
import 'package:annotations_shared/domain/services/native_auth_service.dart';
import 'package:annotations_shared/domain/services/note_reports_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'creates through the saved note receipt and parses its flat metadata',
    () async {
      final requests = <http.Request>[];
      final api = ApiAdapter(
        base: 'https://api.asodya.com/apps/annotations/v1',
        client: MockClient((request) async {
          requests.add(request);
          expect(request.method, 'POST');
          expect(
            request.url.path,
            '/apps/annotations/v1/me/notes/server-note-1/reports',
          );
          expect(request.headers['cookie'], 'sid=session; csrf=csrf');
          expect(request.headers['x-csrf-token'], 'csrf');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['mode'], 'create');
          expect(body['project'], 'approved-project');
          expect(body['operation_key'], 'operation-1');
          expect(body['item'], {
            'title': 'Monthly sales',
            'source_app': 'annotations',
            'template_id': 'bar-v1',
            'template_version': 3,
            'audience': 'personal',
            'mapping': {'category': 'month', 'value': 'sales'},
            'config': {'orientation': 'vertical'},
            'rows': [
              {'month': 'Jan', 'sales': 12},
              {'month': 'Feb', 'sales': 14},
            ],
          });
          return http.Response(
            jsonEncode({
              'note_id': 'server-note-1',
              'report_item_id': '123e4567-e89b-42d3-a456-426614174000',
              'relation_kind': 'created_for_note',
              'operation_key': 'operation-1',
              'item': {
                'id': '123e4567-e89b-42d3-a456-426614174000',
                'project': 'approved-project',
                'report_slug': 'user-viewer-report',
                'dataset_id': 'primary',
                'source_app': 'annotations',
                'template_id': 'bar-v1',
                'template_version': 3,
                'audience': 'personal',
                'control_authority': 'user_owned',
                'etag': '"receipt-etag"',
                'embed_url':
                    'https://reports.asodya.com/v1/menu/approved-project/user-viewer-report/primary',
              },
            }),
            201,
          );
        }),
      );
      final service = NoteReportsService(
        api: api,
        session: const NativeSession(
          sessionId: 'session',
          csrfToken: 'csrf',
          verifiedUserId: 'owner-1',
        ),
      );

      final result = await service.createChart(
        serverNoteId: 'server-note-1',
        project: 'approved-project',
        operationKey: 'operation-1',
        item: const {
          'title': 'Monthly sales',
          'source_app': 'annotations',
          'template_id': 'bar-v1',
          'template_version': 3,
          'audience': 'personal',
          'mapping': {'category': 'month', 'value': 'sales'},
          'config': {'orientation': 'vertical'},
          'rows': [
            {'month': 'Jan', 'sales': 12},
            {'month': 'Feb', 'sales': 14},
          ],
        },
      );

      expect(requests, hasLength(1));
      expect(result.reportId, '123e4567-e89b-42d3-a456-426614174000');
      expect(result.projectSlug, 'approved-project');
      expect(result.reportSlug, 'user-viewer-report');
      expect(result.datasetId, 'primary');
      expect(result.mode, 'live');
      expect(result.source, 'upload');
    },
  );

  test(
    'rejects a receipt whose server note or operation key differs',
    () async {
      final service = NoteReportsService(
        api: ApiAdapter(
          base: 'https://api.asodya.com/apps/annotations/v1',
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'note_id': 'other-note',
                'report_item_id': '123e4567-e89b-42d3-a456-426614174000',
                'relation_kind': 'created_for_note',
                'operation_key': 'operation-1',
                'item': <String, Object?>{},
              }),
              201,
            ),
          ),
        ),
        session: const NativeSession(
          sessionId: 'session',
          csrfToken: 'csrf',
          verifiedUserId: 'owner-1',
        ),
      );
      await expectLater(
        service.createChart(
          serverNoteId: 'server-note-1',
          project: 'approved-project',
          operationKey: 'operation-1',
          item: const {'template_id': 'bar-v1', 'template_version': 3},
        ),
        throwsA(isA<FormatException>()),
      );
    },
  );
}
