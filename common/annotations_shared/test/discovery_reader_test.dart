import 'dart:convert';

import 'package:annotations_shared/dal/remote/api_adapter.dart';
import 'package:annotations_shared/domain/services/discovery_reader_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'public discovery search/browse forwards filters, deduplicates loadMore, and preserves feed state',
    () async {
      final queries = <Map<String, String>>[];
      var call = 0;
      final mock = MockClient((req) async {
        expect(req.url.path, '/apps/annotations/v1/notes');
        queries.add(req.url.queryParameters);
        call++;
        if (call == 1) {
          return http.Response(
            jsonEncode({
              'browse_token': 'bt_seed1',
              'next_cursor': 'r1:a2',
              'items': [
                {
                  'note_id': 'n1',
                  'author_id': 'auth_1',
                  'author_name': 'Alice',
                  'language': 'en',
                  'title': 'Calculus',
                  'summary': 'Derivatives',
                  'tags': ['math'],
                  'views': ['original', 'typed'],
                  'default_view': 'original',
                  'can_switch_view': true,
                  'typed_uses_earlier_revision': false,
                  'published_at': 1700000000,
                },
                {
                  'note_id': 'n2',
                  'author_id': 'auth_2',
                  'author_name': 'Bob',
                  'language': 'en',
                  'title': 'Algebra',
                  'summary': null,
                  'tags': [],
                  'views': ['original'],
                  'default_view': 'original',
                  'can_switch_view': false,
                  'typed_uses_earlier_revision': false,
                  'published_at': 1700000010,
                },
              ],
            }),
            200,
          );
        }
        // Second page intentionally repeats n2 to verify dedup.
        return http.Response(
          jsonEncode({
            'browse_token': 'bt_seed1',
            'next_cursor': null,
            'items': [
              {
                'note_id': 'n2',
                'author_id': 'auth_2',
                'author_name': 'Bob',
                'title': 'Algebra',
                'tags': [],
              },
              {
                'note_id': 'n3',
                'author_id': 'auth_3',
                'author_name': 'Cara',
                'title': 'Geometry',
                'tags': ['math'],
              },
            ],
          }),
          200,
        );
      });

      final adapter = DiscoveryReaderAdapter(
        ApiAdapter(
          client: mock,
          base: 'https://api.asodya.com/apps/annotations/v1',
        ),
      );
      final controller = DiscoveryFeedController(adapter: adapter);

      await controller.refresh(
        const DiscoveryQuery(
          q: 'calc',
          authorId: 'auth_1',
          language: 'en',
          tag: 'math',
          projectId: 'proj_1',
          limit: 2,
        ),
      );
      expect(queries[0]['q'], 'calc');
      expect(queries[0]['author_id'], 'auth_1');
      expect(queries[0]['language'], 'en');
      expect(queries[0]['tag'], 'math');
      expect(queries[0]['project_id'], 'proj_1');
      expect(queries[0]['limit'], '2');
      expect(controller.items.map((e) => e.id).toList(), ['n1', 'n2']);
      expect(controller.browseToken, 'bt_seed1');
      expect(controller.nextCursor, 'r1:a2');

      controller.scrollOffset = 420.5;
      await controller.loadMore();
      expect(queries[1]['browse_token'], 'bt_seed1');
      expect(queries[1]['cursor'], 'r1:a2');
      expect(controller.items.map((e) => e.id).toList(), ['n1', 'n2', 'n3']);
      expect(controller.scrollOffset, 420.5);
      expect(controller.query.q, 'calc');
    },
  );

  test(
    'public reader parses real annotations_api views, default_view, can_switch_view, typed_uses_earlier_revision, representations[], and restricted embeds',
    () async {
      final mock = MockClient((req) async {
        expect(req.url.path, '/apps/annotations/v1/notes/n_pub');
        return http.Response(
          jsonEncode({
            'note_id': 'n_pub',
            'author_id': 'auth_1',
            'author_name': 'Alice',
            'language': 'en',
            'title': 'Published Study',
            'summary': 'Summary text',
            'tags': ['physics'],
            'views': ['original', 'typed'],
            'default_view': 'typed',
            'can_switch_view': true,
            'typed_uses_earlier_revision': true,
            'published_at': 1700000100,
            'representations': [
              {
                'representation': 'original',
                'schema_version': 1,
                'document': {
                  'page': {'width': 1000},
                  'items': [
                    {
                      'id': 'it_rep',
                      'kind': 'reports_embed',
                      'x': 0,
                      'y': 0,
                      'width': 300,
                      'height': 120,
                      'report_id': 'rep_secret',
                      'restricted': true,
                    },
                  ],
                },
              },
              {
                'representation': 'typed',
                'schema_version': 1,
                'document': {
                  'blocks': [
                    {
                      'id': 'b1',
                      'kind': 'paragraph',
                      'spans': [
                        {'text': 'Typed body'},
                      ],
                    },
                    {
                      'id': 'b2',
                      'kind': 'task_card',
                      'task_id': 'task_9',
                      'restricted': true,
                    },
                  ],
                },
              },
            ],
          }),
          200,
        );
      });

      final adapter = DiscoveryReaderAdapter(
        ApiAdapter(
          client: mock,
          base: 'https://api.asodya.com/apps/annotations/v1',
        ),
      );

      final view = await adapter.getPublicNote('n_pub', language: 'en');
      expect(view.noteId, 'n_pub');
      expect(view.activeView, NoteViewMode.typed);
      expect(view.hasOriginal, isTrue);
      expect(view.hasTyped, isTrue);
      expect(view.canSwitchView, isTrue);
      expect(view.isTypedStale, isTrue);
      expect(view.activeDocument?['blocks'], isNotNull);
      expect(view.embeds.length, 1);
      expect(view.embeds.first.kind, 'task_card');
      expect(view.embeds.first.refId, 'task_9');
      expect(view.embeds.first.restricted, isTrue);
      expect(view.embeds.first.payload, isNull);

      final origView = await adapter.getPublicNote(
        'n_pub',
        view: NoteViewMode.original,
      );
      expect(origView.activeView, NoteViewMode.original);
      expect(origView.embeds.length, 1);
      expect(origView.embeds.first.kind, 'reports_embed');
      expect(origView.embeds.first.refId, 'rep_secret');
      expect(origView.embeds.first.restricted, isTrue);
    },
  );

  test(
    'author profile, author projects, public project, and read-only own synced notes hit exact routes',
    () async {
      final paths = <String>[];
      final mock = MockClient((req) async {
        paths.add('${req.method} ${req.url.path}');
        if (req.url.path.endsWith('/authors/auth_1')) {
          return http.Response(
            jsonEncode({'author_id': 'auth_1', 'name': 'Alice'}),
            200,
          );
        }
        if (req.url.path.endsWith('/authors/auth_1/projects')) {
          return http.Response(
            jsonEncode({'items': [], 'next_cursor': null}),
            200,
          );
        }
        if (req.url.path.endsWith('/projects/proj_1')) {
          return http.Response(
            jsonEncode({'project_id': 'proj_1', 'name': 'Physics'}),
            200,
          );
        }
        if (req.url.path.endsWith('/me/notes')) {
          return http.Response(
            jsonEncode({
              'items': [
                {'note_id': 'my_1', 'title': 'My Note', 'tags': []},
              ],
              'next_cursor': null,
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'note_id': 'my_1',
            'title': 'My Note',
            'views': ['original'],
            'default_view': 'original',
            'can_switch_view': false,
            'typed_uses_earlier_revision': false,
            'representations': [
              {
                'representation': 'original',
                'schema_version': 1,
                'document': {'items': []},
              },
            ],
          }),
          200,
        );
      });

      final adapter = DiscoveryReaderAdapter(
        ApiAdapter(
          client: mock,
          base: 'https://api.asodya.com/apps/annotations/v1',
        ),
      );

      final author = await adapter.getAuthor('auth_1');
      expect(author['author_id'], 'auth_1');
      await adapter.getAuthorProjects('auth_1', cursor: 'c1');
      final proj = await adapter.getProject('proj_1');
      expect(proj['project_id'], 'proj_1');
      final mine = await adapter.listMySyncedNotes();
      expect(mine.items.single.id, 'my_1');
      final myView = await adapter.getMySyncedNote('my_1');
      expect(myView.canSwitchView, isFalse);
      expect(myView.hasTyped, isFalse);
      expect(paths, [
        'GET /apps/annotations/v1/authors/auth_1',
        'GET /apps/annotations/v1/authors/auth_1/projects',
        'GET /apps/annotations/v1/projects/proj_1',
        'GET /apps/annotations/v1/me/notes',
        'GET /apps/annotations/v1/me/notes/my_1',
      ]);
    },
  );
}
