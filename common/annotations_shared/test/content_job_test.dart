import 'dart:convert';
import 'dart:io';

import 'package:annotations_shared/dal/remote/api_adapter.dart';
import 'package:annotations_shared/domain/services/content_job_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/annotations_api_contract.dart';

void main() {
  test(
    'disabled by default; reserves + uploads via /me/files, sends client_job_id & kind, persists on disk, and resumes SSE with ?after= & Last-Event-ID without re-upload',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'annotations_47_test_',
      );
      final persistFile = File('${tempDir.path}/content_jobs.json');
      try {
        final requests =
            <
              ({
                String method,
                String path,
                Map<String, String> query,
                Map<String, String> headers,
                String body,
              })
            >[];
        var ssePollCount = 0;

        final mock = AnnotationsApiContract(
          onValid: (req, body) async {
            requests.add((
              method: req.method,
              path: req.url.path,
              query: Map<String, String>.from(req.url.queryParameters),
              headers: Map<String, String>.from(req.headers),
              body: req.body,
            ));
            if (req.method == 'POST' && req.url.path.endsWith('/me/files')) {
              expect(body?['purpose'], 'content_job');
              expect(body?['filename'], 'a.pdf');
              expect(body?['content_type'], 'application/pdf');
              expect(body?['size'], isA<int>());
              expect(body?['checksum'], matches(RegExp(r'^[0-9a-f]{64}$')));
              expect(body?.containsKey('size_bytes'), isFalse);
              return http.Response(jsonEncode({'file_id': 'f_sel_1'}), 201);
            }
            if (req.method == 'PUT' &&
                req.url.path.endsWith('/me/files/f_sel_1/content')) {
              expect(req.bodyBytes, [1, 2, 3, 4]);
              return http.Response(
                jsonEncode({'file_id': 'f_sel_1', 'ready': true}),
                200,
              );
            }
            if (req.method == 'POST' &&
                req.url.path.endsWith('/me/content_jobs')) {
              final body = jsonDecode(req.body) as Map<String, dynamic>;
              expect(body.containsKey('note_id'), isFalse);
              expect(body['client_job_id'], isNotEmpty);
              expect(body['kind'], 'extraction');
              expect(body['file_ids'], ['f_sel_1']);
              return http.Response(
                jsonEncode({
                  'job_id': 'job_99',
                  'status': 'running',
                  'last_event_seq': 1,
                }),
                201,
              );
            }
            if (req.method == 'GET' &&
                req.url.path.endsWith('/me/content_jobs/job_99/events')) {
              ssePollCount++;
              if (ssePollCount == 1) {
                expect(req.url.queryParameters['after'], '1');
                expect(req.headers['last-event-id'], '1');
                return http.Response(
                  'id: 2\nevent: progress\ndata: {"status":"running"}\n\n',
                  200,
                  headers: {'content-type': 'text/event-stream'},
                );
              }
              expect(req.url.queryParameters['after'], '2');
              expect(req.headers['last-event-id'], '2');
              return http.Response(
                'id: 3\nevent: completed\ndata: {"status":"completed"}\n\n',
                200,
                headers: {'content-type': 'text/event-stream'},
              );
            }
            if (req.method == 'GET' &&
                req.url.path.endsWith('/me/content_jobs/job_99')) {
              return http.Response(
                jsonEncode({
                  'job_id': 'job_99',
                  'status': 'completed',
                  'draft': {'format': 'markdown', 'text': 'Extracted summary'},
                }),
                200,
              );
            }
            return http.Response('{}', 404);
          },
        ).toMockClient();

        final api = ApiAdapter(
          client: mock,
          base: 'https://api.asodya.com/apps/annotations/v1',
        );
        final persistence1 = FileContentJobPersistence(persistFile);

        // Off by default.
        final disabledService = ContentJobService(
          api: api,
          persistence: persistence1,
        );
        await expectLater(
          disabledService.startExplicitJob(
            noteId: 'n1',
            kind: ContentJobKind.extraction,
            selectedFiles: [
              const ContentJobSelectedFile(
                filename: 'a.pdf',
                contentType: 'application/pdf',
                bytes: [1, 2, 3, 4],
              ),
            ],
          ),
          throwsA(isA<StateError>()),
        );

        // Session 1 starts job with selected file only.
        final session1 = ContentJobService(
          api: api,
          persistence: persistence1,
          enabled: true,
        );
        final ref = await session1.startExplicitJob(
          noteId: 'n1',
          kind: ContentJobKind.extraction,
          selectedFiles: [
            const ContentJobSelectedFile(
              filename: 'a.pdf',
              contentType: 'application/pdf',
              bytes: [1, 2, 3, 4],
            ),
          ],
        );
        expect(ref.jobId, 'job_99');
        expect(ref.lastEventSeq, 1);
        expect(await session1.resumeJob('n1'), isNull);

        // Simulate app restart (brand new persistence + service reading same file):
        // resumes job_99 from seq 2 without any /me/files calls.
        final fileCallsBefore = requests
            .where((r) => r.path.contains('/me/files'))
            .length;
        final persistence2 = FileContentJobPersistence(persistFile);
        final session2 = ContentJobService(
          api: api,
          persistence: persistence2,
          enabled: true,
        );
        final draft = await session2.resumeJob('n1');
        final fileCallsAfter = requests
            .where((r) => r.path.contains('/me/files'))
            .length;

        expect(fileCallsAfter, fileCallsBefore);
        expect(draft, isNotNull);
        expect(draft!.jobId, 'job_99');
        expect(draft.extractedText, 'Extracted summary');
        expect(draft.accepted, isFalse);
        expect(
          (await persistence2.loadDraft('n1'))?.extractedText,
          'Extracted summary',
        );
      } finally {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      }
    },
  );

  test(
    'completed job rejects a malformed producer draft without saving it',
    () async {
      final persistence = InMemoryContentJobPersistence();
      await persistence.saveRef(
        const ContentJobRef(
          noteId: 'n1',
          clientJobId: 'client-1',
          jobId: 'job-1',
          lastEventSeq: 1,
          status: 'running',
          uploadedFileIds: [],
        ),
      );
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/events')) {
          return http.Response(
            'id: 2\nevent: completed\ndata: {"status":"completed"}\n\n',
            200,
          );
        }
        if (request.url.path.endsWith('/job-1')) {
          return http.Response(
            jsonEncode({
              'job_id': 'job-1',
              'draft': {'format': 'markdown'},
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      });
      final service = ContentJobService(
        api: ApiAdapter(client: client, base: 'https://api.test'),
        persistence: persistence,
        enabled: true,
      );

      await expectLater(service.resumeJob('n1'), throwsFormatException);
      expect(await persistence.loadDraft('n1'), isNull);
      client.close();
    },
  );
}
