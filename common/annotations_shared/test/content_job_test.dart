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
