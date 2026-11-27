import 'dart:convert';

import 'package:annotations_shared/dal/remote/api_adapter.dart';
import 'package:annotations_shared/domain/services/content_job_service.dart';
import 'package:annotations_shared/domain/services/preferences.dart';
import 'package:annotations_shared/domain/models/transcription_session.dart';
import 'package:annotations_shared/presentation/frontend/components/scope.dart';
import 'package:annotations_shared/presentation/frontend/widgets/workspace/content_job_review_page.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures.dart';

void main() {
  testWidgets('selected file starts, resumes and inserts one saved result', (
    tester,
  ) async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (request.method == 'POST' && request.url.path == '/me/files') {
        return http.Response(jsonEncode({'file_id': 'file-1'}), 201);
      }
      if (request.method == 'PUT' &&
          request.url.path == '/me/files/file-1/content') {
        return http.Response('', 204);
      }
      if (request.method == 'POST' && request.url.path == '/me/content_jobs') {
        return http.Response(
          jsonEncode({
            'job_id': 'job-1',
            'last_event_seq': 0,
            'status': 'queued',
          }),
          202,
        );
      }
      if (request.method == 'GET' &&
          request.url.path == '/me/content_jobs/job-1/events') {
        return http.Response.bytes(
          utf8.encode(
            'id: 1\nevent: completed\ndata: {"status":"completed"}\n\n',
          ),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }
      if (request.method == 'GET' &&
          request.url.path == '/me/content_jobs/job-1') {
        return http.Response(
          jsonEncode({
            'job_id': 'job-1',
            'draft': {'format': 'markdown', 'text': 'Selected-file result'},
          }),
          200,
        );
      }
      fail('Unexpected request: ${request.method} ${request.url}');
    });
    final persistence = InMemoryContentJobPersistence();
    final service = ContentJobService(
      api: ApiAdapter(client: client, base: 'https://api.test'),
      persistence: persistence,
      enabled: true,
      sessionProvider: () async => TranscriptionSession(
        accountId: 'owner-a',
        readHeaders: const {'authorization': 'Bearer read'},
        mutationHeaders: const {'authorization': 'Bearer write'},
        isCurrent: () => true,
      ),
    );
    final ownerRevision = ValueNotifier(1);
    addTearDown(ownerRevision.dispose);
    var inserted = 0;
    var pickerCalls = 0;

    await tester.pumpWidget(
      AppScope(
        preferences: Preferences(),
        service: fixtureService(),
        child: MaterialApp(
          home: ContentJobReviewPage(
            noteId: 'note-1',
            service: service,
            isOwnerScopeCurrent: () => ownerRevision.value == 1,
            ownerScopeRevision: ownerRevision,
            expectedOwnerScopeRevision: 1,
            pickFiles: () async {
              pickerCalls++;
              return [XFile('selected.pdf')];
            },
            readFileForTesting: (_) async => [1, 2, 3],
            insertText: (jobId, text) async {
              expect(jobId, 'job-1');
              expect(text, 'Selected-file result');
              inserted++;
              return true;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('content-job-result')), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('content-job-start')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const Key('content-job-select-files')));
    await tester.pumpAndSettle();
    expect(pickerCalls, 1);
    final pickerError = find.byKey(const Key('content-job-error'));
    expect(
      find.text('selected.pdf'),
      findsOneWidget,
      reason: pickerError.evaluate().isEmpty
          ? 'No picker error was rendered.'
          : tester.widget<Text>(pickerError).data,
    );
    await tester.tap(find.byKey(const Key('content-job-start')));
    await tester.pumpAndSettle();

    expect(find.text('Selected-file result'), findsOneWidget);
    expect(
      requests.where((r) => r.method == 'POST' && r.url.path == '/me/files'),
      hasLength(1),
    );
    final upload = requests.singleWhere(
      (r) => r.method == 'PUT' && r.url.path.endsWith('/content'),
    );
    expect(upload.bodyBytes, [1, 2, 3]);

    await tester.tap(find.byKey(const Key('content-job-insert')));
    await tester.pumpAndSettle();
    expect(inserted, 1);
    expect(
      (await persistence.loadDraft('owner-a', 'note-1'))?.accepted,
      isTrue,
    );
    expect(
      find.text('This result was already inserted into the note.'),
      findsOneWidget,
    );
    client.close();
  });

  testWidgets('owner change clears private draft without inserting it', (
    tester,
  ) async {
    final persistence = InMemoryContentJobPersistence();
    await persistence.saveRef(
      'owner-a',
      const ContentJobRef(
        noteId: 'note-1',
        clientJobId: 'client-1',
        jobId: 'job-1',
        status: 'completed',
        uploadedFileIds: ['file-1'],
      ),
    );
    await persistence.saveDraft(
      'owner-a',
      const ContentJobDraft(
        noteId: 'note-1',
        jobId: 'job-1',
        extractedText: 'Private result',
      ),
    );
    final client = MockClient((request) async {
      fail('Discard must not make a server request: ${request.url}');
    });
    final service = ContentJobService(
      api: ApiAdapter(client: client, base: 'https://api.test'),
      persistence: persistence,
      enabled: true,
      sessionProvider: () async => TranscriptionSession(
        accountId: 'owner-a',
        readHeaders: const {},
        mutationHeaders: const {},
        isCurrent: () => true,
      ),
    );
    final ownerRevision = ValueNotifier(1);
    addTearDown(ownerRevision.dispose);
    var insertCalls = 0;
    await tester.pumpWidget(
      AppScope(
        preferences: Preferences(),
        service: fixtureService(),
        child: MaterialApp(
          home: ContentJobReviewPage(
            noteId: 'note-1',
            service: service,
            isOwnerScopeCurrent: () => ownerRevision.value == 1,
            ownerScopeRevision: ownerRevision,
            expectedOwnerScopeRevision: 1,
            insertText: (_, _) async {
              insertCalls++;
              return true;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Private result'), findsOneWidget);
    ownerRevision.value = 2;
    await tester.pumpAndSettle();
    expect(find.text('Private result'), findsNothing);
    expect(insertCalls, 0);
    client.close();
  });

  testWidgets('discard removes local result without another API request', (
    tester,
  ) async {
    final persistence = InMemoryContentJobPersistence();
    await persistence.saveRef(
      'owner-a',
      const ContentJobRef(
        noteId: 'note-1',
        clientJobId: 'client-1',
        jobId: 'job-1',
        status: 'completed',
        uploadedFileIds: ['file-1'],
      ),
    );
    await persistence.saveDraft(
      'owner-a',
      const ContentJobDraft(
        noteId: 'note-1',
        jobId: 'job-1',
        extractedText: 'Private result',
      ),
    );
    final client = MockClient((request) async {
      fail('Discard must not call the server: ${request.url}');
    });
    final service = ContentJobService(
      api: ApiAdapter(client: client, base: 'https://api.test'),
      persistence: persistence,
      enabled: true,
      sessionProvider: () async => TranscriptionSession(
        accountId: 'owner-a',
        readHeaders: const {},
        mutationHeaders: const {},
        isCurrent: () => true,
      ),
    );
    final ownerRevision = ValueNotifier(1);
    addTearDown(ownerRevision.dispose);
    await tester.pumpWidget(
      AppScope(
        preferences: Preferences(),
        service: fixtureService(),
        child: MaterialApp(
          home: ContentJobReviewPage(
            noteId: 'note-1',
            service: service,
            isOwnerScopeCurrent: () => ownerRevision.value == 1,
            ownerScopeRevision: ownerRevision,
            expectedOwnerScopeRevision: 1,
            insertText: (_, _) async => fail('Discard must not insert.'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('content-job-discard')));
    await tester.pumpAndSettle();
    expect(find.text('Private result'), findsNothing);
    expect(
      find.text('The result was discarded. You can start a new job.'),
      findsOneWidget,
    );
    expect(await persistence.loadDraft('owner-a', 'note-1'), isNull);
    expect(
      (await persistence.loadRef('owner-a', 'note-1'))?.status,
      'result_discarded',
    );
    client.close();
  });
}
