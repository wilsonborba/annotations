import 'dart:convert';

import 'package:annotations_shared/dal/remote/api_adapter.dart';
import 'package:annotations_shared/domain/services/content_job_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('disabled by default; restart during job resumes same job without new upload', () async {
    final persistence = InMemoryContentJobPersistence();
    final requests = <(String, String, Map<String, String>)>[];
    var pollCount = 0;

    final mock = MockClient((req) async {
      requests.add((req.method, req.url.path, Map<String, String>.from(req.url.queryParameters)));
      if (req.method == 'POST' && req.url.path.endsWith('/me/files')) {
        return http.Response(jsonEncode({'file_id': 'f_sel_1'}), 201);
      }
      if (req.method == 'POST' && req.url.path.endsWith('/me/content_jobs')) {
        return http.Response(jsonEncode({'job_id': 'job_99', 'status': 'running', 'cursor': 'cur_1'}), 201);
      }
      if (req.method == 'GET' && req.url.path.endsWith('/me/content_jobs/job_99/events')) {
        pollCount++;
        return http.Response(
          jsonEncode({
            'status': pollCount >= 2 ? 'completed' : 'running',
            'next_cursor': 'cur_${pollCount + 1}',
          }),
          200,
        );
      }
      if (req.method == 'GET' && req.url.path.endsWith('/me/content_jobs/job_99')) {
        return http.Response(jsonEncode({'job_id': 'job_99', 'output_text': 'Extracted summary'}), 200);
      }
      return http.Response('{}', 404);
    });

    final api = ApiAdapter(client: mock, base: 'https://api.asodya.com/apps/annotations/v1');

    // Off by default.
    final disabledService = ContentJobService(api: api, persistence: persistence);
    await expectLater(
      disabledService.startExplicitJob(noteId: 'n1', kind: 'extract', selectedFiles: [{'name': 'a.pdf'}]),
      throwsA(isA<StateError>()),
    );

    // Session 1 starts job with selected file only.
    final session1 = ContentJobService(api: api, persistence: persistence, enabled: true);
    final ref = await session1.startExplicitJob(
      noteId: 'n1',
      kind: 'extract',
      selectedFiles: [{'name': 'a.pdf', 'bytes': 12}],
    );
    expect(ref.jobId, 'job_99');
    expect(await session1.resumeJob('n1'), isNull);

    // Simulate app restart (new ContentJobService sharing persistence): resumes same job_99 without POST /me/files.
    final filesPostsBefore = requests.where((r) => r.$1 == 'POST' && r.$2.endsWith('/me/files')).length;
    final session2 = ContentJobService(api: api, persistence: persistence, enabled: true);
    final draft = await session2.resumeJob('n1');
    final filesPostsAfter = requests.where((r) => r.$1 == 'POST' && r.$2.endsWith('/me/files')).length;

    expect(filesPostsAfter, filesPostsBefore);
    expect(draft, isNotNull);
    expect(draft!.jobId, 'job_99');
    expect(draft.extractedText, 'Extracted summary');
    expect(draft.accepted, isFalse);
  });
}
