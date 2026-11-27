import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:annotations_shared/dal/remote/api_adapter.dart';
import 'package:annotations_shared/dal/remote/transcription_api_adapter.dart';
import 'package:annotations_shared/domain/models/transcription_session.dart';
import 'package:annotations_shared/domain/services/transcription_run_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('annotations-feedback-');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'feedback survives restart and retries with the same event and body',
    () async {
      final file = File('${directory.path}/feedback.json');
      final attempts = <Map<String, dynamic>>[];
      final firstClient = MockClient((request) async {
        attempts.add(_requestBody(request));
        expect(request.method, 'POST');
        expect(request.url.path, '/me/transcriptions/run-1/feedback');
        expect(request.headers['authorization'], 'Bearer owner-a');
        expect(request.headers['x-csrf-token'], 'csrf-owner-a');
        expect(_requestBody(request), {
          'schema_version': 1,
          'events': [_event()],
        });
        return http.Response('{"error":"temporary"}', 503);
      });
      final firstService = _service(
        client: firstClient,
        store: FilePendingTranscriptionFeedbackStore(file),
        session: _session('owner-a'),
      );

      await expectLater(
        firstService.submitFeedback(runId: 'run-1', events: [_event()]),
        throwsA(isA<ApiError>()),
      );
      firstClient.close();
      final afterFailure = await FilePendingTranscriptionFeedbackStore(
        file,
      ).loadAll();
      expect(afterFailure, hasLength(1));
      expect(afterFailure.single.eventId, 'event-1');
      expect(afterFailure.single.body, _event());
      expect(attempts.single['schema_version'], 1);

      final retryClient = MockClient((request) async {
        attempts.add(_requestBody(request));
        expect(request.url.path, '/me/transcriptions/run-1/feedback');
        expect(request.method, 'POST');
        expect(request.headers['authorization'], 'Bearer owner-a');
        expect(_requestBody(request), {
          'schema_version': 1,
          'events': [_event()],
        });
        return http.Response(
          jsonEncode({
            'run_id': 'run-1',
            'events': [
              {'event_id': 'event-1', 'stage': 'accepted', 'created_at': 1},
            ],
          }),
          200,
        );
      });
      final restartedService = _service(
        client: retryClient,
        store: FilePendingTranscriptionFeedbackStore(file),
        session: _session('owner-a'),
      );

      expect(await restartedService.retryPendingFeedback(), 1);
      expect(
        await FilePendingTranscriptionFeedbackStore(file).loadAll(),
        isEmpty,
      );
      expect(attempts, hasLength(2));
      expect(attempts[0], attempts[1]);
      retryClient.close();
    },
  );

  test(
    'feedback queued for one account is never sent by another account',
    () async {
      final store = FilePendingTranscriptionFeedbackStore(
        File('${directory.path}/feedback.json'),
      );
      await store.save(
        PendingTranscriptionFeedback(
          accountId: 'owner-a',
          runId: 'run-1',
          eventId: 'event-1',
          body: _event(),
        ),
      );
      var requestCount = 0;
      final client = MockClient((request) async {
        requestCount++;
        expect(request.url.path, '/me/transcriptions/run-1/feedback');
        expect(request.method, 'POST');
        expect(request.headers['authorization'], 'Bearer owner-a');
        expect(_requestBody(request), {
          'schema_version': 1,
          'events': [_event()],
        });
        return http.Response(
          '{"run_id":"run-1","events":[{"event_id":"event-1"}]}',
          200,
        );
      });

      final serviceB = _service(
        client: client,
        store: store,
        session: _session('owner-b'),
      );
      expect(await serviceB.retryPendingFeedback(), 0);
      expect(requestCount, 0);
      expect(await store.loadAll(), hasLength(1));

      final serviceA = _service(
        client: client,
        store: store,
        session: _session('owner-a'),
      );
      expect(await serviceA.retryPendingFeedback(), 1);
      expect(requestCount, 1);
      expect(await store.loadAll(), isEmpty);
      client.close();
    },
  );

  test('missing server acknowledgement leaves feedback pending', () async {
    final store = MemoryPendingTranscriptionFeedbackStore();
    final client = MockClient(
      (_) async => http.Response('{"run_id":"run-1","events":[]}', 200),
    );
    final service = _service(
      client: client,
      store: store,
      session: _session('owner-a'),
    );

    await expectLater(
      service.submitFeedback(runId: 'run-1', events: [_event()]),
      throwsA(isA<TranscriptionFeedbackNotConfirmedException>()),
    );
    expect(store.values, hasLength(1));
    client.close();
  });

  test(
    'session replacement during acknowledgement keeps feedback queued',
    () async {
      final store = MemoryPendingTranscriptionFeedbackStore();
      var current = true;
      final session = TranscriptionSession(
        accountId: 'owner-a',
        readHeaders: {'authorization': 'Bearer owner-a'},
        mutationHeaders: {'authorization': 'Bearer owner-a'},
        isCurrent: () => current,
      );
      final client = MockClient((request) async {
        current = false;
        return http.Response(
          '{"run_id":"run-1","events":[{"event_id":"event-1"}]}',
          200,
        );
      });
      final service = _service(client: client, store: store, session: session);

      await expectLater(
        service.submitFeedback(runId: 'run-1', events: [_event()]),
        throwsA(isA<TranscriptionSessionChangedException>()),
      );
      expect(store.values, hasLength(1));
      client.close();
    },
  );

  test('rejects unsupported feedback fields before queueing', () async {
    final store = MemoryPendingTranscriptionFeedbackStore();
    var requestCount = 0;
    final client = MockClient((_) async {
      requestCount++;
      return http.Response('', 500);
    });
    final service = _service(
      client: client,
      store: store,
      session: _session('owner-a'),
    );

    await expectLater(
      service.submitFeedback(
        runId: 'run-1',
        events: [
          <String, Object?>{..._event(), 'owner_id': 'forbidden'},
        ],
      ),
      throwsArgumentError,
    );
    expect(requestCount, 0);
    expect(store.values, isEmpty);
    client.close();
  });

  test(
    'accepts producer-valid empty suggestion and correction feedback',
    () async {
      final store = MemoryPendingTranscriptionFeedbackStore();
      final emptyCorrection = <String, Object?>{
        ..._event(),
        'event_id': 'event-empty-correction',
        'correction': '',
      };
      final emptySuggestion = <String, Object?>{
        ..._event(),
        'event_id': 'event-empty-suggestion',
        'suggestion': '',
      };
      final requests = <Map<String, dynamic>>[];
      final client = MockClient((request) async {
        final body = _requestBody(request);
        expect(request.url.path, '/me/transcriptions/run-1/feedback');
        expect(body['schema_version'], 1);
        final event = (body['events'] as List).single as Map<String, dynamic>;
        requests.add(event);
        return http.Response(
          jsonEncode({
            'run_id': 'run-1',
            'events': [
              {
                'event_id': event['event_id'],
                'stage': 'accepted',
                'created_at': 1,
              },
            ],
          }),
          200,
        );
      });
      final service = _service(
        client: client,
        store: store,
        session: _session('owner-a'),
      );

      await service.submitFeedback(
        runId: 'run-1',
        events: [emptyCorrection, emptySuggestion],
      );

      expect(requests, [emptyCorrection, emptySuggestion]);
      expect(store.values, isEmpty);
      client.close();
    },
  );

  test(
    'rejects a request above the server byte limit before queueing',
    () async {
      final store = MemoryPendingTranscriptionFeedbackStore();
      var requestCount = 0;
      final client = MockClient((_) async {
        requestCount++;
        return http.Response('', 500);
      });
      final service = _service(
        client: client,
        store: store,
        session: _session('owner-a'),
      );

      await expectLater(
        service.submitFeedback(
          runId: 'run-1',
          events: [
            <String, Object?>{
              ..._event(),
              'correction': List<String>.filled(2000000, 'x').join(),
            },
          ],
        ),
        throwsArgumentError,
      );
      expect(requestCount, 0);
      expect(store.values, isEmpty);
      client.close();
    },
  );

  test('local result retry survives restart and remains owner-bound', () async {
    final file = File('${directory.path}/results.json');
    final document = {
      'page': {
        'width': 1000,
        'background': {'kind': 'blank'},
      },
      'items': <Object?>[],
    };
    final resultBodies = <Map<String, dynamic>>[];
    final firstClient = MockClient((request) async {
      expect(request.headers['authorization'], 'Bearer owner-a');
      if (request.url.path == '/me/transcriptions') {
        expect(request.method, 'POST');
        expect(jsonDecode(request.body), {
          'download_id': 'download-1',
          'model_version': 'v1',
          'language': 'en',
          'mode': 'local',
          'source_revision_id': 'revision-1',
          'ink': {'schema_version': 1, 'document': document},
        });
        return http.Response(jsonEncode(_run('registered')), 201);
      }
      if (request.url.path == '/me/transcriptions/run-1/result') {
        expect(request.method, 'PUT');
        resultBodies.add(_requestBody(request));
        return http.Response('{"error":"temporary"}', 503);
      }
      return http.Response('{"error":"unexpected route"}', 404);
    });
    final stages = <String>[];
    final firstService = _service(
      client: firstClient,
      store: MemoryPendingTranscriptionFeedbackStore(),
      session: _session('owner-a'),
      pendingResults: FilePendingTranscriptionResults(file),
      eventId: () => 'result-event-1',
    );

    await expectLater(
      firstService.runLocal(
        downloadId: 'download-1',
        modelVersion: 'v1',
        language: 'en',
        sourceRevisionId: 'revision-1',
        selectedInkDocument: document,
        schemaVersion: 1,
        modelFile: File('fixture-model'),
        runtime: _FixtureRuntime(document),
        onStage: stages.add,
      ),
      throwsA(isA<ApiError>()),
    );
    firstClient.close();
    expect(stages, ['recognizing']);
    expect(resultBodies.single['event_id'], 'result-event-1');
    expect(await FilePendingTranscriptionResults(file).loadAll(), hasLength(1));

    final otherAccountClient = MockClient((_) async {
      fail('A different account must not send this result.');
    });
    final serviceB = _service(
      client: otherAccountClient,
      store: MemoryPendingTranscriptionFeedbackStore(),
      session: _session('owner-b'),
      pendingResults: FilePendingTranscriptionResults(file),
    );
    expect(await serviceB.retryPendingResults(), 0);
    expect(await FilePendingTranscriptionResults(file).loadAll(), hasLength(1));
    otherAccountClient.close();

    final retryClient = MockClient((request) async {
      expect(request.method, 'PUT');
      expect(request.url.path, '/me/transcriptions/run-1/result');
      expect(request.headers['authorization'], 'Bearer owner-a');
      resultBodies.add(_requestBody(request));
      return http.Response(jsonEncode(_run('completed')), 200);
    });
    final restartedService = _service(
      client: retryClient,
      store: MemoryPendingTranscriptionFeedbackStore(),
      session: _session('owner-a'),
      pendingResults: FilePendingTranscriptionResults(file),
    );
    expect(await restartedService.retryPendingResults(), 1);
    expect(resultBodies, hasLength(2));
    expect(resultBodies[0], resultBodies[1]);
    expect(await FilePendingTranscriptionResults(file).loadAll(), isEmpty);
    retryClient.close();
  });

  test(
    'local hash-source run resumes the saved run without a second inference',
    () async {
      final sourceHash = List.filled(64, 'a').join();
      final document = <String, Object?>{
        'page': {
          'width': 1000,
          'background': {'kind': 'blank'},
        },
        'items': <Object?>[],
      };
      final calls = <String>[];
      var runtimeCalls = 0;
      Map<String, Object?> run(String status) {
        final value = Map<String, Object?>.from(_run(status))
          ..remove('source_revision_id')
          ..['source_hash'] = sourceHash;
        if (status == 'completed') {
          value['result'] = {'event_id': 'hash-result', 'document': document};
        }
        return value;
      }

      final client = MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        if (request.url.path == '/me/transcriptions') {
          expect(request.method, 'POST');
          expect(_requestBody(request)['source_hash'], sourceHash);
          expect(
            _requestBody(request).containsKey('source_revision_id'),
            isFalse,
          );
          return http.Response(jsonEncode(run('registered')), 201);
        }
        if (request.url.path == '/me/transcriptions/run-1/result') {
          expect(request.method, 'PUT');
          final body = _requestBody(request);
          expect(body['source_hash'], sourceHash);
          expect(body.containsKey('source_revision_id'), isFalse);
          return http.Response(jsonEncode(run('completed')), 200);
        }
        if (request.url.path == '/me/transcriptions/run-1') {
          expect(request.method, 'GET');
          return http.Response(jsonEncode(run('completed')), 200);
        }
        return http.Response('{"error":"unexpected route"}', 404);
      });
      final service = _service(
        client: client,
        store: MemoryPendingTranscriptionFeedbackStore(),
        session: _session('owner-a'),
        pendingResults: MemoryPendingTranscriptionResults(),
        eventId: () => 'hash-result',
      );
      final runtime = _CountingRuntime(document, () => runtimeCalls++);
      final registrationOrder = <String>[];

      await service.runLocal(
        downloadId: 'download-1',
        modelVersion: 'v1',
        language: 'en',
        sourceHash: sourceHash,
        selectedInkDocument: document,
        schemaVersion: 1,
        modelFile: File('fixture-model'),
        runtime: runtime,
        onStage: (stage) => registrationOrder.add(stage),
        onRegistered: (run) async {
          expect(run.runId, 'run-1');
          registrationOrder.add('saved-context');
        },
      );
      final resumed = await service.resumeLocal(
        runId: 'run-1',
        sourceHash: sourceHash,
        downloadId: 'download-1',
        modelVersion: 'v1',
        language: 'en',
        selectedInkDocument: document,
        schemaVersion: 1,
        modelFile: File('fixture-model'),
        runtime: runtime,
        onStage: (_) {},
      );

      expect(registrationOrder, ['saved-context', 'recognizing']);
      expect(runtimeCalls, 1);
      expect(resumed.runId, 'run-1');
      expect(resumed.eventId, 'hash-result');
      expect(
        calls.where((call) => call == 'POST /me/transcriptions'),
        hasLength(1),
      );
      expect(
        calls.where((call) => call == 'GET /me/transcriptions/run-1'),
        hasLength(1),
      );
      client.close();
    },
  );

  test(
    'registration account switch never rebinds local recognition to new owner',
    () async {
      var currentAccount = 'owner-a';
      TranscriptionSession sessionFor(String accountId) => TranscriptionSession(
        accountId: accountId,
        readHeaders: {'authorization': 'Bearer $accountId'},
        mutationHeaders: {
          'authorization': 'Bearer $accountId',
          'x-csrf-token': 'csrf-$accountId',
        },
        isCurrent: () => currentAccount == accountId,
      );
      final pending = MemoryPendingTranscriptionResults();
      var runtimeCalls = 0;
      var resultPuts = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/me/transcriptions') {
          expect(request.method, 'POST');
          expect(request.headers['authorization'], 'Bearer owner-a');
          currentAccount = 'owner-b';
          return http.Response(jsonEncode(_run('registered')), 201);
        }
        if (request.url.path == '/me/transcriptions/run-1/result') {
          resultPuts++;
          expect(request.method, 'PUT');
          expect(request.headers['authorization'], 'Bearer owner-b');
          return http.Response(jsonEncode(_run('registered')), 200);
        }
        return http.Response('{"error":"unexpected route"}', 404);
      });
      final service = TranscriptionRunService(
        api: TranscriptionApiAdapter(
          ApiAdapter(client: client, base: 'https://api.test'),
        ),
        sessionProvider: () async => sessionFor(currentAccount),
        pendingResults: pending,
        pendingFeedback: MemoryPendingTranscriptionFeedbackStore(),
        enabled: true,
        newEventId: () => 'result-event-1',
      );
      final document = <String, Object?>{
        'page': {
          'width': 1000,
          'background': {'kind': 'blank'},
        },
        'items': <Object?>[],
      };

      Object? failure;
      try {
        await service.runLocal(
          downloadId: 'download-1',
          modelVersion: 'v1',
          language: 'en',
          sourceRevisionId: 'revision-1',
          selectedInkDocument: document,
          schemaVersion: 1,
          modelFile: File('fixture-model'),
          runtime: _CountingRuntime(document, () => runtimeCalls++),
          onStage: (_) {},
        );
      } on Object catch (error) {
        failure = error;
      }

      expect(failure, isA<TranscriptionSessionChangedException>());
      expect(runtimeCalls, 0);
      expect(resultPuts, 0);
      expect(pending.values, isEmpty);
      client.close();
    },
  );

  test(
    'a result is not cleared until the server marks the run completed',
    () async {
      final store = MemoryPendingTranscriptionResults();
      await store.save(
        PendingTranscriptionResult(
          accountId: 'owner-a',
          runId: 'run-1',
          eventId: 'result-event-1',
          body: {'event_id': 'result-event-1', 'document': <String, Object?>{}},
        ),
      );
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            ..._run('registered'),
            'result': {'event_id': 'result-event-1'},
          }),
          200,
        ),
      );
      final service = _service(
        client: client,
        store: MemoryPendingTranscriptionFeedbackStore(),
        session: _session('owner-a'),
        pendingResults: store,
      );

      await expectLater(
        service.retryPendingResults(),
        throwsA(isA<TranscriptionResultNotConfirmedException>()),
      );
      expect(store.values, hasLength(1));
      client.close();
    },
  );

  test('cloud progress is delivered before the SSE response closes', () async {
    final client = _LiveEventsClient();
    final service = _service(
      client: client,
      store: MemoryPendingTranscriptionFeedbackStore(),
      session: _session('owner-a'),
    );
    final received = <TranscriptionEvent>[];
    final firstEvent = Completer<void>();
    final waiting = service.waitForCloudResult(
      'run-1',
      onEvent: (event) {
        received.add(event);
        if (!firstEvent.isCompleted) firstEvent.complete();
      },
    );
    await client.eventRequestStarted.future;

    final prefix = utf8.encode(
      'id: 1\r\nevent: progress\r\ndata: {"status":"running","text":"',
    );
    final thai = utf8.encode('กิ');
    client.events.add([...prefix, thai.first]);
    client.events.add([...thai.skip(1), ...utf8.encode('"}\r')]);
    client.events.add(utf8.encode('\n\r\n'));
    await firstEvent.future.timeout(const Duration(seconds: 2));

    expect(received, hasLength(1));
    expect(received.single.id, 1);
    expect(received.single.stage, 'progress');
    expect(received.single.data['text'], 'กิ');
    expect(client.getRunCalls, 1);

    client.events.close();
    final run = await waiting;
    expect(run.status, 'completed');
    expect(client.getRunCalls, 2);
    client.close();
  });

  test(
    'account change during SSE prevents delivering its old-owner event',
    () async {
      var current = true;
      final session = TranscriptionSession(
        accountId: 'owner-a',
        readHeaders: {'authorization': 'Bearer owner-a'},
        mutationHeaders: {'authorization': 'Bearer owner-a'},
        isCurrent: () => current,
      );
      final client = _LiveEventsClient();
      final service = _service(
        client: client,
        store: MemoryPendingTranscriptionFeedbackStore(),
        session: session,
      );
      var callbacks = 0;
      final waiting = service.waitForCloudResult(
        'run-1',
        onEvent: (_) => callbacks++,
      );
      await client.eventRequestStarted.future;
      final expectedFailure = expectLater(
        waiting,
        throwsA(isA<TranscriptionSessionChangedException>()),
      );
      current = false;
      client.events.add(
        utf8.encode('id: 1\nevent: progress\ndata: {"status":"running"}\n\n'),
      );
      await expectedFailure;
      expect(callbacks, 0);
      client.close();
    },
  );

  test(
    'account change during the final run read rejects the old result',
    () async {
      var current = true;
      final session = TranscriptionSession(
        accountId: 'owner-a',
        readHeaders: {'authorization': 'Bearer owner-a'},
        mutationHeaders: {'authorization': 'Bearer owner-a'},
        isCurrent: () => current,
      );
      final finalRead = Completer<http.Response>();
      var getCalls = 0;
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/events')) {
          return http.Response(
            'id: 1\nevent: progress\ndata: {"status":"running"}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }
        getCalls++;
        if (getCalls == 1) {
          return http.Response(jsonEncode(_cloudRun('registered', 0)), 200);
        }
        return finalRead.future;
      });
      final service = _service(
        client: client,
        store: MemoryPendingTranscriptionFeedbackStore(),
        session: session,
      );
      final waiting = service.waitForCloudResult('run-1', onEvent: (_) {});
      while (getCalls < 2) {
        await Future<void>.delayed(Duration.zero);
      }
      current = false;
      finalRead.complete(
        http.Response(jsonEncode(_cloudRun('completed', 1)), 200),
      );
      await expectLater(
        waiting,
        throwsA(isA<TranscriptionSessionChangedException>()),
      );
      client.close();
    },
  );

  test(
    'account change during the initial run read rejects the old result',
    () async {
      var current = true;
      final session = TranscriptionSession(
        accountId: 'owner-a',
        readHeaders: {'authorization': 'Bearer owner-a'},
        mutationHeaders: {'authorization': 'Bearer owner-a'},
        isCurrent: () => current,
      );
      final initialRead = Completer<http.Response>();
      var requested = false;
      final client = MockClient((_) {
        requested = true;
        return initialRead.future;
      });
      final service = _service(
        client: client,
        store: MemoryPendingTranscriptionFeedbackStore(),
        session: session,
      );

      final waiting = service.waitForCloudResult('run-1', onEvent: (_) {});
      while (!requested) {
        await Future<void>.delayed(Duration.zero);
      }
      current = false;
      initialRead.complete(
        http.Response(jsonEncode(_cloudRun('completed', 0)), 200),
      );
      await expectLater(
        waiting,
        throwsA(isA<TranscriptionSessionChangedException>()),
      );
      client.close();
    },
  );
}

TranscriptionRunService _service({
  required http.Client client,
  required PendingTranscriptionFeedbackStore store,
  required TranscriptionSession session,
  PendingTranscriptionResults? pendingResults,
  String Function()? eventId,
}) => TranscriptionRunService(
  api: TranscriptionApiAdapter(
    ApiAdapter(client: client, base: 'https://api.test'),
  ),
  sessionProvider: () async => session,
  pendingResults: pendingResults ?? MemoryPendingTranscriptionResults(),
  pendingFeedback: store,
  enabled: true,
  newEventId: eventId,
);

final class _LiveEventsClient extends http.BaseClient {
  final eventRequestStarted = Completer<void>();
  late StreamController<List<int>> events;
  bool _eventsCreated = false;
  int getRunCalls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path.endsWith('/events')) {
      events = StreamController<List<int>>();
      _eventsCreated = true;
      eventRequestStarted.complete();
      return http.StreamedResponse(
        events.stream,
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    }
    getRunCalls++;
    final body = jsonEncode(
      _cloudRun(getRunCalls == 1 ? 'registered' : 'completed', 1),
    );
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(body)),
      200,
      headers: {'content-type': 'application/json'},
    );
  }

  @override
  void close() {
    if (_eventsCreated && !events.isClosed) events.close();
  }
}

final class _FixtureRuntime implements TranscriptionRuntime {
  const _FixtureRuntime(this.document);

  final Map<String, Object?> document;

  @override
  Future<LocalRecognitionResult> recognize({
    required File modelFile,
    required Map<String, Object?> selectedInkDocument,
    required String language,
    required void Function(String stage) onStage,
  }) async {
    expect(modelFile.path, 'fixture-model');
    expect(selectedInkDocument, document);
    expect(language, 'en');
    onStage('recognizing');
    return const LocalRecognitionResult(
      document: {
        'blocks': [
          {
            'id': 'block-1',
            'kind': 'paragraph',
            'spans': [
              {'text': 'hello'},
            ],
          },
        ],
      },
      runtimeName: 'fixture',
      runtimeVersion: '1',
      elapsedMilliseconds: 5,
    );
  }
}

final class _CountingRuntime implements TranscriptionRuntime {
  const _CountingRuntime(this.document, this.onRecognize);

  final Map<String, Object?> document;
  final void Function() onRecognize;

  @override
  Future<LocalRecognitionResult> recognize({
    required File modelFile,
    required Map<String, Object?> selectedInkDocument,
    required String language,
    required void Function(String stage) onStage,
  }) async {
    onRecognize();
    onStage('recognizing');
    return LocalRecognitionResult(
      document: document,
      runtimeName: 'fixture',
      runtimeVersion: '1',
      elapsedMilliseconds: 1,
    );
  }
}

Map<String, Object?> _run(String status) => {
  'run_id': 'run-1',
  'download_id': 'download-1',
  'model_version': 'v1',
  'platform': 'linux',
  'language': 'en',
  'mode': 'local',
  'status': status,
  'source_stale': false,
  'last_event_id': 0,
  if (status == 'completed') 'result': {'event_id': 'result-event-1'},
  'source_revision_id': 'revision-1',
};

Map<String, Object?> _cloudRun(String status, int lastEventId) => {
  ..._run(status),
  'mode': 'cloud',
  'last_event_id': lastEventId,
};

TranscriptionSession _session(String accountId) => TranscriptionSession(
  accountId: accountId,
  readHeaders: {'authorization': 'Bearer $accountId'},
  mutationHeaders: {
    'authorization': 'Bearer $accountId',
    'x-csrf-token': 'csrf-$accountId',
  },
  isCurrent: () => true,
);

Map<String, Object?> _event() => {
  'event_id': 'event-1',
  'segment_id': 'segment-1',
  'source_item_ids': ['stroke-1'],
  'strokes': [
    {
      'x': [100, 200],
      'y': [100, 200],
      't': [0, 5],
      'pressure': [500, 600],
    },
  ],
  'suggestion': 'helo',
  'correction': 'hello',
  'stage': 'accepted',
  'language': 'en',
  'model_version': 'fixture-v1',
};

Map<String, dynamic> _requestBody(http.Request request) =>
    jsonDecode(request.body) as Map<String, dynamic>;
