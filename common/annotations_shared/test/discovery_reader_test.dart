import 'dart:convert';

import 'package:annotations_shared/dal/remote/api_adapter.dart';
import 'package:annotations_shared/domain/services/discovery_reader_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('returning from a note preserves list, filters, browse_token, scroll offset and deduplicates loadMore', () async {
    final seenQueries = <Map<String, String>>[];
    final mock = MockClient((req) async {
      seenQueries.add(Map<String, String>.from(req.url.queryParameters));
      final cursor = req.url.queryParameters['cursor'];
      if (cursor == null) {
        return http.Response(
          jsonEncode({
            'browse_token': 'bt_1',
            'next_cursor': 'c_2',
            'items': [
              {'note_id': 'n1', 'title': 'First', 'author_id': 'a1', 'author_name': 'Ana'},
              {'note_id': 'n2', 'title': 'Second', 'author_id': 'a2', 'author_name': 'Bob'},
            ],
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode({
          'browse_token': 'bt_1',
          'next_cursor': null,
          'items': [
            {'note_id': 'n2', 'title': 'Second (dup)', 'author_id': 'a2', 'author_name': 'Bob'},
            {'note_id': 'n3', 'title': 'Third', 'author_id': 'a3', 'author_name': 'Cai'},
          ],
        }),
        200,
      );
    });

    final adapter = DiscoveryReaderAdapter(
      ApiAdapter(client: mock, base: 'https://api.asodya.com/apps/annotations/v1'),
    );
    final feed = DiscoveryFeedController(adapter: adapter);

    await feed.refresh(const DiscoveryQuery(q: 'calculus', language: 'en'));
    expect(feed.items.map((e) => e.id).toList(), ['n1', 'n2']);
    expect(feed.browseToken, 'bt_1');

    await feed.loadMore();
    expect(feed.items.map((e) => e.id).toList(), ['n1', 'n2', 'n3']);
    expect(seenQueries.last['browse_token'], 'bt_1');
    expect(seenQueries.last['cursor'], 'c_2');

    // Simulate scrolling, navigating to a note, and returning:
    feed.scrollOffset = 420.5;
    expect(feed.scrollOffset, 420.5);
    expect(feed.query.q, 'calculus');
    expect(feed.items.map((e) => e.id).toList(), ['n1', 'n2', 'n3']);
  });

  test('reader view selection, stale typed flag, and restricted embed placeholder', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/apps/annotations/v1/notes/n1');
      return http.Response(
        jsonEncode({
          'note_id': 'n1',
          'title': 'Public Note',
          'main_view': 'original',
          'has_original': false,
          'has_typed': true,
          'typed_stale': true,
          'embeds': [
            {'kind': 'report_embed', 'ref_id': 'r1', 'visibility': 'restricted', 'payload': {'secret': 1}},
            {'kind': 'report_embed', 'ref_id': 'r2', 'visibility': 'public', 'payload': {'ok': true}},
          ],
        }),
        200,
      );
    });

    final adapter = DiscoveryReaderAdapter(
      ApiAdapter(client: mock, base: 'https://api.asodya.com/apps/annotations/v1'),
    );
    final view = await adapter.getPublicNote('n1', language: 'en');
    expect(view.activeView, NoteViewMode.typed);
    expect(view.canSwitchView, isFalse);
    expect(view.isTypedStale, isTrue);
    expect(view.embeds.first.restricted, isTrue);
    expect(view.embeds.first.payload, isNull);
    expect(view.embeds.last.restricted, isFalse);
    expect(view.embeds.last.payload, {'ok': true});
  });
}
