import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:annotations_shared/dal/remote/api_adapter.dart';
import 'package:annotations_shared/domain/services/content_job_service.dart';
import 'package:annotations_shared/domain/models/transcription_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/annotations_api_contract.dart';

void main() {
  test(
    'all terminal statuses expose their saved draft and error projection',
    () async {
      for (final status in const [
        'completed',
        'partial',
        'cancelled',
        'failed',
      ]) {
        final persistence = InMemoryContentJobPersistence();
        await persistence.saveRef(
          'owner-a',
          ContentJobRef(
            noteId: 'n1',
            clientJobId: 'client-1',
            jobId: 'job-$status',
            lastEventSeq: 1,
            status: 'running',
            uploadedFileIds: const ['file-1'],
          ),
        );
        final client = MockClient((request) async {
          if (request.url.path.endsWith('/events')) {
            return http.Response(
              'id: 2\nevent: $status\ndata: {"seq":2}\n\n',
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }
          if (request.url.path.endsWith('/job-$status')) {
            return http.Response(
              jsonEncode({
                'job_id': 'job-$status',
                'status': status,
                'event_cursor': 2,
                'draft': {'format': 'markdown', 'text': 'partial-$status'},
                'error': status == 'failed'
                    ? {'code': 'cortex_failed', 'message': 'Processing stopped'}
                    : null,
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
          sessionProvider: _provider(() => true),
        );

        final draft = await service.resumeJob('n1');
        expect(draft?.extractedText, 'partial-$status');
        final ref = await persistence.loadRef('owner-a', 'n1');
        expect(ref?.status, status);
        expect(ref?.lastEventSeq, 2);
        expect(ref?.errorCode, status == 'failed' ? 'cortex_failed' : isNull);
        expect(
          ref?.errorMessage,
          status == 'failed' ? 'Processing stopped' : isNull,
        );
        client.close();
      }
    },
  );

  test('late terminal detail cannot replace a newer explicit job', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'content_job_terminal_projection_race_',
    );
    final persistence = FileContentJobPersistence(
      File('${tempDir.path}/jobs.json'),
    );
    await persistence.saveRef(
      'owner-a',
      const ContentJobRef(
        noteId: 'n1',
        clientJobId: 'client-a',
        jobId: 'job-a',
        status: 'failed',
        uploadedFileIds: ['file-a'],
      ),
    );
    final detailStarted = Completer<void>();
    final oldDetail = Completer<http.Response>();
    final client = MockClient((request) async {
      if (request.method == 'GET' &&
          request.url.path == '/me/content_jobs/job-a') {
        if (!detailStarted.isCompleted) detailStarted.complete();
        return oldDetail.future;
      }
      if (request.method == 'POST' && request.url.path == '/me/files') {
        return http.Response(jsonEncode({'file_id': 'file-b'}), 201);
      }
      if (request.method == 'PUT' &&
          request.url.path == '/me/files/file-b/content') {
        return http.Response('', 200);
      }
      if (request.method == 'POST' && request.url.path == '/me/content_jobs') {
        return http.Response(
          jsonEncode({'job_id': 'job-b', 'status': 'queued'}),
          201,
        );
      }
      return http.Response('unexpected route', 404);
    });
    final service = ContentJobService(
      api: ApiAdapter(client: client, base: 'https://api.test'),
      persistence: persistence,
      enabled: true,
      sessionProvider: _provider(() => true),
    );

    try {
      final staleResume = service.resumeJob('n1');
      await detailStarted.future;
      final replacement = await service.startExplicitJob(
        noteId: 'n1',
        kind: ContentJobKind.extraction,
        selectedFiles: const [
          ContentJobSelectedFile(
            filename: 'replacement.pdf',
            contentType: 'application/pdf',
            bytes: [4, 5, 6],
          ),
        ],
      );
      expect(replacement.jobId, 'job-b');

      oldDetail.complete(
        http.Response(
          jsonEncode({
            'job_id': 'job-a',
            'status': 'failed',
            'draft': {'format': 'markdown', 'text': 'stale result from A'},
            'error': {'code': 'failed', 'message': 'old result'},
          }),
          200,
        ),
      );
      await staleResume;

      final state = await service.loadReviewState('n1');
      expect(state.ref?.jobId, 'job-b');
      expect(state.ref?.status, 'queued');
      expect(state.draft, isNull);
      expect(await persistence.loadDraft('owner-a', 'n1'), isNull);
    } finally {
      client.close();
      await tempDir.delete(recursive: true);
    }
  });

  test('late terminal detail cannot undo an already handled result', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'content_job_handled_projection_race_',
    );
    final persistence = FileContentJobPersistence(
      File('${tempDir.path}/jobs.json'),
    );
    await persistence.saveRef(
      'owner-a',
      const ContentJobRef(
        noteId: 'n1',
        clientJobId: 'client-a',
        jobId: 'job-a',
        status: 'failed',
        uploadedFileIds: ['file-a'],
      ),
    );
    final detailStarted = Completer<void>();
    final oldDetail = Completer<http.Response>();
    final client = MockClient((request) async {
      if (request.method == 'GET' &&
          request.url.path == '/me/content_jobs/job-a') {
        if (!detailStarted.isCompleted) detailStarted.complete();
        return oldDetail.future;
      }
      return http.Response('unexpected route', 404);
    });
    final serviceA = ContentJobService(
      api: ApiAdapter(client: client, base: 'https://api.test'),
      persistence: persistence,
      enabled: true,
      sessionProvider: _provider(() => true),
    );
    final clientB = MockClient((_) async => http.Response('{}', 404));
    final serviceB = ContentJobService(
      api: ApiAdapter(client: clientB, base: 'https://api.test'),
      persistence: persistence,
      enabled: true,
      sessionProvider: _provider(() => true),
    );

    try {
      final staleResume = serviceA.resumeJob('n1');
      await detailStarted.future;
      await persistence.saveDraft(
        'owner-a',
        const ContentJobDraft(
          noteId: 'n1',
          jobId: 'job-a',
          extractedText: 'saved result',
        ),
      );
      await serviceB.markDraftInserted('n1', 'job-a');
      oldDetail.complete(
        http.Response(
          jsonEncode({
            'job_id': 'job-a',
            'status': 'completed',
            'draft': {'format': 'markdown', 'text': 'saved result'},
          }),
          200,
        ),
      );
      await staleResume;

      final state = await serviceB.loadReviewState('n1');
      expect(state.ref?.status, 'result_inserted');
      expect(state.draft?.accepted, isTrue);
      expect(state.draft?.extractedText, 'saved result');
    } finally {
      client.close();
      clientB.close();
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'cancel uses owner mutation route and preserves returned partial draft',
    () async {
      final persistence = InMemoryContentJobPersistence();
      await persistence.saveRef(
        'owner-a',
        const ContentJobRef(
          noteId: 'n1',
          clientJobId: 'client-1',
          jobId: 'job-cancel',
          status: 'running',
          uploadedFileIds: ['file-1'],
        ),
      );
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        if (request.method == 'DELETE' &&
            request.url.path == '/me/content_jobs/job-cancel/execution') {
          expect(request.headers['authorization'], 'Bearer write-a');
          return http.Response(
            jsonEncode({
              'job_id': 'job-cancel',
              'status': 'cancelled',
              'event_cursor': 4,
              'draft': {'format': 'markdown', 'text': 'Saved partial output'},
              'error': null,
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
        sessionProvider: _provider(() => true),
      );

      final draft = await service.cancelJob('n1');
      expect(draft?.extractedText, 'Saved partial output');
      expect(requests.map((request) => request.method), ['DELETE']);
      expect((await persistence.loadRef('owner-a', 'n1'))?.status, 'cancelled');
      expect(
        (await persistence.loadDraft('owner-a', 'n1'))?.extractedText,
        'Saved partial output',
      );
      client.close();
    },
  );

  test(
    'inserted result resumes as handled and discard removes only draft',
    () async {
      final persistence = InMemoryContentJobPersistence();
      const draft = ContentJobDraft(
        noteId: 'n1',
        jobId: 'job-1',
        extractedText: 'Reviewed result',
      );
      await persistence.saveRef(
        'owner-a',
        const ContentJobRef(
          noteId: 'n1',
          clientJobId: 'client-1',
          jobId: 'job-1',
          status: 'completed',
          uploadedFileIds: ['file-1'],
        ),
      );
      await persistence.saveDraft('owner-a', draft);
      final client = MockClient(
        (_) async => throw StateError('unexpected HTTP'),
      );
      final service = ContentJobService(
        api: ApiAdapter(client: client, base: 'https://api.test'),
        persistence: persistence,
        enabled: true,
        sessionProvider: _provider(() => true),
      );

      expect(
        (await service.loadReviewState('n1')).draft?.extractedText,
        'Reviewed result',
      );
      await service.markDraftInserted('n1', 'job-1');
      expect((await service.resumeJob('n1')), isNull);
      expect((await persistence.loadDraft('owner-a', 'n1'))?.accepted, isTrue);

      // A different owner cannot delete the saved result.
      final otherOwner = ContentJobService(
        api: ApiAdapter(client: client, base: 'https://api.test'),
        persistence: persistence,
        enabled: true,
        sessionProvider: () async => TranscriptionSession(
          accountId: 'owner-b',
          readHeaders: const {},
          mutationHeaders: const {},
          isCurrent: () => true,
        ),
      );
      await otherOwner.discardDraft('n1', 'job-1');
      expect(await persistence.loadDraft('owner-a', 'n1'), isNotNull);
      await service.discardDraft('n1', 'job-1');
      expect(await persistence.loadDraft('owner-a', 'n1'), isNull);
      expect(await service.resumeJob('n1'), isNull);
      expect(
        (await persistence.loadRef('owner-a', 'n1'))?.status,
        'result_discarded',
      );
      client.close();
    },
  );

  test(
    'a restarted new job ignores the prior inserted draft and resumes its own result',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'content_job_next_after_insert_',
      );
      final persistenceFile = File('${tempDir.path}/jobs.json');
      final requests = <String>[];
      var uploadNumber = 0;
      var createdJobs = 0;
      final client = MockClient((request) async {
        requests.add('${request.method} ${request.url.path}');
        if (request.method == 'POST' &&
            request.url.path.endsWith('/me/files')) {
          uploadNumber++;
          return http.Response(
            jsonEncode({'file_id': 'file-$uploadNumber'}),
            201,
          );
        }
        if (request.method == 'PUT' &&
            request.url.path.contains('/me/files/')) {
          return http.Response('', 204);
        }
        if (request.method == 'POST' &&
            request.url.path.endsWith('/me/content_jobs')) {
          createdJobs++;
          final jobId = 'job-$createdJobs';
          return http.Response(
            jsonEncode({
              'job_id': jobId,
              'status': 'queued',
              'last_event_seq': 0,
            }),
            201,
          );
        }
        final eventMatch = RegExp(
          r'/me/content_jobs/(job-\d+)/events$',
        ).firstMatch(request.url.path);
        if (request.method == 'GET' && eventMatch != null) {
          return http.Response(
            'id: 1\nevent: completed\ndata: {"status":"completed"}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }
        final jobMatch = RegExp(
          r'/me/content_jobs/(job-\d+)$',
        ).firstMatch(request.url.path);
        if (request.method == 'GET' && jobMatch != null) {
          final jobId = jobMatch.group(1)!;
          return http.Response(
            jsonEncode({
              'job_id': jobId,
              'status': 'completed',
              'draft': {
                'format': 'markdown',
                'text': jobId == 'job-1' ? 'Old inserted result' : 'New result',
              },
            }),
            200,
          );
        }
        return http.Response('unexpected request', 404);
      });

      try {
        final api = ApiAdapter(
          client: client,
          base: 'https://api.asodya.com/apps/annotations/v1',
        );
        final service = ContentJobService(
          api: api,
          persistence: FileContentJobPersistence(persistenceFile),
          enabled: true,
          sessionProvider: _provider(() => true),
        );
        const selectedFile = [
          ContentJobSelectedFile(
            filename: 'selected.pdf',
            contentType: 'application/pdf',
            bytes: [1, 2, 3],
          ),
        ];

        final firstRef = await service.startExplicitJob(
          noteId: 'n1',
          kind: ContentJobKind.extraction,
          selectedFiles: selectedFile,
        );
        expect(firstRef.jobId, 'job-1');
        final firstDraft = await service.resumeJob('n1');
        expect(firstDraft?.extractedText, 'Old inserted result');
        await service.markDraftInserted('n1', 'job-1');

        final secondRef = await service.startExplicitJob(
          noteId: 'n1',
          kind: ContentJobKind.extraction,
          selectedFiles: selectedFile,
        );
        expect(secondRef.jobId, 'job-2');

        // A fresh service/persistence instance models app restart. The old
        // accepted draft remains on disk until job 2 completes, but cannot
        // suppress job 2's event/result fetch or appear as its review draft.
        final restarted = ContentJobService(
          api: api,
          persistence: FileContentJobPersistence(persistenceFile),
          enabled: true,
          sessionProvider: _provider(() => true),
        );
        final beforeResume = await restarted.loadReviewState('n1');
        expect(beforeResume.ref?.jobId, 'job-2');
        expect(beforeResume.draft, isNull);

        final secondDraft = await restarted.resumeJob('n1');
        expect(secondDraft?.jobId, 'job-2');
        expect(secondDraft?.extractedText, 'New result');
        final review = await restarted.loadReviewState('n1');
        expect(review.ref?.jobId, 'job-2');
        expect(review.draft?.jobId, 'job-2');
        expect(review.draft?.extractedText, 'New result');
        expect(
          requests,
          contains('GET /apps/annotations/v1/me/content_jobs/job-2/events'),
        );
        expect(
          requests,
          contains('GET /apps/annotations/v1/me/content_jobs/job-2'),
        );
      } finally {
        client.close();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test(
    'interrupted multi-file upload keeps its client id and prior receipts',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'content_job_partial_upload_',
      );
      final file = File('${tempDir.path}/jobs.json');
      var reservations = 0;
      final originalSelection = const [
        ContentJobSelectedFile(
          filename: 'one.pdf',
          contentType: 'application/pdf',
          bytes: [1],
        ),
        ContentJobSelectedFile(
          filename: 'two.pdf',
          contentType: 'application/pdf',
          bytes: [2],
        ),
      ];
      final firstClient = MockClient((request) async {
        if (request.method == 'POST' && request.url.path == '/me/files') {
          reservations++;
          return http.Response(
            jsonEncode({'file_id': 'file-$reservations'}),
            201,
          );
        }
        if (request.method == 'PUT' &&
            request.url.path.endsWith('/file-1/content')) {
          return http.Response('', 204);
        }
        if (request.method == 'PUT' &&
            request.url.path.endsWith('/file-2/content')) {
          return http.Response('{"error":"upload interrupted"}', 500);
        }
        throw StateError('Unexpected first-attempt request ${request.url}');
      });
      final first = ContentJobService(
        api: ApiAdapter(client: firstClient, base: 'https://api.test'),
        persistence: FileContentJobPersistence(file),
        enabled: true,
        sessionProvider: _provider(() => true),
      );
      await expectLater(
        first.startExplicitJob(
          noteId: 'n1',
          kind: ContentJobKind.extraction,
          selectedFiles: originalSelection,
        ),
        throwsA(isA<ApiError>()),
      );
      final interrupted = await FileContentJobPersistence(
        file,
      ).loadRef('owner-a', 'n1');
      expect(interrupted?.uploadedFileIds, ['file-1']);
      expect(interrupted?.selectedFiles, hasLength(2));
      expect(interrupted?.kind, ContentJobKind.extraction);
      final clientJobId = interrupted!.clientJobId;
      firstClient.close();

      var rejectedRequests = 0;
      final rejectClient = MockClient((request) async {
        rejectedRequests++;
        return http.Response('{}', 500);
      });
      final rejectService = ContentJobService(
        api: ApiAdapter(client: rejectClient, base: 'https://api.test'),
        persistence: FileContentJobPersistence(file),
        enabled: true,
        sessionProvider: _provider(() => true),
      );
      await expectLater(
        rejectService.startExplicitJob(
          noteId: 'n1',
          kind: ContentJobKind.extraction,
          selectedFiles: const [
            ContentJobSelectedFile(
              filename: 'different.pdf',
              contentType: 'application/pdf',
              bytes: [9],
            ),
          ],
        ),
        throwsA(isA<StateError>()),
      );
      expect(rejectedRequests, 0);
      rejectClient.close();

      final resumedRequests = <http.Request>[];
      final retryClient = MockClient((request) async {
        resumedRequests.add(request);
        if (request.method == 'POST' && request.url.path == '/me/files') {
          reservations++;
          return http.Response(
            jsonEncode({'file_id': 'file-$reservations'}),
            201,
          );
        }
        if (request.method == 'PUT' &&
            request.url.path.endsWith('/file-3/content')) {
          return http.Response('', 204);
        }
        if (request.method == 'POST' &&
            request.url.path == '/me/content_jobs') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['client_job_id'], clientJobId);
          expect(body['kind'], 'extraction');
          expect(body['file_ids'], ['file-1', 'file-3']);
          return http.Response(
            jsonEncode({'job_id': 'job-1', 'status': 'queued'}),
            201,
          );
        }
        throw StateError('Unexpected retry request ${request.url}');
      });
      final restarted = ContentJobService(
        api: ApiAdapter(client: retryClient, base: 'https://api.test'),
        persistence: FileContentJobPersistence(file),
        enabled: true,
        sessionProvider: _provider(() => true),
      );
      final result = await restarted.startExplicitJob(
        noteId: 'n1',
        kind: ContentJobKind.extraction,
        selectedFiles: originalSelection,
      );
      expect(result.jobId, 'job-1');
      expect(
        resumedRequests.where((request) => request.method == 'PUT'),
        hasLength(1),
      );
      expect(reservations, 3);
      retryClient.close();
      await tempDir.delete(recursive: true);
    },
  );

  test(
    'a restarted new job ignores the prior inserted draft and resumes its own result',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'content_job_next_after_insert_',
      );
      final persistenceFile = File('${tempDir.path}/jobs.json');
      final requests = <String>[];
      var uploadNumber = 0;
      var createdJobs = 0;
      final client = MockClient((request) async {
        requests.add('${request.method} ${request.url.path}');
        if (request.method == 'POST' &&
            request.url.path.endsWith('/me/files')) {
          uploadNumber++;
          return http.Response(
            jsonEncode({'file_id': 'file-$uploadNumber'}),
            201,
          );
        }
        if (request.method == 'PUT' &&
            request.url.path.contains('/me/files/')) {
          return http.Response('', 204);
        }
        if (request.method == 'POST' &&
            request.url.path.endsWith('/me/content_jobs')) {
          createdJobs++;
          final jobId = 'job-$createdJobs';
          return http.Response(
            jsonEncode({
              'job_id': jobId,
              'status': 'queued',
              'last_event_seq': 0,
            }),
            201,
          );
        }
        final eventMatch = RegExp(
          r'/me/content_jobs/(job-\d+)/events$',
        ).firstMatch(request.url.path);
        if (request.method == 'GET' && eventMatch != null) {
          return http.Response(
            'id: 1\nevent: completed\ndata: {"status":"completed"}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }
        final jobMatch = RegExp(
          r'/me/content_jobs/(job-\d+)$',
        ).firstMatch(request.url.path);
        if (request.method == 'GET' && jobMatch != null) {
          final jobId = jobMatch.group(1)!;
          return http.Response(
            jsonEncode({
              'job_id': jobId,
              'status': 'completed',
              'draft': {
                'format': 'markdown',
                'text': jobId == 'job-1' ? 'Old inserted result' : 'New result',
              },
            }),
            200,
          );
        }
        return http.Response('unexpected request', 404);
      });

      try {
        final api = ApiAdapter(
          client: client,
          base: 'https://api.asodya.com/apps/annotations/v1',
        );
        final service = ContentJobService(
          api: api,
          persistence: FileContentJobPersistence(persistenceFile),
          enabled: true,
          sessionProvider: _provider(() => true),
        );
        const selectedFile = [
          ContentJobSelectedFile(
            filename: 'selected.pdf',
            contentType: 'application/pdf',
            bytes: [1, 2, 3],
          ),
        ];

        final firstRef = await service.startExplicitJob(
          noteId: 'n1',
          kind: ContentJobKind.extraction,
          selectedFiles: selectedFile,
        );
        expect(firstRef.jobId, 'job-1');
        final firstDraft = await service.resumeJob('n1');
        expect(firstDraft?.extractedText, 'Old inserted result');
        await service.markDraftInserted('n1', 'job-1');

        final secondRef = await service.startExplicitJob(
          noteId: 'n1',
          kind: ContentJobKind.extraction,
          selectedFiles: selectedFile,
        );
        expect(secondRef.jobId, 'job-2');

        // A fresh service/persistence instance models app restart. The old
        // accepted draft remains on disk until job 2 completes, but cannot
        // suppress job 2's event/result fetch or appear as its review draft.
        final restarted = ContentJobService(
          api: api,
          persistence: FileContentJobPersistence(persistenceFile),
          enabled: true,
          sessionProvider: _provider(() => true),
        );
        final beforeResume = await restarted.loadReviewState('n1');
        expect(beforeResume.ref?.jobId, 'job-2');
        expect(beforeResume.draft, isNull);

        final secondDraft = await restarted.resumeJob('n1');
        expect(secondDraft?.jobId, 'job-2');
        expect(secondDraft?.extractedText, 'New result');
        final review = await restarted.loadReviewState('n1');
        expect(review.ref?.jobId, 'job-2');
        expect(review.draft?.jobId, 'job-2');
        expect(review.draft?.extractedText, 'New result');
        expect(
          requests,
          contains('GET /apps/annotations/v1/me/content_jobs/job-2/events'),
        );
        expect(
          requests,
          contains('GET /apps/annotations/v1/me/content_jobs/job-2'),
        );
      } finally {
        client.close();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test(
    'persistence isolates identical note ids and ignores unowned legacy data',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'content_job_owner_',
      );
      final file = File('${tempDir.path}/jobs.json');
      try {
        file.writeAsStringSync(
          jsonEncode({
            'refs': {
              'same-note': {
                'note_id': 'same-note',
                'client_job_id': 'legacy',
                'status': 'running',
                'uploaded_file_ids': [],
              },
            },
            'drafts': {
              'same-note': {
                'note_id': 'same-note',
                'job_id': 'legacy',
                'extracted_text': 'legacy private text',
                'accepted': false,
              },
            },
          }),
        );
        final persistence = FileContentJobPersistence(file);
        expect(await persistence.loadRef('owner-a', 'same-note'), isNull);
        expect(await persistence.loadDraft('owner-b', 'same-note'), isNull);

        await persistence.saveRef(
          'owner-a',
          const ContentJobRef(
            noteId: 'same-note',
            clientJobId: 'client-a',
            status: 'running',
            uploadedFileIds: [],
          ),
        );
        await persistence.saveDraft(
          'owner-a',
          const ContentJobDraft(
            noteId: 'same-note',
            jobId: 'job-a',
            extractedText: 'owner A draft',
          ),
        );
        expect(
          (await persistence.loadRef('owner-a', 'same-note'))?.clientJobId,
          'client-a',
        );
        expect(await persistence.loadRef('owner-b', 'same-note'), isNull);
        expect(
          (await persistence.loadDraft('owner-a', 'same-note'))?.extractedText,
          'owner A draft',
        );
        expect(await persistence.loadDraft('owner-b', 'same-note'), isNull);

        final stored =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        expect(stored['refs'], contains('same-note'));
        expect(stored['drafts'], contains('same-note'));
        expect(file.readAsStringSync(), isNot(contains('Bearer')));
        expect(file.readAsStringSync(), isNot(contains('csrf-a')));
      } finally {
        await tempDir.delete(recursive: true);
      }
    },
  );

  test(
    'account change during SSE stops progress and owner draft fetch',
    () async {
      final persistence = InMemoryContentJobPersistence();
      await persistence.saveRef(
        'owner-a',
        const ContentJobRef(
          noteId: 'same-note',
          clientJobId: 'client-a',
          jobId: 'job-a',
          lastEventSeq: 1,
          status: 'running',
          uploadedFileIds: [],
        ),
      );
      final client = _OwnerSwitchClient();
      var current = true;
      final service = ContentJobService(
        api: ApiAdapter(client: client, base: 'https://api.test'),
        persistence: persistence,
        enabled: true,
        sessionProvider: _provider(() => current),
      );
      final progress = <(int, String)>[];
      final pending = service.resumeJob(
        'same-note',
        onProgress: (sequence, status) => progress.add((sequence, status)),
      );
      await client.eventRequestStarted.future;
      expect(client.eventRequest!.headers['authorization'], 'Bearer read-a');
      expect(client.eventRequest!.headers.containsKey('x-csrf-token'), isFalse);
      current = false;
      client.events.add(
        utf8.encode(
          'id: 2\nevent: completed\ndata: {"status":"completed"}\n\n',
        ),
      );
      await expectLater(
        pending,
        throwsA(isA<TranscriptionSessionChangedException>()),
      );
      expect(progress, isEmpty);
      expect(client.draftReads, 0);
      expect(
        (await persistence.loadRef('owner-a', 'same-note'))?.lastEventSeq,
        1,
      );
      expect(await persistence.loadDraft('owner-a', 'same-note'), isNull);
      expect(await persistence.loadRef('owner-b', 'same-note'), isNull);
      client.close();
    },
  );

  test(
    'account change during upload blocks further upload and job creation',
    () async {
      final persistence = InMemoryContentJobPersistence();
      final reservationStarted = Completer<void>();
      final reservation = Completer<http.Response>();
      var putCount = 0;
      var createCount = 0;
      final client = MockClient((request) async {
        if (request.method == 'POST' &&
            request.url.path.endsWith('/me/files')) {
          reservationStarted.complete();
          return reservation.future;
        }
        if (request.method == 'PUT') putCount++;
        if (request.method == 'POST' &&
            request.url.path.endsWith('/me/content_jobs')) {
          createCount++;
        }
        return http.Response('{}', 200);
      });
      var current = true;
      final service = ContentJobService(
        api: ApiAdapter(client: client, base: 'https://api.test'),
        persistence: persistence,
        enabled: true,
        sessionProvider: _provider(() => current),
      );
      final pending = service.startExplicitJob(
        noteId: 'same-note',
        kind: ContentJobKind.extraction,
        selectedFiles: const [
          ContentJobSelectedFile(
            filename: 'selected.pdf',
            contentType: 'application/pdf',
            bytes: [1, 2, 3],
          ),
        ],
      );
      await reservationStarted.future;
      current = false;
      reservation.complete(
        http.Response(jsonEncode({'file_id': 'file-a'}), 201),
      );
      await expectLater(
        pending,
        throwsA(isA<TranscriptionSessionChangedException>()),
      );
      expect(putCount, 0);
      expect(createCount, 0);
      expect(await persistence.loadRef('owner-b', 'same-note'), isNull);
      expect(
        (await persistence.loadRef('owner-a', 'same-note'))?.status,
        'reserving',
      );
      client.close();
    },
  );

  test(
    'cancels an SSE body when response headers arrive after account change',
    () async {
      final persistence = InMemoryContentJobPersistence();
      await persistence.saveRef(
        'owner-a',
        const ContentJobRef(
          noteId: 'same-note',
          clientJobId: 'client-a',
          jobId: 'job-a',
          lastEventSeq: 1,
          status: 'running',
          uploadedFileIds: [],
        ),
      );
      final client = _HeaderGateClient();
      var current = true;
      final service = ContentJobService(
        api: ApiAdapter(client: client, base: 'https://api.test'),
        persistence: persistence,
        enabled: true,
        sessionProvider: _provider(() => current),
      );
      final progress = <(int, String)>[];
      final pending = service.resumeJob(
        'same-note',
        onProgress: (sequence, status) => progress.add((sequence, status)),
      );
      await client.requestStarted.future;
      current = false;
      client.response.complete(
        http.StreamedResponse(
          client.body.stream,
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
      );
      await expectLater(
        pending,
        throwsA(isA<TranscriptionSessionChangedException>()),
      );
      expect(client.cancelCount, 1);
      expect(progress, isEmpty);
      expect(client.draftReads, 0);
      expect(client.closeCount, 0);
      expect(await persistence.loadDraft('owner-a', 'same-note'), isNull);
      await client.body.close();
    },
  );

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
                  'event_cursor': 3,
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
          sessionProvider: _provider(() => true),
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
          sessionProvider: _provider(() => true),
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
          (await persistence2.loadDraft('owner-a', 'n1'))?.extractedText,
          'Extracted summary',
        );
        for (final request in requests.where(
          (request) => request.method == 'POST' || request.method == 'PUT',
        )) {
          expect(request.headers['authorization'], 'Bearer write-a');
          expect(request.headers['x-csrf-token'], 'csrf-a');
        }
        for (final request in requests.where(
          (request) => request.method == 'GET',
        )) {
          expect(request.headers['authorization'], 'Bearer read-a');
          expect(request.headers.containsKey('x-csrf-token'), isFalse);
        }
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
        'owner-a',
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
              'status': 'completed',
              'event_cursor': 2,
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
        sessionProvider: _provider(() => true),
      );

      await expectLater(service.resumeJob('n1'), throwsFormatException);
      expect(await persistence.loadDraft('owner-a', 'n1'), isNull);
      client.close();
    },
  );

  test(
    'resume reports live progress and persists each cursor before EOF',
    () async {
      final persistence = InMemoryContentJobPersistence();
      await persistence.saveRef(
        'owner-a',
        const ContentJobRef(
          noteId: 'n1',
          clientJobId: 'client-1',
          jobId: 'job-1',
          lastEventSeq: 1,
          status: 'running',
          uploadedFileIds: [],
        ),
      );
      final client = _GatedContentJobClient();
      final service = ContentJobService(
        api: ApiAdapter(client: client, base: 'https://api.test'),
        persistence: persistence,
        enabled: true,
        sessionProvider: _provider(() => true),
      );
      final progress = <(int, String)>[];
      final sawProgress = Completer<void>();
      var completed = false;
      final waiting = service
          .resumeJob(
            'n1',
            onProgress: (sequence, status) {
              progress.add((sequence, status));
              if (status == 'running' && !sawProgress.isCompleted) {
                sawProgress.complete();
              }
            },
          )
          .then((value) {
            completed = true;
            return value;
          });
      await client.eventRequestStarted.future;
      expect(client.eventRequest?.url.queryParameters['after'], '1');
      expect(client.eventRequest?.headers['last-event-id'], '1');

      final progressPrefix = utf8.encode(
        'id: 2\r\nevent: progress\r\ndata: {"status":"running","label":"',
      );
      final thai = utf8.encode('กิ');
      client.events.add([...progressPrefix, thai.first]);
      client.events.add([...thai.skip(1), ...utf8.encode('"}\r')]);
      client.events.add(utf8.encode('\n\r\n'));
      await sawProgress.future.timeout(const Duration(seconds: 2));
      expect(progress, [(2, 'running')]);
      expect((await persistence.loadRef('owner-a', 'n1'))?.lastEventSeq, 2);
      expect(completed, isFalse);

      client.events.add(
        utf8.encode(
          'id: 3\nevent: completed\ndata: {"status":"completed"}\n\n',
        ),
      );
      await client.events.close();
      final draft = await waiting;
      expect(progress, [(2, 'running'), (3, 'completed')]);
      expect(draft?.extractedText, 'Summary');
      expect((await persistence.loadRef('owner-a', 'n1'))?.lastEventSeq, 3);
      expect(client.draftReads, 1);
      client.close();
    },
  );
}

TranscriptionSessionProvider _provider(bool Function() current) => () async {
  if (!current()) return null;
  return TranscriptionSession(
    accountId: 'owner-a',
    readHeaders: const {'authorization': 'Bearer read-a'},
    mutationHeaders: const {
      'authorization': 'Bearer write-a',
      'x-csrf-token': 'csrf-a',
    },
    isCurrent: current,
  );
};

final class _OwnerSwitchClient extends http.BaseClient {
  final eventRequestStarted = Completer<void>();
  final StreamController<List<int>> events = StreamController<List<int>>();
  http.BaseRequest? eventRequest;
  int draftReads = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path.endsWith('/events')) {
      eventRequest = request;
      eventRequestStarted.complete();
      return http.StreamedResponse(
        events.stream,
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    }
    if (request.url.path.endsWith('/job-a')) draftReads++;
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode('{}')),
      200,
    );
  }

  @override
  void close() {
    if (!events.isClosed) events.close();
  }
}

final class _HeaderGateClient extends http.BaseClient {
  final requestStarted = Completer<void>();
  final response = Completer<http.StreamedResponse>();
  var cancelCount = 0;
  var closeCount = 0;
  var draftReads = 0;
  late final StreamController<List<int>> body = StreamController<List<int>>(
    onCancel: () => cancelCount++,
  );

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.url.path.endsWith('/events')) {
      requestStarted.complete();
      return response.future;
    }
    if (request.url.path.endsWith('/job-a')) draftReads++;
    return Future.value(
      http.StreamedResponse(Stream<List<int>>.value(utf8.encode('{}')), 200),
    );
  }

  @override
  void close() => closeCount++;
}

final class _GatedContentJobClient extends http.BaseClient {
  final eventRequestStarted = Completer<void>();
  final StreamController<List<int>> events = StreamController<List<int>>();
  http.BaseRequest? eventRequest;
  int draftReads = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path.endsWith('/events')) {
      eventRequest = request;
      eventRequestStarted.complete();
      return http.StreamedResponse(
        events.stream,
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    }
    if (request.url.path.endsWith('/job-1')) {
      draftReads++;
      return http.StreamedResponse(
        Stream<List<int>>.value(
          utf8.encode(
            jsonEncode({
              'job_id': 'job-1',
              'status': 'completed',
              'event_cursor': 3,
              'draft': {'format': 'markdown', 'text': 'Summary'},
            }),
          ),
        ),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode('{}')),
      404,
    );
  }

  @override
  void close() {
    if (!events.isClosed) events.close();
  }
}
