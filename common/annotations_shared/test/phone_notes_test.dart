// annotations#35: phones write simple typed notes and read everything else
// without changing it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:annotations_shared/core/platform_profile.dart';
import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/note_views.dart';
import 'package:annotations_shared/domain/services/quiz_card_service.dart';
import 'package:annotations_shared/domain/services/reports_embed_source.dart';
import 'package:annotations_shared/domain/services/task_card_service.dart';
import 'package:annotations_shared/dal/remote/reports_api_adapter.dart';
import 'package:annotations_shared/presentation/frontend/handlers/paper_handler.dart';
import 'package:annotations_shared/presentation/frontend/handlers/typed_note_handler.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show ChangeSource, QuillEditor;
import 'package:annotations_shared/presentation/frontend/widgets/typed/note_screen.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'attachment_fixtures.dart';
import 'design_goldens_test.dart' show loadAppFonts;
import 'paper_canvas_test.dart' show host, phone, setWindow, studyNote;
import 'package:annotations_shared/domain/services/note_autosave.dart';
import 'package:annotations_shared/core/local_store_settings.dart';

final typed = DocumentSchema('note-typed', 1);

NoteDocument simpleTyped() => NoteDocument.fromJson({
  'blocks': [
    {
      'id': 'h1',
      'kind': 'heading',
      'level': 1,
      'spans': [
        {'text': 'Photosynthesis'},
      ],
    },
    {
      'id': 'p1',
      'kind': 'paragraph',
      'spans': [
        {'text': 'Plants make sugar.'},
      ],
    },
  ],
}, schema: typed);

NoteDocument complexTyped() => NoteDocument.fromJson({
  'blocks': [
    ...(simpleTyped().toJson()['blocks'] as List),
    {
      'id': 't1',
      'kind': 'table',
      'header': true,
      'rows': [
        {
          'cells': [
            {
              'spans': [
                {'text': 'Plant'},
              ],
            },
          ],
        },
        {
          'cells': [
            {
              'spans': [
                {'text': 'Bean'},
              ],
            },
          ],
        },
      ],
    },
    {
      'id': 'c1',
      'kind': 'link_card',
      'url': 'https://example.org/a',
      'title': 'A source',
    },
  ],
}, schema: typed);

void main() {
  setUpAll(loadAppFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the view of each note on each device', () {
    final paper = studyNote();
    expect(noteViewFor(PlatformProfile.fullWriter, paper), NoteView.paper);
    expect(noteViewFor(PlatformProfile.phone, paper), NoteView.readOnly);
    expect(noteViewFor(PlatformProfile.browser, paper), NoteView.readOnly);
    expect(noteViewFor(PlatformProfile.phone, simpleTyped()), NoteView.typed);
    expect(
      noteViewFor(PlatformProfile.phone, complexTyped()),
      NoteView.readOnly,
    );
    // Android tablets and iPads are full writers (annotations#16).
    expect(
      resolvePlatformProfile(
        isWeb: false,
        platform: TargetPlatform.android,
        shortestSideDp: 800,
      ),
      PlatformProfile.fullWriter,
    );
    expect(
      resolvePlatformProfile(
        isWeb: false,
        platform: TargetPlatform.iOS,
        isPad: true,
      ),
      PlatformProfile.fullWriter,
    );
  });

  late FileStore store;
  PaperHandler handlerFor(NoteDocument d, {String? title}) {
    store = FileStore();
    return PaperHandler(
      noteId: 'n1',
      document: d,
      title: title,
      autosave: NoteAutosave(
        store,
        settings: const LocalStoreSettings(
          autosaveDelay: Duration(milliseconds: 20),
        ),
      ),
    );
  }

  for (final (name, make) in [
    ('a paper note with ink, layout and cards', studyNote),
    ('a typed note with a table and a card', complexTyped),
  ]) {
    testWidgets('$name opens read-only on a phone and closes byte for byte '
        'unchanged', (tester) async {
      await setWindow(tester, phone);
      final document = make();
      final before = utf8.encode(jsonEncode(document.toJson()));
      final h = handlerFor(document, title: 'Study');
      addTearDown(h.dispose);
      await tester.pumpWidget(
        host(NoteScreen(handler: h, profile: PlatformProfile.phone)),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('paper-toolbar')), findsNothing);
      expect(find.byKey(const Key('typed-editor')), findsNothing);
      // Taps, a pen, keys and scrolling change nothing.
      for (final at in [const Offset(100, 200), const Offset(300, 500)]) {
        await tester.tapAt(at);
        await tester.pump(const Duration(milliseconds: 50));
      }
      final pen = await tester.startGesture(
        const Offset(120, 300),
        kind: PointerDeviceKind.stylus,
      );
      await pen.moveBy(const Offset(80, 20));
      await pen.up();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.drag(find.byType(MaterialApp), const Offset(0, -200));
      await tester.pumpAndSettle();
      await h.close();
      expect(store.saved, isEmpty);
      expect(utf8.encode(jsonEncode(h.document.toJson())), before);
    });
  }

  testWidgets('read-only phone reader loads the saved owner quiz card', (
    tester,
  ) async {
    await setWindow(tester, phone);
    final document = NoteDocument.fromJson({
      'page': {
        'width': 1000,
        'background': {'kind': 'blank'},
      },
      'items': [
        {
          'id': 'report-card',
          'kind': 'reports_embed',
          'x': 40,
          'y': 20,
          'width': 900,
          'height': 800,
          'report_id': 'monthly',
          'project_slug': 'public',
          'report_slug': 'monthly',
          'dataset_id': 'monthly',
          'mode': 'live',
          'source': 'link',
        },
        {
          'id': 'task-card',
          'kind': 'task_card',
          'x': 40,
          'y': 850,
          'width': 900,
          'height': 140,
          'task_id': 'task-1',
        },
        {
          'id': 'quiz-card',
          'kind': 'quiz_card',
          'x': 40,
          'y': 1050,
          'width': 900,
          'height': 140,
          'quiz_id': 'quiz-saved-1',
        },
      ],
    }, schema: DocumentSchema('note-original', 1));
    final handler = handlerFor(document, title: 'Saved quiz');
    addTearDown(handler.dispose);
    var requests = 0;
    var reportViewRequests = 0;
    var taskRequests = 0;
    final reportsSource = ReportsEmbedSource(
      api: ReportsApiAdapter(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/me')) {
            return http.Response(jsonEncode({'user_id': 'owner-1'}), 200);
          }
          if (request.url.path.contains('/reports/monthly')) {
            reportViewRequests++;
          }
          return http.Response('{}', 500);
        }),
        headersProvider: ({required mutation}) async => const {
          'cookie': 'session=fixture',
        },
      ),
    );
    await tester.pumpWidget(
      host(
        NoteScreen(
          handler: handler,
          profile: PlatformProfile.phone,
          reportsSource: reportsSource,
          trustedReportsAccountId: 'owner-1',
          loadTaskCard: (taskId) async {
            taskRequests++;
            expect(taskId, 'task-1');
            return const TaskSummary(
              taskId: 'task-1',
              title: 'Paper owner task title',
              completed: false,
            );
          },
          loadQuizCard: (quizId) async {
            requests++;
            expect(quizId, 'quiz-saved-1');
            return const QuizSummary(
              quizId: 'quiz-saved-1',
              title: 'Owner quiz title',
              questionCount: 0,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(reportViewRequests, 1);
    expect(taskRequests, 1);
    expect(find.text('Paper owner task title'), findsOneWidget);
    expect(find.byKey(const Key('reports-retry')), findsOneWidget);
    expect(find.text('Owner quiz title'), findsOneWidget);
    expect(find.text('0 questions'), findsOneWidget);
    expect(find.byKey(const Key('quiz-card-open')), findsOneWidget);

    final typedDocument = NoteDocument.fromJson({
      'blocks': [
        {
          'id': 'typed-quiz-card',
          'kind': 'quiz_card',
          'width': 320,
          'height': 140,
          'quiz_id': 'quiz-saved-1',
        },
      ],
    }, schema: DocumentSchema('note-typed', 1));
    final typedHandler = handlerFor(typedDocument, title: 'Typed saved quiz');
    addTearDown(typedHandler.dispose);
    await tester.pumpWidget(
      host(
        NoteScreen(
          handler: typedHandler,
          profile: PlatformProfile.phone,
          loadQuizCard: (quizId) async => const QuizSummary(
            quizId: 'quiz-saved-1',
            title: 'Typed owner quiz title',
            questionCount: null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Typed owner quiz title'), findsOneWidget);
    expect(find.text('Question count unavailable'), findsOneWidget);
  });

  testWidgets('read-only typed note loads its owner Reports and task cards', (
    tester,
  ) async {
    await setWindow(tester, phone);
    var reportViewRequests = 0;
    final source = ReportsEmbedSource(
      api: ReportsApiAdapter(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/me')) {
            return http.Response(jsonEncode({'user_id': 'owner-1'}), 200);
          }
          if (request.url.path.contains('/reports/monthly')) {
            reportViewRequests++;
          }
          return http.Response('{}', 500);
        }),
        headersProvider: ({required mutation}) async => const {
          'cookie': 'session=fixture',
        },
      ),
    );
    final document = NoteDocument.fromJson({
      'blocks': [
        {
          'id': 'typed-report',
          'kind': 'reports_embed',
          'report_id': 'monthly',
          'project_slug': 'public',
          'report_slug': 'monthly',
          'dataset_id': 'monthly',
          'mode': 'live',
          'source': 'link',
        },
        {'id': 'typed-task', 'kind': 'task_card', 'task_id': 'task-1'},
      ],
    }, schema: typed);
    final handler = handlerFor(document, title: 'Typed owner cards');
    addTearDown(handler.dispose);
    var taskRequests = 0;
    await tester.pumpWidget(
      host(
        NoteScreen(
          handler: handler,
          profile: PlatformProfile.phone,
          reportsSource: source,
          trustedReportsAccountId: 'owner-1',
          loadTaskCard: (taskId) async {
            taskRequests++;
            expect(taskId, 'task-1');
            return const TaskSummary(
              taskId: 'task-1',
              title: 'Owner task title',
              completed: false,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(reportViewRequests, 1);
    expect(taskRequests, 1);
    expect(find.byKey(const Key('reports-retry')), findsOneWidget);
    expect(find.text('Owner task title'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
  });

  testWidgets('public typed reader never requests private card summaries', (
    tester,
  ) async {
    await setWindow(tester, phone);
    var apiRequests = 0;
    var taskReads = 0;
    var quizReads = 0;
    final source = ReportsEmbedSource(
      api: ReportsApiAdapter(
        client: MockClient((_) async {
          apiRequests++;
          return http.Response('{}', 500);
        }),
        headersProvider: ({required mutation}) async => const {
          'cookie': 'session=fixture',
        },
      ),
    );
    final document = NoteDocument.fromJson({
      'blocks': [
        {
          'id': 'public-report',
          'kind': 'reports_embed',
          'report_id': 'monthly',
          'project_slug': 'private-project',
          'report_slug': 'monthly',
          'dataset_id': 'monthly',
          'mode': 'live',
          'source': 'link',
        },
        {'id': 'public-task', 'kind': 'task_card', 'task_id': 'task-1'},
        {
          'id': 'public-quiz',
          'kind': 'quiz_card',
          'quiz_id': 'quiz-1',
          'study_id': 'study-1',
        },
      ],
    }, schema: typed);
    final handler = handlerFor(document, title: 'Public note');
    addTearDown(handler.dispose);
    await tester.pumpWidget(
      host(
        NoteReader(
          handler: handler,
          publicProjection: true,
          reportsSource: source,
          trustedReportsAccountId: 'owner-1',
          loadTaskCard: (_) async {
            taskReads++;
            return const TaskSummary(
              taskId: 'task-1',
              title: 'PRIVATE TASK TITLE',
              completed: false,
            );
          },
          loadQuizCard: (_) async {
            quizReads++;
            return const QuizSummary(
              quizId: 'quiz-1',
              title: 'PRIVATE QUIZ TITLE',
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(apiRequests, 0);
    expect(taskReads, 0);
    expect(quizReads, 0);
    expect(find.byKey(const Key('locked-public-report')), findsOneWidget);
    expect(find.byKey(const Key('locked-public-task')), findsOneWidget);
    expect(find.byKey(const Key('locked-public-quiz')), findsOneWidget);
    expect(find.text('PRIVATE TASK TITLE'), findsNothing);
    expect(find.text('PRIVATE QUIZ TITLE'), findsNothing);
  });

  testWidgets('typed Reports card reloads when its reference changes', (
    tester,
  ) async {
    await setWindow(tester, phone);
    final oldResponse = Completer<http.Response>();
    final oldRequestStarted = Completer<void>();
    final paths = <String>[];
    final source = ReportsEmbedSource(
      api: ReportsApiAdapter(
        client: MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path.endsWith('/me')) {
            return http.Response(jsonEncode({'user_id': 'owner-1'}), 200);
          }
          if (request.url.path.endsWith('/reports/old-report')) {
            if (!oldRequestStarted.isCompleted) oldRequestStarted.complete();
            return oldResponse.future;
          }
          if (request.url.path.endsWith('/reports/new-report')) {
            return http.Response('', 403);
          }
          fail('Unexpected Reports request: ${request.url.path}');
        }),
        headersProvider: ({required mutation}) async => const {
          'cookie': 'session=fixture',
        },
      ),
    );
    NoteDocument reportDocument(String report) => NoteDocument.fromJson({
      'blocks': [
        {
          'id': 'same-card-id',
          'kind': 'reports_embed',
          'report_id': report,
          'project_slug': 'public',
          'report_slug': report,
          'dataset_id': 'monthly',
          'mode': 'live',
          'source': 'link',
        },
      ],
    }, schema: typed);
    final firstHandler = handlerFor(
      reportDocument('old-report'),
      title: 'Report reference update',
    );
    final secondHandler = handlerFor(
      reportDocument('new-report'),
      title: 'Report reference update',
    );
    addTearDown(firstHandler.dispose);
    addTearDown(secondHandler.dispose);

    Widget reader(PaperHandler handler) => host(
      NoteReader(
        key: const Key('stable-reader'),
        handler: handler,
        reportsSource: source,
        trustedReportsAccountId: 'owner-1',
      ),
    );

    await tester.pumpWidget(reader(firstHandler));
    await oldRequestStarted.future;
    await tester.pumpWidget(reader(secondHandler));
    await tester.pumpAndSettle();
    expect(
      paths,
      contains('/apps/reports/v1/projects/public/reports/new-report'),
    );
    expect(find.text('This report is restricted.'), findsOneWidget);

    oldResponse.complete(
      http.Response(
        jsonEncode({
          'project': 'public',
          'report': 'old-report',
          'title': 'Stale old report',
          'updated_at': '2026-11-24T00:00:00Z',
          'datasets': [
            {
              'dataset_id': 'monthly',
              'title': 'Monthly',
              'can_view': true,
              'fields': [
                {'name': 'month', 'type': 'string', 'role': 'dimension'},
                {'name': 'sales', 'type': 'integer', 'role': 'measure'},
              ],
            },
          ],
        }),
        200,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('This report is restricted.'), findsOneWidget);
    expect(find.text('Stale old report'), findsNothing);
  });

  testWidgets('the typed editor: text, styles, Undo, the title; opening '
      'alone saves nothing', (tester) async {
    await setWindow(tester, phone);
    final h = handlerFor(simpleTyped(), title: 'Biology');
    addTearDown(h.dispose);
    await tester.pumpWidget(
      host(NoteScreen(handler: h, profile: PlatformProfile.phone)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('typed-editor')), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(store.saved, isEmpty);
    // Type at the end of the paragraph.
    await tester.tap(find.byKey(const Key('typed-editor')));
    await tester.pump();
    final state = tester.state<State<StatefulWidget>>(
      find.byType(TypedNoteEditor),
    );
    final editor = (state as dynamic).typed;
    final c = editor.controller;
    c.updateSelection(
      TextSelection.collapsed(offset: c.document.length - 1),
      ChangeSource.local,
    );
    c.replaceText(c.document.length - 1, 0, '\nLight', null);
    await tester.pump(const Duration(milliseconds: 600));
    final blocks = (h.document as TypedDocument).blocks;
    expect(blocks, hasLength(3));
    expect(blocks.last.toJson()['spans'], [
      {'text': 'Light'},
    ]);
    // The new line as a bulleted list, then bold.
    c.updateSelection(
      TextSelection.collapsed(offset: c.document.length - 2),
      ChangeSource.local,
    );
    editor.setLineStyle(TypedLineStyle.bullets);
    await tester.pump(const Duration(milliseconds: 600));
    expect((h.document as TypedDocument).blocks.last.toJson()['kind'], 'list');
    // Undo brings the paragraph back; the editor follows.
    h.undo();
    await tester.pump();
    expect(
      (h.document as TypedDocument).blocks.last.toJson()['kind'],
      'paragraph',
    );
    // The title.
    await tester.enterText(find.byKey(const Key('typed-title')), 'Plants');
    await tester.pump(const Duration(milliseconds: 100));
    expect(h.title, 'Plants');
    await h.close();
    expect(store.saved.last.title, 'Plants');
    expect(store.saved.last.document is TypedDocument, isTrue);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('title then body input keeps body focus through editor rebuild', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await setWindow(tester, phone);
      final h = handlerFor(simpleTyped(), title: 'Biology');
      addTearDown(h.dispose);
      await tester.pumpWidget(
        host(NoteScreen(handler: h, profile: PlatformProfile.phone)),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('typed-title')), 'Plants');
      await tester.pump();
      expect(h.title, 'Plants');

      final before = tester.widget<QuillEditor>(
        find.byKey(const Key('typed-editor')),
      );
      final focus = before.focusNode;
      final scroll = before.scrollController;
      final editorRect = tester.getRect(find.byKey(const Key('typed-editor')));
      await tester.tapAt(editorRect.topLeft + const Offset(60, 25));
      await tester.pump();

      final afterTap = tester.widget<QuillEditor>(
        find.byKey(const Key('typed-editor')),
      );
      expect(identical(afterTap.focusNode, focus), isTrue);
      expect(identical(afterTap.scrollController, scroll), isTrue);
      expect(focus.hasFocus, isTrue);

      final state = tester.state<State<StatefulWidget>>(
        find.byType(TypedNoteEditor),
      );
      final editor = (state as dynamic).typed;
      final beforeText = editor.controller.document.toPlainText() as String;
      final caret = beforeText.length - 1;
      const bodyInput = 'Body input';
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: '${beforeText.substring(0, caret)}$bodyInput\n',
          selection: TextSelection.collapsed(offset: caret + bodyInput.length),
        ),
      );
      await tester.pump();

      final afterInput = tester.widget<QuillEditor>(
        find.byKey(const Key('typed-editor')),
      );
      expect(identical(afterInput.focusNode, focus), isTrue);
      expect(identical(afterInput.scrollController, scroll), isTrue);
      expect(focus.hasFocus, isTrue);
      expect(editor.controller.document.toPlainText(), contains(bodyInput));
      expect(
        editor.controller.selection.extentOffset,
        caret + bodyInput.length,
      );
      expect(h.title, 'Plants');

      final englishText = editor.controller.document.toPlainText() as String;
      final portugueseCaret = englishText.length - 1;
      const portugueseInput = ' ação';
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text:
              '${englishText.substring(0, portugueseCaret)}$portugueseInput\n',
          selection: TextSelection.collapsed(
            offset: portugueseCaret + portugueseInput.length,
          ),
        ),
      );
      await tester.pump();
      expect(editor.controller.document.toPlainText(), contains('ação'));
      expect(
        editor.controller.selection.extentOffset,
        portugueseCaret + portugueseInput.length,
      );
      expect(
        identical(
          tester
              .widget<QuillEditor>(find.byKey(const Key('typed-editor')))
              .focusNode,
          focus,
        ),
        isTrue,
      );
      expect(focus.hasFocus, isTrue);
      expect(h.title, 'Plants');

      final committedText = editor.controller.document.toPlainText() as String;
      final thaiCaret = committedText.length - 1;
      const thaiComposition = 'กี่';
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: '${committedText.substring(0, thaiCaret)}$thaiComposition\n',
          selection: TextSelection.collapsed(
            offset: thaiCaret + thaiComposition.length,
          ),
          composing: TextRange(
            start: thaiCaret,
            end: thaiCaret + thaiComposition.length,
          ),
        ),
      );
      await tester.pump();
      final afterComposition = tester.widget<QuillEditor>(
        find.byKey(const Key('typed-editor')),
      );
      expect(identical(afterComposition.focusNode, focus), isTrue);
      expect(identical(afterComposition.scrollController, scroll), isTrue);
      expect(focus.hasFocus, isTrue);
      expect(
        editor.controller.document.toPlainText(),
        contains(thaiComposition),
      );
      expect(
        editor.controller.selection.extentOffset,
        thaiCaret + thaiComposition.length,
      );
      expect(h.title, 'Plants');
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: '${committedText.substring(0, thaiCaret)}$thaiComposition\n',
          selection: TextSelection.collapsed(
            offset: thaiCaret + thaiComposition.length,
          ),
        ),
      );
      await tester.pump();
      await h.close();
      await tester.pump(const Duration(seconds: 1));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  final review = Platform.environment['ANNOTATIONS_REVIEW_DIR'];
  for (final (mode, brightness) in const [
    ('light', Brightness.light),
    ('dark', Brightness.dark),
  ]) {
    testWidgets('review images, $mode', skip: review == null, (tester) async {
      Future<void> shot(String name) => expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('$review/phone_${name}_$mode.png'),
      );
      await setWindow(tester, phone);
      for (final (name, make) in [
        ('typed_editor', simpleTyped),
        ('read_only_typed', complexTyped),
        ('read_only_paper', studyNote),
      ]) {
        final h = handlerFor(make(), title: 'Photosynthesis');
        await tester.pumpWidget(
          host(
            NoteScreen(
              key: ValueKey(name),
              handler: h,
              profile: PlatformProfile.phone,
            ),
            brightness: brightness,
          ),
        );
        await tester.pumpAndSettle();
        await shot(name);
        if (name == 'typed_editor') {
          await tester.tap(find.byKey(const Key('typed-line-style')));
          await tester.pumpAndSettle();
          await shot('line_styles');
          await tester.tapAt(const Offset(200, 700));
          await tester.pumpAndSettle();
        }
        await tester.pumpWidget(const SizedBox());
        h.dispose();
        await tester.pump(const Duration(seconds: 1));
      }
    });
  }
}
