import 'dart:convert';
import 'dart:io';

import 'package:annotations_shared/app.dart';
import 'package:annotations_shared/core/strings.dart';
import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/discovery_reader_service.dart';
import 'package:annotations_shared/domain/services/note_autosave.dart';
import 'package:annotations_shared/domain/services/read_only_store.dart';
import 'package:annotations_shared/presentation/frontend/handlers/attachment_handler.dart';
import 'package:annotations_shared/presentation/frontend/handlers/paper_handler.dart';
import 'package:annotations_shared/presentation/frontend/widgets/typed/note_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'design_goldens_test.dart' show loadAppFonts;
import 'fixtures.dart';

/// annotations#40: public browsing, author and project pages and the reader,
/// against a fake that answers like annotations_api public routes.

String t(String key) => translate(key, 'en');

Map<String, Object?> summary(
  String id, {
  List<String> views = const ['original'],
}) => {
  'note_id': id,
  'author_id': 'a1',
  'author_name': 'Wilson',
  'title': 'Note $id',
  'summary': 'About $id',
  'language': 'en',
  'tags': ['biology'],
  'views': views,
  'default_view': views.first,
  'can_switch_view': views.length > 1,
  'typed_uses_earlier_revision': false,
  'published_at': 1794996000,
};

final original = {
  'page': {
    'width': 1000,
    'background': {'kind': 'ruled', 'spacing': 32, 'visibility': 0.5},
  },
  'items': [
    {
      'id': 't1',
      'kind': 'text',
      'x': 40,
      'y': 60,
      'width': 300,
      'height': 40,
      'spans': [
        {'text': 'Cell cycle'},
      ],
    },
    // The public projection of a Reports embed: no mode or source.
    {
      'id': 'r1',
      'kind': 'reports_embed',
      'x': 40,
      'y': 140,
      'width': 400,
      'height': 200,
      'report_id': 'rep1',
      'restricted': true,
    },
  ],
};

final typedDoc = {
  'blocks': [
    {
      'id': 'h',
      'kind': 'heading',
      'level': 1,
      'spans': [
        {'text': 'Cell cycle'},
      ],
    },
    {'id': 'k', 'kind': 'task_card', 'task_id': 'tk1', 'restricted': true},
  ],
};

class FakeApi {
  final requests = <Uri>[];
  final failOnceStatus = <String, int>{};
  final failOnceNetwork = <String>{};
  bool stale = false;
  bool includeProjectAuthorId = true;
  bool authorLookupFails = false;
  List<String> views = const ['original', 'typed'];

  http.Response json(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status);

  late final service = fixtureService(
    handler: (r) async {
      requests.add(r.url);
      final path = r.url.path;
      if (failOnceNetwork.remove(path)) {
        throw const SocketException('Connection refused');
      }
      final onceStatus = failOnceStatus.remove(path);
      if (onceStatus != null) {
        return json({'error': 'transient_$onceStatus'}, onceStatus);
      }
      final p = r.url.pathSegments;
      final q = r.url.queryParameters;
      if (path == '/notes') {
        if (q['cursor'] == 'c1') {
          return json({
            'items': [summary('n3')],
            'next_cursor': null,
            'browse_token': q['browse_token'],
          });
        }
        return json({
          'items': [
            summary('n1'),
            summary('n2', views: ['original', 'typed']),
          ],
          'next_cursor': 'c1',
          'browse_token': 'b1',
        });
      }
      if (p.length == 2 && p[0] == 'notes') {
        if (p[1] == 'missing') return json({'error': 'not_found'}, 404);
        final view = q['view'];
        return json({
          ...summary(p[1], views: views),
          'typed_uses_earlier_revision': stale,
          'representations': [
            if (view != 'typed' && views.contains('original'))
              {
                'representation': 'original',
                'schema_version': 1,
                'document': original,
              },
            if (view != 'original' && views.contains('typed'))
              {
                'representation': 'typed',
                'schema_version': 1,
                'document': typedDoc,
              },
          ],
        });
      }
      if (p.length == 2 && p[0] == 'authors') {
        if (p[1] == 'missing' || authorLookupFails) {
          return json({'error': 'not_found'}, 404);
        }
        return json({'author_id': p[1], 'name': 'Wilson'});
      }
      if (p.length == 3 && p[0] == 'authors' && p[2] == 'projects') {
        // Real annotations_api omits author_name from public project responses.
        return json({
          'items': [
            {
              'project_id': 'p1',
              'author_id': 'a1',
              'name': 'Biology',
              'note_count': 2,
            },
          ],
          'next_cursor': null,
        });
      }
      if (p.length == 2 && p[0] == 'projects') {
        if (p[1] == 'missing') return json({'error': 'not_found'}, 404);
        // Real annotations_api omits author_name from public project responses.
        return json({
          'project_id': p[1],
          if (includeProjectAuthorId) 'author_id': 'a1',
          'name': 'Biology',
          'note_count': 2,
        });
      }
      return json({'detail': 'Not Found'}, 404);
    },
  );
}

Future<void> open(
  WidgetTester tester,
  FakeApi api,
  String at, {
  double width = 1300,
  String locale = 'en',
  String theme = 'light',
}) async {
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  SharedPreferences.setMockInitialValues({
    'annotations.locale': locale,
    'annotations.theme': theme,
  });
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 1100);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    AnnotationsApp(
      key: UniqueKey(),
      trackingEnabled: false,
      service: api.service,
      initialLocation: at,
    ),
  );
  await tester.pumpAndSettle();
}

String location(WidgetTester tester) => GoRouter.of(
  tester.element(find.byType(Navigator).last),
).state.uri.toString();

void main() {
  setUpAll(loadAppFonts);

  group('Browse', () {
    testWidgets('filters go to GET /notes; results show their fields', (
      tester,
    ) async {
      final api = FakeApi();
      await open(
        tester,
        api,
        '/v1/menu?q=cell&tag=biology&author=a1&language=en&project=p1',
      );
      final q = api.requests
          .firstWhere((u) => u.path == '/notes')
          .queryParameters;
      expect(q['q'], 'cell');
      expect(q['tag'], 'biology');
      expect(q['author_id'], 'a1');
      expect(q['language'], 'en');
      expect(q['project_id'], 'p1');
      expect(find.text('Note n1'), findsOneWidget);
      expect(find.text('About n1'), findsOneWidget);
      expect(find.text('Wilson'), findsWidgets);
      expect(find.text('2026-11-18'), findsWidgets);
      expect(find.byKey(const Key('view-n2-typed')), findsOneWidget);
      expect(find.byKey(const Key('view-n1-typed')), findsNothing);
      expect(find.byKey(const Key('active-filterTag')), findsOneWidget);
    });

    testWidgets('a tag filters; clearing a filter removes it', (tester) async {
      final api = FakeApi();
      await open(tester, api, '/v1/menu');
      await tester.tap(find.byKey(const Key('tag-n1-biology')));
      await tester.pumpAndSettle();
      expect(location(tester), '/v1/menu?tag=biology');
      expect(api.requests.last.queryParameters['tag'], 'biology');
      tester
          .widget<InputChip>(find.byKey(const Key('active-filterTag')))
          .onDeleted!();
      await tester.pumpAndSettle();
      expect(location(tester), '/v1/menu');
    });

    testWidgets('Show more continues with the cursor and browse token', (
      tester,
    ) async {
      final api = FakeApi();
      await open(tester, api, '/v1/menu');
      await tester.ensureVisible(find.byKey(const Key('feed-more')));
      await tester.tap(find.byKey(const Key('feed-more')));
      await tester.pumpAndSettle();
      final last = api.requests.last.queryParameters;
      expect(last['cursor'], 'c1');
      expect(last['browse_token'], 'b1');
      expect(find.text('Note n3'), findsOneWidget);
      expect(find.byKey(const Key('feed-more')), findsNothing);
    });
  });

  testWidgets('author page lists projects; a project lists its notes', (
    tester,
  ) async {
    final api = FakeApi();
    await open(tester, api, '/v1/authors/a1');
    expect(find.byKey(const Key('author-name')), findsOneWidget);
    expect(
      api.requests.any((u) => u.queryParameters['author_id'] == 'a1'),
      isTrue,
    );
    await tester.tap(find.byKey(const Key('project-p1')));
    await tester.pumpAndSettle();
    expect(location(tester), '/v1/projects/p1');
    expect(find.byKey(const Key('project-name')), findsOneWidget);
    expect(api.requests.last.queryParameters['project_id'], 'p1');
  });

  group('Reader', () {
    testWidgets('Original keeps the paper; restricted cards keep a lock', (
      tester,
    ) async {
      final api = FakeApi()..views = ['original'];
      await open(tester, api, '/v1/notes/n1');
      expect(find.byKey(const Key('reader-original')), findsOneWidget);
      expect(tester.takeException(), isNull);
      // One view only: no switch.
      expect(find.byKey(const Key('reader-switch')), findsNothing);
      await expectLater(
        find.byKey(const Key('reader-original')),
        matchesGoldenFile('goldens/reader_original.png'),
      );
    });

    testWidgets(
      'tapping restricted cards in Original and Typed causes zero side effects or leaks',
      (tester) async {
        final api = FakeApi()..views = ['original', 'typed'];
        await open(tester, api, '/v1/notes/n1');
        final readerFinder = find.byKey(const Key('reader-original'));
        expect(readerFinder, findsOneWidget);
        final handler = tester.widget<NoteReader>(readerFinder).handler;
        final view = handler.view.value!;
        final cardCenter =
            tester.getTopLeft(readerFinder) +
            view.toScreen(const Offset(240, 240));
        final countBefore = api.requests.length;

        await tester.tapAt(cardCenter);
        await tester.pumpAndSettle();

        expect(api.requests.length, countBefore);
        expect(location(tester), '/v1/notes/n1');
        expect(find.textContaining('rep1'), findsNothing);
        expect(find.textContaining('tk1'), findsNothing);
        expect(find.byType(Dialog), findsNothing);
        expect(find.byType(SnackBar), findsNothing);

        await tester.tap(find.text(t('viewTyped')));
        await tester.pumpAndSettle();
        final countTyped = api.requests.length;
        expect(find.byKey(const Key('locked-k')), findsOneWidget);

        await tester.tap(find.byKey(const Key('locked-k')));
        await tester.pumpAndSettle();
        expect(api.requests.length, countTyped);
        expect(location(tester), '/v1/notes/n1?view=typed');
        expect(find.textContaining('tk1'), findsNothing);
        expect(find.byType(Dialog), findsNothing);
      },
    );

    testWidgets('the switch opens Typed, a formal page with the lock', (
      tester,
    ) async {
      final api = FakeApi()..stale = true;
      await open(tester, api, '/v1/notes/n1');
      expect(find.byKey(const Key('reader-switch')), findsOneWidget);
      expect(find.byKey(const Key('reader-stale')), findsNothing);
      await tester.tap(find.text(t('viewTyped')));
      await tester.pumpAndSettle();
      expect(location(tester), '/v1/notes/n1?view=typed');
      expect(api.requests.last.queryParameters['view'], 'typed');
      expect(find.byKey(const Key('typed-reader')), findsOneWidget);
      expect(find.byKey(const Key('locked-k')), findsOneWidget);
      expect(find.byKey(const Key('reader-stale')), findsOneWidget);
      // Reading width of the formal page.
      expect(
        tester.getSize(find.byKey(const Key('typed-reader'))).width,
        lessThanOrEqualTo(760),
      );
    });

    testWidgets(
      'genuine 404 renders S01 without Retry on note, author, and project pages',
      (tester) async {
        for (final route in [
          '/v1/notes/missing',
          '/v1/authors/missing',
          '/v1/projects/missing',
        ]) {
          final api = FakeApi();
          await open(tester, api, route);
          expect(find.byKey(const Key('image-S01')), findsOneWidget);
          expect(find.byKey(const Key('not-found')), findsOneWidget);
          expect(find.text(t('retry')), findsNothing);
        }
      },
    );

    testWidgets(
      'transient 503 and network failure show LoadError and Retry preserves route query',
      (tester) async {
        final noteApi = FakeApi()..failOnceStatus['/notes/n1'] = 503;
        await open(tester, noteApi, '/v1/notes/n1?view=typed');
        expect(find.byKey(const Key('reader-error')), findsOneWidget);
        expect(find.byKey(const Key('not-found')), findsNothing);
        await tester.tap(find.text(t('retry')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('typed-reader')), findsOneWidget);
        expect(
          noteApi.requests
              .where((u) => u.path == '/notes/n1')
              .map((u) => u.queryParameters['view']),
          ['typed', 'typed'],
        );

        final authorApi = FakeApi()..failOnceNetwork.add('/authors/a1');
        await open(tester, authorApi, '/v1/authors/a1');
        expect(find.byKey(const Key('author-error')), findsOneWidget);
        expect(find.byKey(const Key('not-found')), findsNothing);
        await tester.tap(find.text(t('retry')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('author-name')), findsOneWidget);

        final projectApi = FakeApi()..failOnceStatus['/projects/p1'] = 503;
        await open(tester, projectApi, '/v1/projects/p1');
        expect(find.byKey(const Key('project-error')), findsOneWidget);
        expect(find.byKey(const Key('not-found')), findsNothing);
        await tester.tap(find.text(t('retry')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('project-name')), findsOneWidget);
        expect(find.text('by Wilson'), findsOneWidget);
      },
    );

    testWidgets('readable on a phone', (tester) async {
      final api = FakeApi();
      await open(tester, api, '/v1/notes/n1?view=typed', width: 390);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('typed-reader')), findsOneWidget);
    });

    testWidgets(
      'browse, project, reader, and retry states fit in pt-BR and th without overflow',
      (tester) async {
        for (final locale in ['pt-BR', 'th']) {
          for (final width in [1280.0, 390.0]) {
            final api = FakeApi()..failOnceStatus['/notes/n1'] = 503;
            await open(
              tester,
              api,
              '/v1/projects/p1',
              width: width,
              locale: locale,
              theme: locale == 'th' ? 'dark' : 'light',
            );
            expect(tester.takeException(), isNull);
            expect(find.byKey(const Key('project-author')), findsOneWidget);

            await open(
              tester,
              api,
              '/v1/notes/n1?view=typed',
              width: width,
              locale: locale,
              theme: locale == 'th' ? 'dark' : 'light',
            );
            expect(tester.takeException(), isNull);
            expect(find.byKey(const Key('reader-error')), findsOneWidget);

            await tester.tap(find.text(translate('retry', locale)));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(find.byKey(const Key('typed-reader')), findsOneWidget);
          }
        }
      },
    );
  });

  testWidgets(
    'ProjectPage resolves author name via GET /authors/{id} and falls back cleanly',
    (tester) async {
      final api = FakeApi();
      await open(tester, api, '/v1/projects/p1');
      expect(api.requests.any((u) => u.path == '/authors/a1'), isTrue);
      expect(find.text('by Wilson'), findsOneWidget);
      await tester.tap(find.byKey(const Key('project-author')));
      await tester.pumpAndSettle();
      expect(location(tester), '/v1/authors/a1');

      final missingAuthorApi = FakeApi()..authorLookupFails = true;
      await open(tester, missingAuthorApi, '/v1/projects/p1');
      expect(find.text('by Author'), findsOneWidget);

      final noAuthorIdApi = FakeApi()..includeProjectAuthorId = false;
      await open(tester, noAuthorIdApi, '/v1/projects/p1');
      expect(
        noAuthorIdApi.requests.any((u) => u.path.startsWith('/authors/')),
        isFalse,
      );
      expect(find.text('by Author'), findsOneWidget);
    },
  );

  test(
    'AttachmentHandler.open refuses restricted cards before launching URLs or files',
    () async {
      final launched = <Uri>[];
      final doc = NoteDocument.fromJson({
        'page': {
          'width': 1000,
          'background': {'kind': 'ruled', 'spacing': 32, 'visibility': 0.5},
        },
        'items': [
          {
            'id': 'r1',
            'kind': 'reports_embed',
            'x': 10,
            'y': 10,
            'width': 100,
            'height': 80,
            'report_id': 'rep1',
            'mode': 'live',
            'source': 'reports',
            'restricted': true,
          },
          {
            'id': 'l1',
            'kind': 'link_card',
            'x': 10,
            'y': 120,
            'width': 100,
            'height': 80,
            'restricted': true,
            'url': 'https://example.invalid/secret',
          },
          {
            'id': 'f1',
            'kind': 'file_card',
            'x': 10,
            'y': 220,
            'width': 100,
            'height': 80,
            'restricted': true,
            'file_id': 'secret-file',
          },
        ],
      }, schema: DocumentSchema('note-original', 1));
      final paper = PaperHandler(
        noteId: 'n1',
        document: doc,
        autosave: NoteAutosave(const ReadOnlyNoteStore()),
      );
      final handler = AttachmentHandler(
        paper: paper,
        launch: (uri) async {
          launched.add(uri);
          return true;
        },
      );
      addTearDown(() {
        handler.dispose();
        paper.dispose();
      });
      expect(await handler.open('r1'), isFalse);
      expect(await handler.open('l1'), isFalse);
      expect(await handler.open('f1'), isFalse);
      expect(launched, isEmpty);
    },
  );

  test('the public projection keeps the paper geometry of every item', () {
    final readable = readablePublicDocument(original);
    final doc = NoteDocument.fromJson(
      readable,
      schema: DocumentSchema('note-original', 1),
    );
    final items = (doc.toJson()['items'] as List).cast<Map>();
    for (final (i, item) in items.indexed) {
      final source = (original['items'] as List)[i] as Map;
      for (final k in ['x', 'y', 'width', 'height']) {
        expect(item[k], source[k], reason: '${item['id']} $k');
      }
    }
    expect(items[1]['restricted'], isTrue);
    expect(items[1]['mode'], 'live');
    expect(items[1]['source'], 'reports');
  });
}
