import 'dart:io';

import 'package:annotations_shared/app.dart';
import 'package:annotations_shared/core/platform_profile.dart';
import 'package:annotations_shared/core/strings.dart';
import 'package:annotations_shared/dal/local/sqlite_note_store.dart';
import 'package:annotations_shared/domain/models/local_note.dart';
import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/local_workspace.dart';
import 'package:annotations_shared/domain/services/note_sync_service.dart';
import 'package:annotations_shared/presentation/frontend/handlers/workspace_handler.dart';
import 'package:annotations_shared/presentation/frontend/widgets/workspace/workspace_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'design_goldens_test.dart' show loadAppFonts;
import 'fixtures.dart';

/// annotations#38 stage 4: the installed first start and writer workspace.

late Directory root;
late SqliteNoteStore store;

String t(String key) => translate(key, 'en');

LocalWorkspace workspace({
  PlatformProfile profile = PlatformProfile.fullWriter,
}) => LocalWorkspace(
  store: store,
  catalog: ProjectTagCatalog(),
  profile: profile,
);

Future<void> openApp(
  WidgetTester tester,
  LocalWorkspace ws, {
  bool introSeen = true,
  double width = 1300,
  String? location,
}) async {
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  SharedPreferences.setMockInitialValues({});
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 1000);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    AnnotationsApp(
      key: UniqueKey(),
      trackingEnabled: false,
      service: fixtureService(),
      workspace: ws,
      introSeen: introSeen,
      initialLocation: location,
    ),
  );
  await settle(tester);
}

/// Lets the real SQLite store finish, then settles the frames.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }
}

String location(WidgetTester tester) => GoRouter.of(
  tester.element(find.byType(Navigator).last),
).state.uri.toString();

Future<LocalNote> saved(String id, String? title) => store.save(
  LocalNoteDraft(
    id: id,
    schema: DocumentSchema('note-typed', 1),
    document: NoteDocument.fromJson({
      'blocks': <Object>[],
    }, schema: DocumentSchema('note-typed', 1)),
    title: title,
  ),
);

void main() {
  setUpAll(loadAppFonts);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('workspace_');
    store = await SqliteNoteStore.open(root.path);
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });

  testWidgets('first start: at most three intro screens, then Notes', (
    tester,
  ) async {
    await openApp(tester, workspace(), introSeen: false);
    expect(location(tester), '/v1/welcome');
    var screens = 1;
    while (find.text(t('introStart')).evaluate().isEmpty) {
      await tester.tap(find.byKey(const Key('intro-next')));
      await tester.pumpAndSettle();
      screens++;
    }
    expect(screens, lessThanOrEqualTo(3));
    await tester.tap(find.byKey(const Key('intro-next')));
    await settle(tester);
    expect(location(tester), '/v1/write');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('annotations.intro_seen'), isTrue);
  });

  testWidgets('Skip leaves the intro at once', (tester) async {
    await openApp(tester, workspace(), introSeen: false);
    await tester.tap(find.byKey(const Key('intro-skip')));
    await settle(tester);
    expect(location(tester), '/v1/write');
  });

  testWidgets('installed start opens Notes with no browser landing', (
    tester,
  ) async {
    await openApp(tester, workspace());
    expect(location(tester), '/v1/write');
    expect(find.byKey(const Key('writer-bar')), findsOneWidget);
    expect(find.byKey(const Key('tab-tabOverview')), findsNothing);
    expect(find.byKey(const Key('workspace-empty')), findsOneWidget);
  });

  testWidgets('New note opens the editor; the list shows Untitled note', (
    tester,
  ) async {
    await openApp(tester, workspace());
    await tester.tap(find.byKey(const Key('workspace-new')));
    await settle(tester);
    expect(location(tester), startsWith('/v1/write/'));
    expect(find.byKey(const Key('editor-back')), findsOneWidget);
    await tester.tap(find.byKey(const Key('editor-back')));
    await settle(tester);
    expect(find.text(t('untitledNote')), findsOneWidget);
    expect(find.text(t('stateLocal')), findsOneWidget);
  });

  test('phones create typed notes, full writers paper notes', () async {
    for (final (profile, family) in [
      (PlatformProfile.phone, 'note-typed'),
      (PlatformProfile.fullWriter, 'note-original'),
    ]) {
      final id = await workspace(profile: profile).createNote();
      final note = (await store.load(id))!;
      expect(note.schema.name, family);
      expect(note.title, isNull);
    }
  });

  testWidgets('each note shows its sync state', (tester) async {
    await tester.runAsync(() async {
      await saved('a', 'Local');
      await saved('b', 'Synced');
      await store.setSync('b', state: LocalSyncState.synced, accountId: 'u1');
      await saved('c', 'Changed');
      await store.setSync('c', state: LocalSyncState.synced, accountId: 'u1');
      await saved('c', 'Changed');
    });
    await openApp(tester, workspace());
    Finder state(String id, String key) => find.descendant(
      of: find.byKey(Key('state-$id')),
      matching: find.text(t(key)),
    );
    expect(state('a', 'stateLocal'), findsOneWidget);
    expect(state('b', 'stateSynced'), findsOneWidget);
    expect(state('c', 'stateChanged'), findsOneWidget);
  });

  testWidgets('filters by project and by tag', (tester) async {
    final ws = workspace();
    await tester.runAsync(() async {
      await saved('a', 'Biology');
      await saved('b', 'History');
    });
    ws.catalog.createLocalProject('p1', 'School');
    ws.catalog.assignNoteToProject('a', 'p1');
    ws.catalog.addTag('b', 'exam');
    await openApp(tester, ws);
    expect(find.text('Biology'), findsOneWidget);
    expect(find.text('History'), findsOneWidget);
    await tester.tap(find.byKey(const Key('filter-project')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('filter-p1')));
    await settle(tester);
    expect(find.text('Biology'), findsOneWidget);
    expect(find.text('History'), findsNothing);
    await tester.tap(find.byKey(const Key('filter-project')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('filter-all')).last);
    await settle(tester);
    await tester.tap(find.byKey(const Key('filter-tag')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('filter-exam')));
    await settle(tester);
    expect(find.text('Biology'), findsNothing);
    expect(find.text('History'), findsOneWidget);
  });

  testWidgets('remove from this device asks first', (tester) async {
    await tester.runAsync(() => saved('a', 'Keep me'));
    await openApp(tester, workspace());
    Future<void> remove(String button) async {
      await tester.tap(find.byKey(const Key('actions-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('remove-a')));
      await tester.pumpAndSettle();
      expect(find.text(t('removeFromDeviceText')), findsOneWidget);
      await tester.tap(find.byKey(Key(button)));
      await settle(tester);
    }

    await remove('remove-cancel');
    expect(find.text('Keep me'), findsOneWidget);
    await remove('remove-confirm');
    expect(find.text('Keep me'), findsNothing);
    expect(await tester.runAsync(() => store.load('a')), isNull);
  });

  testWidgets('a backup exports to a file and restores as a note', (
    tester,
  ) async {
    await tester.runAsync(() => saved('a', 'Backed up'));
    final file = '${root.path}/backup.json';
    final handler = WorkspaceHandler(
      workspace(),
      saveLocation: (_) async => file,
      openBackup: () async => file,
    );
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.runAsync(handler.load);
    final note = handler.notes!.single;
    expect(await tester.runAsync(() => handler.exportBackup(note)), isTrue);
    expect(File(file).existsSync(), isTrue);
    expect(await tester.runAsync(handler.restoreBackup), isTrue);
    expect(handler.notes, hasLength(2));
    expect(handler.notes!.map((n) => n.title), everyElement('Backed up'));
    // A cancelled picker changes nothing.
    final cancelled = WorkspaceHandler(
      workspace(),
      saveLocation: (_) async => null,
      openBackup: () async => null,
    );
    expect(await tester.runAsync(() => cancelled.exportBackup(note)), isFalse);
    expect(await tester.runAsync(cancelled.restoreBackup), isFalse);
    expect(WorkspacePage, isNotNull);
  });

  testWidgets('a note gets a new project and a tag from its menu', (
    tester,
  ) async {
    final ws = workspace();
    await tester.runAsync(() => saved('a', 'Biology'));
    await openApp(tester, ws);
    await tester.tap(find.byKey(const Key('actions-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('project-a')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('new-project-name')), 'School');
    await tester.tap(find.byKey(const Key('project-save')));
    await settle(tester);
    expect(ws.catalog.projects.values, ['School']);
    expect(ws.catalog.projectForNote('a'), isNotNull);
    // The same name again is refused, not duplicated.
    await tester.tap(find.byKey(const Key('actions-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('project-a')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('new-project-name')), 'school');
    await tester.tap(find.byKey(const Key('project-save')));
    await tester.pumpAndSettle();
    expect(find.text(t('projectExists')), findsOneWidget);
    expect(ws.catalog.projects, hasLength(1));
    await tester.tap(find.text(t('cancel')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('actions-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tag-a')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('tag-name')), 'Exam');
    await tester.tap(find.byKey(const Key('tag-save')));
    await settle(tester);
    expect(ws.catalog.tagsForNote('a'), {'exam'});
    expect(find.textContaining('School'), findsWidgets);
    expect(find.textContaining('#exam'), findsOneWidget);
  });
}
