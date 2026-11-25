import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:annotations_shared/core/platform_profile.dart';
import 'package:annotations_shared/dal/local/sqlite_note_store.dart';
import 'package:annotations_shared/dal/remote/aes_cbc.dart';
import 'package:annotations_shared/dal/remote/api_adapter.dart';
import 'package:annotations_shared/domain/models/local_note.dart';
import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/annotations_service.dart';
import 'package:annotations_shared/domain/services/installed_account.dart';
import 'package:annotations_shared/domain/services/local_workspace.dart';
import 'package:annotations_shared/domain/services/native_auth_service.dart';
import 'package:annotations_shared/domain/services/note_sync_service.dart';
import 'package:annotations_shared/domain/services/preferences.dart';
import 'package:annotations_shared/presentation/frontend/components/scope.dart';
import 'package:annotations_shared/presentation/frontend/widgets/workspace/note_editor_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'design_goldens_test.dart' show loadAppFonts;

Future<void> pumpEditorFrames(WidgetTester tester) async {
  for (var frame = 0; frame < 12; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

class SwitchableInstalledAccount extends InstalledAccount {
  SwitchableInstalledAccount(NativeSession session, http.Client client)
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

  NativeSession? _session;

  @override
  NativeSession? get activeSession => _session;

  @override
  bool get signedIn => _session != null;

  @override
  String? get localOwnerId => _session?.verifiedUserId;

  void switchTo(NativeSession? session) {
    _session = session;
    notifyListeners();
  }
}

void main() {
  setUpAll(loadAppFonts);

  testWidgets(
    'account switch during source catalog read stops the prepared quiz flow',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      late Directory root;
      late SqliteNoteStore store;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('prepared_race_');
        store = await SqliteNoteStore.open(root.path);
      });
      addTearDown(() async {
        await store.close();
        await root.delete(recursive: true);
      });

      final schema = DocumentSchema('note-original', 1);
      await tester.runAsync(
        () => store.save(
          LocalNoteDraft(
            id: 'note-race',
            schema: schema,
            document: NoteDocument.fromJson({
              'page': {
                'width': 1000,
                'background': {'kind': 'blank'},
              },
              'items': [
                {
                  'id': 'text-1',
                  'kind': 'text',
                  'x': 0,
                  'y': 0,
                  'width': 300,
                  'height': 40,
                  'spans': [
                    {'text': 'Local note text'},
                  ],
                },
              ],
            }, schema: schema),
            title: 'Local note',
            accountId: 'account-a',
          ),
        ),
      );
      await tester.runAsync(
        () => store.setSync(
          'note-race',
          state: LocalSyncState.synced,
          accountId: 'account-a',
          serverNoteId: 'server-note-a',
          serverRevision: 1,
          serverOriginalRevisionId: 'original-revision-1',
        ),
      );
      final accountClient = MockClient((_) async => http.Response('{}', 200));
      addTearDown(accountClient.close);
      final account = SwitchableInstalledAccount(
        const NativeSession(
          sessionId: 'session-a',
          csrfToken: 'csrf-a',
          verifiedUserId: 'account-a',
        ),
        accountClient,
      );
      expect(account.signedIn, isTrue);

      final catalogStarted = Completer<void>();
      final releaseCatalog = Completer<http.Response>();
      final apiCalls = <String>[];
      final apiClient = MockClient((request) {
        apiCalls.add('${request.method} ${request.url.path}');
        if (request.method == 'GET' &&
            request.url.path == '/apps/annotations/v1/me/notes/server-note-a') {
          if (!catalogStarted.isCompleted) catalogStarted.complete();
          return releaseCatalog.future;
        }
        return Future.value(http.Response('{}', 404));
      });
      addTearDown(apiClient.close);
      final workspace = LocalWorkspace(
        store: store,
        catalog: ProjectTagCatalog(),
        profile: PlatformProfile.fullWriter,
      );
      final preferences = Preferences();
      addTearDown(preferences.dispose);

      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 900);
      addTearDown(tester.view.reset);
      await tester
          .pumpWidget(
            MaterialApp(
              home: AppScope(
                preferences: preferences,
                service: AnnotationsService(
                  api: ApiAdapter(
                    base: 'https://api.test/apps/annotations/v1',
                    client: apiClient,
                  ),
                ),
                workspace: workspace,
                installed: account,
                child: const NoteEditorPage(noteId: 'note-race'),
              ),
            ),
          )
          .timeout(const Duration(seconds: 5));

      await pumpEditorFrames(tester).timeout(const Duration(seconds: 5));

      expect(find.byKey(const Key('editor-prepare-quiz')), findsOneWidget);

      final prepareButton = find.byKey(const Key('editor-prepare-quiz'));
      final gesture = await tester.startGesture(
        tester.getCenter(prepareButton),
      );
      await gesture.up();
      await tester.pump();

      for (var frame = 0; frame < 12 && !catalogStarted.isCompleted; frame++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        catalogStarted.isCompleted,
        isTrue,
        reason: 'API calls: $apiCalls',
      );

      account.switchTo(
        const NativeSession(
          sessionId: 'session-b',
          csrfToken: 'csrf-b',
          verifiedUserId: 'account-b',
        ),
      );

      expect(account.activeSession?.verifiedUserId, 'account-b');
      releaseCatalog.complete(
        http.Response(
          jsonEncode({
            'note_id': 'server-note-a',
            'revision': 1,
            'title': 'Server note',
            'representations': [
              {
                'representation': 'original',
                'revision_id': 'original-revision-1',
                'document': {
                  'page': {
                    'width': 1000,
                    'background': {'kind': 'blank'},
                  },
                  'items': [
                    {
                      'kind': 'text',
                      'spans': [
                        {'text': 'Server note text'},
                      ],
                    },
                  ],
                },
              },
            ],
          }),
          200,
        ),
      );
      await pumpEditorFrames(tester).timeout(const Duration(seconds: 5));

      expect(find.byKey(const Key('quiz-source-note_original')), findsNothing);
      expect(apiCalls, ['GET /apps/annotations/v1/me/notes/server-note-a']);
      expect(account.activeSession?.verifiedUserId, 'account-b');
    },
  );
}
