import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:annotations_shared/dal/remote/api_adapter.dart';
import 'package:annotations_shared/dal/remote/transcription_api_adapter.dart';
import 'package:annotations_shared/domain/models/transcription_session.dart';
import 'package:annotations_shared/domain/services/model_download_service.dart';
import 'package:annotations_shared/domain/services/transcription_draft_service.dart';
import 'package:annotations_shared/domain/services/transcription_run_service.dart';
import 'package:annotations_shared/domain/services/transcription_workflow_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'note_capacity_test.dart' show handwriting;

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'annotations-transcription-workflow-',
    );
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'starts from only selected source and persists before recognition',
    () async {
      final bytes = [1, 2, 3, 4];
      final hash = sha256.convert(bytes).toString();
      final model = File('${directory.path}/v1_linux_$hash.model');
      await model.writeAsBytes(bytes);
      final selected = <Map<String, dynamic>>[
        {
          'id': 'group-1',
          'kind': 'group',
          'members': ['s1'],
        },
      ];
      final stroke = handwriting(1);
      final ink = <String, Object?>{
        'page': {
          'width': 240,
          'background': {'kind': 'blank'},
        },
        'items': [...selected, stroke],
      };
      final resultDocument = <String, Object?>{
        'blocks': [
          {
            'id': 'block-1',
            'kind': 'paragraph',
            'spans': [
              {'text': 'fixture recognition'},
            ],
          },
        ],
      };
      final requests = <String>[];
      final feedbackEventIds = <String>[];
      String? resultEventId;
      var sessionCurrent = true;
      var sessionReads = 0;
      final session = _session(() => sessionCurrent);
      Future<TranscriptionSession?> sessionProvider() async {
        sessionReads++;
        if (sessionReads == 6) sessionCurrent = false;
        return session;
      }

      final client = MockClient((request) async {
        requests.add('${request.method} ${request.url.path}');
        if (request.url.path == '/models/v1') {
          return _manifest(hash, bytes.length);
        }
        if (request.url.path == '/me/model_downloads/download-1') {
          return _grant(hash, bytes.length);
        }
        if (request.url.path == '/me/transcriptions' &&
            request.method == 'POST') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['source_hash'], 'a' * 64);
          expect(body.containsKey('source_revision_id'), isFalse);
          expect(body['ink']['document']['items'], [...selected, stroke]);
          return _run('registered', sourceHash: 'a' * 64);
        }
        if (request.url.path == '/me/transcriptions/run-1/result') {
          expect(request.method, 'PUT');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['source_hash'], 'a' * 64);
          resultEventId = body['event_id'] as String;
          return _run(
            'completed',
            sourceHash: 'a' * 64,
            result: {'event_id': resultEventId, 'document': resultDocument},
          );
        }
        if (request.url.path == '/me/transcriptions/run-1') {
          return _run(
            'completed',
            sourceHash: 'a' * 64,
            result: {'event_id': resultEventId, 'document': resultDocument},
          );
        }
        if (request.url.path == '/me/transcriptions/run-1/feedback') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final event = (body['events'] as List).single as Map;
          feedbackEventIds.add('${event['event_id']}');
          expect(event['source_item_ids'], ['group-1']);
          expect(event['strokes'], [stroke]);
          return http.Response(
            jsonEncode({
              'run_id': 'run-1',
              'events': [
                {'event_id': event['event_id']},
              ],
            }),
            200,
          );
        }
        return http.Response('unexpected route', 404);
      });
      late final TranscriptionWorkflowService workflow;
      var runtimeCalls = 0;
      var runtimeSawRegisteredDraft = false;
      workflow = _workflow(
        client: client,
        directory: directory,
        sessionProvider: sessionProvider,
      );

      final draft = await workflow.startLocal(
        noteId: 'note-1',
        localSourceRevision: 3,
        sourceHash: 'a' * 64,
        selectedSourceItems: selected,
        selectedSourceItemIds: const ['group-1'],
        selectedInkDocument: ink,
        downloaded: DownloadedModel(
          grant: _grantValue(hash, bytes.length),
          file: model,
          manifest: _manifestValue(hash, bytes.length),
        ),
        language: 'en',
        schemaVersion: 1,
        runtime: _Runtime(resultDocument, () {
          runtimeCalls++;
          runtimeSawRegisteredDraft =
              workflow.drafts
                  .reopenDraft('note-1', accountId: 'owner-a')
                  ?.runId ==
              'run-1';
        }),
        onStage: (_) {},
      );

      expect(draft.accountId, 'owner-a');
      expect(draft.runId, 'run-1');
      expect(draft.sourceRevision, 3);
      expect(draft.baseSourceHash, 'a' * 64);
      expect(draft.passages.single.text, 'fixture recognition');
      expect(runtimeCalls, 1);
      expect(runtimeSawRegisteredDraft, isTrue);
      expect(
        requests.where((path) => path == 'POST /me/transcriptions'),
        hasLength(1),
      );
      expect(requests, contains('GET /me/model_downloads/download-1'));
      expect(
        workflow.drafts.reopenDraft('note-1', accountId: 'owner-b'),
        isNull,
      );
      await expectLater(
        workflow.correctPassage(
          noteId: 'note-1',
          partId: 'group-1',
          correctedText: 'corrected fixture text',
        ),
        throwsA(isA<TranscriptionSessionChangedException>()),
      );
      final savedCorrection = workflow.drafts.reopenDraft(
        'note-1',
        accountId: 'owner-a',
      )!;
      expect(savedCorrection.passages.single.text, 'corrected fixture text');
      expect(savedCorrection.pendingFeedbackEvents, hasLength(1));
      final reloadedDraft = TranscriptionDraftService(
        persistenceFile: File('${directory.path}/drafts.json'),
      ).reopenDraft('note-1', accountId: 'owner-a')!;
      expect(
        reloadedDraft.pendingFeedbackEvents,
        savedCorrection.pendingFeedbackEvents,
      );
      final pendingEventId =
          '${savedCorrection.pendingFeedbackEvents.single['event_id']}';
      sessionCurrent = true;
      expect(await workflow.retryPendingFeedback(), 1);
      expect(
        workflow.drafts
            .reopenDraft('note-1', accountId: 'owner-a')!
            .pendingFeedbackEvents,
        isEmpty,
      );
      expect(requests, contains('POST /me/transcriptions/run-1/feedback'));
      expect(feedbackEventIds, [pendingEventId]);
      final requestsBeforeResume = requests.length;
      final resumed = await workflow.resumeLocal(
        noteId: 'note-1',
        runtime: _Runtime(resultDocument, () => runtimeCalls++),
        onStage: (_) {},
      );
      expect(resumed.runId, 'run-1');
      expect(runtimeCalls, 1);
      expect(requests, hasLength(requestsBeforeResume));
      client.close();
    },
  );

  test('selected ids must exactly match the submitted source sample', () async {
    var requestCount = 0;
    final client = MockClient((_) async {
      requestCount++;
      return http.Response('unexpected route', 500);
    });
    final bytes = [9];
    final hash = sha256.convert(bytes).toString();
    final model = File('${directory.path}/v1_linux_$hash.model');
    await model.writeAsBytes(bytes);
    final workflow = _workflow(
      client: client,
      directory: directory,
      sessionProvider: () async => _session(),
    );

    await expectLater(
      workflow.startLocal(
        noteId: 'note-1',
        localSourceRevision: 1,
        sourceHash: 'b' * 64,
        selectedSourceItems: const [
          {'id': 'stroke-1', 'kind': 'stroke'},
        ],
        selectedSourceItemIds: const ['stroke-2'],
        selectedInkDocument: const {
          'items': [
            {'id': 'stroke-1', 'kind': 'stroke'},
          ],
        },
        downloaded: DownloadedModel(
          grant: _grantValue(hash, bytes.length),
          file: model,
          manifest: _manifestValue(hash, bytes.length),
        ),
        language: 'en',
        schemaVersion: 1,
        runtime: _Runtime(const {}, () {}),
        onStage: (_) {},
      ),
      throwsArgumentError,
    );
    expect(requestCount, 0);
    client.close();
  });

  test(
    'late acceptance acknowledgement cannot accept a newer correction',
    () async {
      final stroke = handwriting(1);
      final strokeId = '${stroke['id']}';
      final acceptResponse = Completer<http.Response>();
      final acceptWasSent = Completer<void>();
      final receivedAcceptedId = Completer<String>();
      var feedbackCalls = 0;
      final client = MockClient((request) async {
        if (request.url.path != '/me/transcriptions/run-1/feedback') {
          return http.Response('unexpected route', 404);
        }
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final events = body['events'] as List;
        final event = Map<String, dynamic>.from(events.single as Map);
        feedbackCalls++;
        if (event['stage'] == 'accepted') {
          acceptWasSent.complete();
          receivedAcceptedId.complete(event['event_id'] as String);
          return acceptResponse.future;
        }
        return http.Response(
          jsonEncode({
            'run_id': 'run-1',
            'events': [
              {'event_id': event['event_id']},
            ],
          }),
          200,
        );
      });
      final workflow = _workflow(
        client: client,
        directory: directory,
        sessionProvider: () async => _session(),
      );
      workflow.drafts.saveDraft(
        noteId: 'late-ack',
        accountId: 'owner-a',
        runId: 'run-1',
        downloadId: 'download-1',
        modelVersion: 'v1',
        platform: 'linux',
        language: 'en',
        schemaVersion: 1,
        sourceRevision: 1,
        sourceHash: 'a' * 64,
        selectedSourceItemIds: [strokeId],
        selectedInkDocument: {
          'items': [stroke],
        },
        passages: [
          TranscriptionPassage(
            partId: strokeId,
            sourceItemIds: [strokeId],
            sourceHash: 'ink-source',
            y: 1,
            x: 1,
            kind: TranscriptionPassageKind.text,
            text: 'model suggestion',
          ),
        ],
      );

      await workflow.correctPassage(
        noteId: 'late-ack',
        partId: strokeId,
        correctedText: 'first accepted text',
      );
      final accepting = workflow.acceptCorrection(
        noteId: 'late-ack',
        partId: strokeId,
      );
      await acceptWasSent.future;
      final acceptedEventId = await receivedAcceptedId.future;
      await workflow.correctPassage(
        noteId: 'late-ack',
        partId: strokeId,
        correctedText: 'newer text',
      );
      final whileOldAckPending = workflow.drafts.reopenDraft(
        'late-ack',
        accountId: 'owner-a',
      )!;
      expect(whileOldAckPending.passages.single.text, 'newer text');
      expect(whileOldAckPending.passages.single.feedbackAccepted, isFalse);

      acceptResponse.complete(
        http.Response(
          jsonEncode({
            'run_id': 'run-1',
            'events': [
              {'event_id': acceptedEventId},
            ],
          }),
          200,
        ),
      );
      await accepting;
      final afterOldAck = workflow.drafts.reopenDraft(
        'late-ack',
        accountId: 'owner-a',
      )!;
      expect(afterOldAck.passages.single.text, 'newer text');
      expect(afterOldAck.passages.single.userCorrected, isTrue);
      expect(afterOldAck.passages.single.feedbackAccepted, isFalse);
      expect(afterOldAck.pendingFeedbackEvents, isEmpty);
      expect(feedbackCalls, 3);
      client.close();
    },
  );
}

TranscriptionWorkflowService _workflow({
  required http.Client client,
  required Directory directory,
  required TranscriptionSessionProvider sessionProvider,
}) {
  final api = ApiAdapter(client: client, base: 'https://api.test');
  final sessionBoundApi = TranscriptionApiAdapter(api);
  final runs = TranscriptionRunService(
    api: sessionBoundApi,
    sessionProvider: sessionProvider,
    pendingResults: FilePendingTranscriptionResults(
      File('${directory.path}/results.json'),
    ),
    pendingFeedback: FilePendingTranscriptionFeedbackStore(
      File('${directory.path}/feedback.json'),
    ),
    enabled: true,
  );
  return TranscriptionWorkflowService(
    downloads: ModelDownloadService(
      api: sessionBoundApi,
      store: DirectoryModelArtifactStore(directory),
      sessionProvider: sessionProvider,
      enabled: true,
    ),
    runs: runs,
    drafts: TranscriptionDraftService(
      persistenceFile: File('${directory.path}/drafts.json'),
    ),
    sessionProvider: sessionProvider,
    decodePassages: (result, selectedItems) {
      expect(result['blocks'], isNotEmpty);
      expect(selectedItems.map((item) => item['id']), ['group-1', 's1']);
      return [
        TranscriptionPassage(
          partId: 'group-1',
          sourceItemIds: const ['group-1'],
          sourceHash: 'source-stroke-hash',
          y: 2,
          x: 3,
          kind: TranscriptionPassageKind.text,
          text: 'fixture recognition',
        ),
      ];
    },
  );
}

final class _Runtime implements TranscriptionRuntime {
  const _Runtime(this.document, this.onRecognize);

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

TranscriptionSession _session([bool Function()? isCurrent]) =>
    TranscriptionSession(
      accountId: 'owner-a',
      readHeaders: {'authorization': 'Bearer owner-a'},
      mutationHeaders: {
        'authorization': 'Bearer owner-a',
        'x-csrf-token': 'csrf-owner-a',
      },
      isCurrent: isCurrent ?? () => true,
    );

ModelReleaseManifest _manifestValue(String hash, int size) =>
    ModelReleaseManifest.fromJson({
      'version': 'v1',
      'status': 'published',
      'is_default': true,
      'created_at': 1,
      'artifacts': [
        {'platform': 'linux', 'size': size, 'sha256': hash},
      ],
      'languages': ['en'],
      'capabilities': ['transcription'],
    });

ModelDownloadGrant _grantValue(String hash, int size) =>
    ModelDownloadGrant.fromJson({
      'download_id': 'download-1',
      'model_version': 'v1',
      'platform': 'linux',
      'size': size,
      'sha256': hash,
      'model_status': 'published',
      'created_at': 1,
    });

http.Response _manifest(String hash, int size) => http.Response(
  jsonEncode({
    'version': 'v1',
    'status': 'published',
    'is_default': true,
    'created_at': 1,
    'artifacts': [
      {'platform': 'linux', 'size': size, 'sha256': hash},
    ],
    'languages': ['en'],
    'capabilities': ['transcription'],
  }),
  200,
);

http.Response _grant(String hash, int size) => http.Response(
  jsonEncode({
    'download_id': 'download-1',
    'model_version': 'v1',
    'platform': 'linux',
    'size': size,
    'sha256': hash,
    'model_status': 'published',
    'created_at': 1,
  }),
  200,
);

http.Response _run(
  String status, {
  required String sourceHash,
  Map<String, Object?>? result,
}) => http.Response(
  jsonEncode({
    'run_id': 'run-1',
    'download_id': 'download-1',
    'model_version': 'v1',
    'platform': 'linux',
    'language': 'en',
    'mode': 'local',
    'status': status,
    'source_stale': false,
    'last_event_id': 0,
    'source_hash': sourceHash,
    'result': ?result,
  }),
  status == 'registered' ? 201 : 200,
);
