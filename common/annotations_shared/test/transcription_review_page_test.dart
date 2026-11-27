import 'dart:io';

import 'package:annotations_shared/dal/remote/api_adapter.dart';
import 'package:annotations_shared/dal/remote/aes_cbc.dart';
import 'package:annotations_shared/dal/remote/transcription_api_adapter.dart';
import 'package:annotations_shared/core/platform_profile.dart';
import 'package:annotations_shared/domain/models/local_note.dart';
import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/models/transcription_session.dart';
import 'package:annotations_shared/domain/services/annotations_service.dart';
import 'package:annotations_shared/domain/services/local_note_store.dart';
import 'package:annotations_shared/domain/services/local_workspace.dart';
import 'package:annotations_shared/domain/services/model_download_service.dart';
import 'package:annotations_shared/domain/services/native_auth_service.dart';
import 'package:annotations_shared/domain/services/note_sync_service.dart';
import 'package:annotations_shared/domain/services/note_autosave.dart';
import 'package:annotations_shared/domain/services/object_selection.dart';
import 'package:annotations_shared/domain/services/preferences.dart';
import 'package:annotations_shared/domain/services/installed_account.dart';
import 'package:annotations_shared/domain/services/transcription_draft_service.dart';
import 'package:annotations_shared/domain/services/transcription_run_service.dart';
import 'package:annotations_shared/domain/services/transcription_workflow_service.dart';
import 'package:annotations_shared/presentation/frontend/components/scope.dart';
import 'package:annotations_shared/presentation/frontend/components/theme.dart';
import 'package:annotations_shared/presentation/frontend/widgets/workspace/transcription_review_page.dart';
import 'package:annotations_shared/presentation/frontend/widgets/workspace/note_editor_page.dart';
import 'package:annotations_shared/presentation/frontend/widgets/paper/paper_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'note_capacity_test.dart' show handwriting;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'stale selection never widens and cancel leaves Original untouched',
    (tester) async {
      final directory = Directory(
        '/home/main-server/.cache/codex-impl-3/tmp/'
        'annotations48-transcription-review/widget-files/'
        '${DateTime.now().microsecondsSinceEpoch}',
      )..createSync(recursive: true);
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final original = NoteDocument.fromJson({
        'page': {
          'width': 1000,
          'background': {'kind': 'blank'},
        },
        'items': [handwriting(1), handwriting(2)],
      }, schema: DocumentSchema(DocumentFamily.original.schemaName, 1));
      final originalBytes = original.toJson().toString();
      final note = LocalNote(
        id: 'note-1',
        schema: original.schema,
        document: original,
        title: 'Original fixture',
        revision: 1,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        syncState: LocalSyncState.local,
        accountId: 'owner-a',
      );
      final client = MockClient(
        (_) async => throw StateError('unexpected API'),
      );
      addTearDown(client.close);
      Future<TranscriptionSession?> sessionProvider() async => null;
      final drafts = TranscriptionDraftService();
      final workflow = _workflow(directory, client, drafts, sessionProvider);
      final store = _ReadOnlyStore(note);
      final preferences = Preferences();
      addTearDown(preferences.dispose);

      await tester.pumpWidget(
        AppScope(
          preferences: preferences,
          service: AnnotationsService(api: ApiAdapter(client: client)),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: appTheme(Brightness.light),
            home: TranscriptionReviewPage(
              note: note,
              initialSelectedItemIds: const ['removed-source-id'],
              access: TranscriptionReviewAccess(
                workflow: workflow,
                runtime: _UnusedRuntime(),
                platform: 'linux',
              ),
              store: store,
              ownerAccountId: 'owner-a',
              isOwnerScopeCurrent: () => true,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final sourceOne = find.byKey(const Key('transcription-source-s1'));
      final sourceTwo = find.byKey(const Key('transcription-source-s2'));
      expect(sourceOne, findsOneWidget);
      expect(sourceTwo, findsOneWidget);
      expect(
        find.byKey(const Key('transcription-selection-invalid')),
        findsOneWidget,
      );
      expect((tester.widget(sourceOne) as CheckboxListTile).value, isFalse);
      expect((tester.widget(sourceTwo) as CheckboxListTile).value, isFalse);
      await tester.tap(sourceOne);
      await tester.pump();
      expect((tester.widget(sourceOne) as CheckboxListTile).value, isTrue);
      expect((tester.widget(sourceTwo) as CheckboxListTile).value, isFalse);
      expect(
        find.byKey(const Key('transcription-selection-invalid')),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('transcription-cancel')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(store.saved, isEmpty);
      expect(
        workflow.drafts.reopenDraft('note-1', accountId: 'owner-a'),
        isNull,
      );
      expect(original.toJson().toString(), originalBytes);
    },
  );

  testWidgets('a synced Original resumes against its revision identity', (
    tester,
  ) async {
    final directory = Directory(
      '/home/main-server/.cache/codex-impl-3/tmp/'
      'annotations48-transcription-review/widget-files/'
      '${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    final original = NoteDocument.fromJson({
      'page': {
        'width': 1000,
        'background': {'kind': 'blank'},
      },
      'items': [handwriting(2)],
    }, schema: DocumentSchema(DocumentFamily.original.schemaName, 1));
    final item =
        (original.toJson()['items'] as List).single as Map<String, Object?>;
    const sourceRevisionId = 'original-revision-1';
    final note = LocalNote(
      id: 'note-2',
      schema: original.schema,
      document: original,
      title: 'Synced fixture',
      revision: 4,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      syncState: LocalSyncState.synced,
      accountId: 'owner-a',
      serverNoteId: 'server-note-2',
      serverOriginalRevisionId: sourceRevisionId,
    );
    final drafts = TranscriptionDraftService(
      persistenceFile: File('${directory.path}/drafts.json'),
    );
    drafts.saveDraft(
      noteId: note.id,
      accountId: 'owner-a',
      runId: 'run-1',
      downloadId: 'download-1',
      modelVersion: 'model-v1',
      platform: 'linux',
      language: 'en',
      schemaVersion: 1,
      selectedSourceItemIds: const ['s2'],
      selectedInkDocument: original.toJson(),
      sourceRevision: note.revision,
      sourceRevisionId: sourceRevisionId,
      passages: [
        TranscriptionPassage(
          partId: 's2',
          sourceItemIds: const ['s2'],
          sourceHash: 'source-item-hash',
          y: 1,
          x: 1,
          kind: TranscriptionPassageKind.text,
          text: 'saved result',
        ),
      ],
    );
    final client = MockClient((_) async => throw StateError('unexpected API'));
    addTearDown(client.close);
    Future<TranscriptionSession?> sessionProvider() async =>
        const TranscriptionSession(
          accountId: 'owner-a',
          readHeaders: {},
          mutationHeaders: {},
          isCurrent: _current,
        );
    final workflow = _workflow(directory, client, drafts, sessionProvider);
    final store = _ReadOnlyStore(note);
    final preferences = Preferences();
    addTearDown(preferences.dispose);

    await tester.pumpWidget(
      AppScope(
        preferences: preferences,
        service: AnnotationsService(api: ApiAdapter(client: client)),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: appTheme(Brightness.light),
          home: TranscriptionReviewPage(
            note: note,
            access: TranscriptionReviewAccess(
              workflow: workflow,
              runtime: _UnusedRuntime(),
              platform: 'linux',
            ),
            store: store,
            ownerAccountId: 'owner-a',
            isOwnerScopeCurrent: () => true,
          ),
        ),
      ),
    );
    for (var frame = 0; frame < 10; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.byKey(const Key('transcription-draft-saved')), findsOneWidget);
    expect(find.byKey(const Key('transcription-source-changed')), findsNothing);
    expect(find.byKey(const Key('transcription-passage-s2')), findsOneWidget);
    expect(
      drafts.reopenDraft(note.id, accountId: 'owner-a')!.needsReview,
      isFalse,
    );
    expect(store.saved, isEmpty);
    expect(item['id'], 's2');
  });

  testWidgets('the editor opens review for its selected Original unit', (
    tester,
  ) async {
    final directory = Directory(
      '/home/main-server/.cache/codex-impl-3/tmp/'
      'annotations48-transcription-review/widget-files/'
      '${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    final original = NoteDocument.fromJson({
      'page': {
        'width': 1000,
        'background': {'kind': 'blank'},
      },
      'items': [handwriting(3)],
    }, schema: DocumentSchema(DocumentFamily.original.schemaName, 1));
    final note = LocalNote(
      id: 'note-editor-entry',
      schema: original.schema,
      document: original,
      title: 'Editor fixture',
      revision: 1,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      syncState: LocalSyncState.local,
      accountId: 'owner-a',
    );
    final store = _ReadOnlyStore(note);
    final client = MockClient((_) async => throw StateError('unexpected API'));
    addTearDown(client.close);
    final installed = _TestInstalledAccount(
      const NativeSession(
        sessionId: 'session-a',
        csrfToken: 'csrf-a',
        verifiedUserId: 'owner-a',
      ),
      client,
    );
    final workspace = LocalWorkspace(
      store: store,
      catalog: ProjectTagCatalog(),
      profile: PlatformProfile.fullWriter,
    );
    final preferences = Preferences();
    addTearDown(preferences.dispose);
    final workflow = _workflow(
      directory,
      client,
      TranscriptionDraftService(),
      () async => null,
    );
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      AppScope(
        preferences: preferences,
        service: AnnotationsService(api: ApiAdapter(client: client)),
        workspace: workspace,
        installed: installed,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: appTheme(Brightness.light),
          home: NoteEditorPage(
            noteId: note.id,
            transcriptionReviewForTesting: TranscriptionReviewAccess(
              workflow: workflow,
              runtime: _UnusedRuntime(),
              platform: 'linux',
            ),
          ),
        ),
      ),
    );
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final entry = find.byKey(const Key('editor-convert-handwriting'));
    expect(entry, findsOneWidget);
    final editorHandler = tester
        .widget<PaperScreen>(find.byType(PaperScreen))
        .handler;
    editorHandler.selection.value = ObjectSelection(['s3']);
    editorHandler.autosave.edited(
      LocalNoteDraft(
        id: note.id,
        schema: note.schema,
        document: note.document,
        title: note.title,
        accountId: note.accountId,
      ),
    );
    await tester.runAsync(() => editorHandler.autosave.flush());
    expect(editorHandler.autosave.state.value, SaveState.failed);
    final loadsBeforeFailedEntry = store.loadCalls;

    await tester.tap(entry);
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // The failed retry must not load an older snapshot or admit the review.
    expect(store.loadCalls, loadsBeforeFailedEntry);
    expect(find.byKey(const Key('transcription-cancel')), findsNothing);

    store.failSaves = false;
    await tester.tap(entry);
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.byKey(const Key('transcription-cancel')), findsOneWidget);
    expect(find.byKey(const Key('transcription-source-s3')), findsOneWidget);
    expect(find.byKey(const Key('transcription-source-s1')), findsNothing);
    await tester.tap(find.byKey(const Key('transcription-cancel')));
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byKey(const Key('editor-convert-handwriting')), findsOneWidget);
    expect(store.saved, hasLength(3));
    expect(store.saved.last.document.toJson(), original.toJson());

    await tester.pumpWidget(
      AppScope(
        preferences: preferences,
        service: AnnotationsService(api: ApiAdapter(client: client)),
        workspace: workspace,
        installed: installed,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: appTheme(Brightness.light),
          home: const NoteEditorPage(noteId: 'note-editor-entry'),
        ),
      ),
    );
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byKey(const Key('editor-convert-handwriting')), findsNothing);
  });
}

bool _current() => true;

TranscriptionWorkflowService _workflow(
  Directory directory,
  http.Client client,
  TranscriptionDraftService drafts,
  TranscriptionSessionProvider sessionProvider,
) {
  final api = TranscriptionApiAdapter(
    ApiAdapter(client: client, base: 'https://api.test'),
  );
  return TranscriptionWorkflowService(
    downloads: ModelDownloadService(
      api: api,
      store: DirectoryModelArtifactStore(directory),
      sessionProvider: sessionProvider,
      enabled: false,
    ),
    runs: TranscriptionRunService(
      api: api,
      sessionProvider: sessionProvider,
      pendingResults: FilePendingTranscriptionResults(
        File('${directory.path}/results.json'),
      ),
      pendingFeedback: FilePendingTranscriptionFeedbackStore(
        File('${directory.path}/feedback.json'),
      ),
      enabled: false,
    ),
    drafts: drafts,
    sessionProvider: sessionProvider,
    decodePassages: (_, _) => const [],
  );
}

final class _ReadOnlyStore implements LocalNoteStore {
  _ReadOnlyStore(this.note);

  final LocalNote note;
  final List<LocalNoteDraft> saved = [];
  bool failSaves = true;
  int loadCalls = 0;

  @override
  Future<LocalNote?> load(String id) async {
    loadCalls++;
    return id == note.id ? note : null;
  }

  @override
  Future<LocalNote> save(LocalNoteDraft draft) async {
    saved.add(draft);
    if (failSaves) {
      throw StateError('This fixture intentionally fails the first save.');
    }
    return note;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _UnusedRuntime implements TranscriptionRuntime {
  @override
  Future<LocalRecognitionResult> recognize({
    required File modelFile,
    required Map<String, Object?> selectedInkDocument,
    required String language,
    required void Function(String stage) onStage,
  }) => throw StateError('The cancel-only fixture must not run recognition.');
}

final class _TestInstalledAccount extends InstalledAccount {
  _TestInstalledAccount(NativeSession session, http.Client client)
    : _session = session,
      super(
        auth: NativeAuthService(
          client: client,
          storage: InMemorySecureSessionStorage(),
        ),
        client: client,
        platform: 'linux',
        open: (_) async {},
        aes: aesCbcEncrypt,
        appContextKey: 'test-only-key',
      );

  final NativeSession _session;

  @override
  NativeSession? get activeSession => _session;

  @override
  bool get signedIn => true;

  @override
  String get userId => _session.verifiedUserId!;

  @override
  String? get localOwnerId => _session.verifiedUserId;
}
