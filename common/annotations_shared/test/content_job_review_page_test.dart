import 'dart:async';
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
            'status': 'completed',
            'event_cursor': 1,
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
            fileLengthForTesting: (_) async => 3,
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

  testWidgets('cancel remains available during resume and shows partial output', (
    tester,
  ) async {
    final persistence = InMemoryContentJobPersistence();
    await persistence.saveRef(
      'owner-a',
      const ContentJobRef(
        noteId: 'note-1',
        clientJobId: 'client-1',
        jobId: 'job-1',
        status: 'running',
        uploadedFileIds: ['file-1'],
      ),
    );
    final client = _CancellableContentJobClient();
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
            insertText: (_, _) async => true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('content-job-resume')));
    await client.eventStarted.future.timeout(const Duration(seconds: 2));
    await tester.pump();
    expect(find.byKey(const Key('content-job-cancel')), findsOneWidget);
    await tester.tap(find.byKey(const Key('content-job-cancel')));
    await client.cancelRequested.future.timeout(const Duration(seconds: 2));
    for (
      var attempt = 0;
      attempt < 20 && find.text('Partial reviewed text').evaluate().isEmpty;
      attempt++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump();

    final pageError = find.byKey(const Key('content-job-error'));
    expect(
      find.text('Partial reviewed text'),
      findsOneWidget,
      reason: pageError.evaluate().isEmpty
          ? 'Cancellation request arrived=${client.cancelRequested.isCompleted}; '
                'saved draft=${(await persistence.loadDraft('owner-a', 'note-1'))?.extractedText}'
          : tester.widget<Text>(pageError).data,
    );
    expect(
      (await persistence.loadRef('owner-a', 'note-1'))?.status,
      'cancelled',
    );
    await client.events.close();
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

  testWidgets(
    'file limits are checked before reading and a rejected selection preserves the previous one',
    (tester) async {
      final client = MockClient((request) async {
        fail('Selecting files must not start network requests: ${request.url}');
      });
      final service = ContentJobService(
        api: ApiAdapter(client: client, base: 'https://api.test'),
        persistence: InMemoryContentJobPersistence(),
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
      var selectedFiles = <XFile>[XFile('selected.pdf')];
      var byteReads = 0;
      var metadataReads = 0;
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
              insertText: (_, _) async => false,
              pickFiles: () async => selectedFiles,
              fileLengthForTesting: (file) async {
                metadataReads++;
                return switch (file.name) {
                  'large.pdf' => ContentJobService.maxFileBytes + 1,
                  'exact.pdf' => ContentJobService.maxFileBytes,
                  _ => 3,
                };
              },
              readFileForTesting: (_) async {
                byteReads++;
                return [1, 2, 3];
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('content-job-select-files')));
      await tester.pumpAndSettle();
      expect(find.text('selected.pdf'), findsOneWidget);

      selectedFiles = [XFile('large.pdf')];
      await tester.tap(find.byKey(const Key('content-job-select-files')));
      await tester.pumpAndSettle();
      expect(find.text('selected.pdf'), findsOneWidget);
      expect(find.text('large.pdf'), findsNothing);
      expect(
        find.text('Each selected file must be 100 MB or smaller.'),
        findsOneWidget,
      );
      expect(byteReads, 0);

      selectedFiles = [XFile('exact.pdf')];
      await tester.tap(find.byKey(const Key('content-job-select-files')));
      await tester.pumpAndSettle();
      expect(find.text('exact.pdf'), findsOneWidget);
      expect(find.text('100000000 bytes'), findsOneWidget);
      expect(byteReads, 0);

      selectedFiles = [for (var i = 0; i < 21; i++) XFile('file-$i.pdf')];
      final metadataBeforeTooMany = metadataReads;
      await tester.tap(find.byKey(const Key('content-job-select-files')));
      await tester.pumpAndSettle();
      expect(find.text('exact.pdf'), findsOneWidget);
      expect(find.text('Choose no more than 20 files.'), findsOneWidget);
      expect(metadataReads, metadataBeforeTooMany);
      expect(byteReads, 0);

      selectedFiles = [XFile('${List.filled(256, 'a').join()}.pdf')];
      await tester.tap(find.byKey(const Key('content-job-select-files')));
      await tester.pumpAndSettle();
      expect(find.text('exact.pdf'), findsOneWidget);
      expect(find.text('A selected file name is too long.'), findsOneWidget);
      expect(metadataReads, metadataBeforeTooMany);
      expect(byteReads, 0);
      client.close();
    },
  );

  testWidgets('owner change during file metadata check never reads bytes', (
    tester,
  ) async {
    final client = MockClient((request) async {
      fail('File selection must not call the API: ${request.url}');
    });
    final service = ContentJobService(
      api: ApiAdapter(client: client, base: 'https://api.test'),
      persistence: InMemoryContentJobPersistence(),
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
    final lengthStarted = Completer<void>();
    final fileLength = Completer<int>();
    var byteReads = 0;
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
            insertText: (_, _) async => false,
            pickFiles: () async => [XFile('waiting.pdf')],
            fileLengthForTesting: (_) {
              if (!lengthStarted.isCompleted) lengthStarted.complete();
              return fileLength.future;
            },
            readFileForTesting: (_) async {
              byteReads++;
              return [1, 2, 3];
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('content-job-select-files')));
    await lengthStarted.future;
    ownerRevision.value++;
    await tester.pump();
    fileLength.complete(3);
    await tester.pumpAndSettle();

    expect(byteReads, 0);
    expect(find.text('waiting.pdf'), findsNothing);
    client.close();
  });
}

final class _CancellableContentJobClient extends http.BaseClient {
  final events = StreamController<List<int>>();
  final eventStarted = Completer<void>();
  final cancelRequested = Completer<void>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path.endsWith('/events')) {
      if (!eventStarted.isCompleted) eventStarted.complete();
      return http.StreamedResponse(
        events.stream,
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    }
    if (request.method == 'DELETE' && request.url.path.endsWith('/execution')) {
      if (!cancelRequested.isCompleted) cancelRequested.complete();
      return http.StreamedResponse(
        Stream<List<int>>.value(
          utf8.encode(
            jsonEncode({
              'job_id': 'job-1',
              'status': 'cancelled',
              'event_cursor': 1,
              'draft': {'format': 'markdown', 'text': 'Partial reviewed text'},
              'error': null,
            }),
          ),
        ),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    throw StateError('Unexpected request ${request.method} ${request.url}');
  }

  @override
  void close() {
    if (!events.isClosed) events.close();
  }
}
