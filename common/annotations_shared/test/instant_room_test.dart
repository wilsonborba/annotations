import 'dart:convert';

import 'package:annotations_shared/dal/remote/api_adapter.dart';
import 'package:annotations_shared/domain/services/instant_room_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('two clients editing different items succeed; same item 409 keeps text and refreshes; expiry clears content', () async {
    final serverItems = <String, Map<String, Object?>>{};
    var expired = false;

    final mock = MockClient((req) async {
      if (expired) {
        return http.Response(jsonEncode({'error': 'expired'}), 410);
      }
      if (req.method == 'POST' && req.url.path.endsWith('/instant')) {
        return http.Response(
          jsonEncode({'code': 'ROOM12', 'items': serverItems.values.toList()}),
          201,
        );
      }
      if (req.method == 'GET' && req.url.path.endsWith('/instant/ROOM12')) {
        return http.Response(
          jsonEncode({'code': 'ROOM12', 'items': serverItems.values.toList()}),
          200,
        );
      }
      if (req.method == 'PUT' && req.url.path.contains('/instant/ROOM12/items/')) {
        final id = req.url.pathSegments.last;
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final expectedRev = (body['expected_revision'] as num).toInt();
        final currentRev = (serverItems[id]?['item_revision'] as int?) ?? 0;
        if (expectedRev != currentRev) {
          return http.Response(jsonEncode({'error': 'revision_conflict'}), 409);
        }
        final item = Map<String, Object?>.from(body['item'] as Map);
        // Simulate #20/#43 web integer check: reject if non-integer or rule fails.
        if (item['force_rule_error'] == true) {
          return http.Response(jsonEncode({'error': 'invalid_integer_field'}), 422);
        }
        final nextRev = currentRev + 1;
        item['item_revision'] = nextRev;
        serverItems[id] = item;
        return http.Response(jsonEncode({'item_revision': nextRev}), 200);
      }
      return http.Response('{}', 404);
    });

    final clientA = InstantRoomService(
      ApiAdapter(client: mock, base: 'https://api.asodya.com/apps/annotations/v1'),
    );
    final clientB = InstantRoomService(
      ApiAdapter(client: mock, base: 'https://api.asodya.com/apps/annotations/v1'),
    );

    await clientA.createRoom();
    await clientB.joinRoom('https://annotations.asodya.com/v1/instant/ROOM12');
    expect(clientA.state, InstantSharingState.shared);
    expect(clientA.hasHistory, isFalse);

    // Unfinished gesture never sends.
    expect(
      await clientA.sendCompletedEdit({'id': 'a1', 'x': 10.0, 'y': 20.0}, isGestureInProgress: true),
      isFalse,
    );

    // Different items both succeed, and integer fields are encoded as ints.
    expect(await clientA.sendCompletedEdit({'id': 'a1', 'x': 10.0, 'y': 20.0, 'text': 'Client A'}), isTrue);
    expect(await clientB.sendCompletedEdit({'id': 'b1', 'x': 30, 'y': 40, 'text': 'Client B'}), isTrue);
    expect(serverItems['a1']!['x'], isA<int>());

    // Same item concurrent edit -> 409 keeps rejected text in conflicts and refreshes.
    final okConflict = await clientB.sendCompletedEdit({'id': 'a1', 'x': 10, 'y': 20, 'text': 'Conflicting B text'});
    expect(okConflict, isFalse);
    expect(clientB.conflicts.length, 1);
    expect(clientB.conflicts.first.keptText, 'Conflicting B text');

    // Server rule rejection (422) raises InstantRuleError.
    await expectLater(
      clientA.sendCompletedEdit({'id': 'a2', 'x': 5, 'y': 5, 'force_rule_error': true}),
      throwsA(isA<InstantRuleError>()),
    );

    // Expiry clears content and blocks further edits.
    expired = true;
    await clientA.joinRoom('ROOM12');
    expect(clientA.state, InstantSharingState.expired);
    expect(clientA.items, isEmpty);
    expect(clientA.canEdit, isFalse);
    expect(clientA.canExtend, isFalse);
    expect(clientA.canConvertToNote, isFalse);
  });
}
