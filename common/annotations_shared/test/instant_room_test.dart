import 'dart:convert';

import 'package:annotations_shared/dal/remote/api_adapter.dart';
import 'package:annotations_shared/domain/services/instant_room_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'PUT /instant/{code}, POST /items (rev 0), PUT /items/{id} (rev>0), 409 current_item refresh, 422 rule error, and 410 expiry',
    () async {
      final serverItems = <String, Map<String, Object?>>{};
      final itemRevs = <String, int>{};
      var roomRev = 1;
      var expired = false;
      final calls = <String>[];

      Map<String, dynamic> roomJson() => {
        'code': 'ROOM12',
        'created_at': 1700000000,
        'expires_at': 1700086400,
        'revision': roomRev,
        'schema_version': 1,
        'document': {
          'page': {
            'width': 1000,
            'background': {'kind': 'blank'},
          },
          'items': serverItems.values.toList(),
        },
        'item_revisions': itemRevs,
        'max_file_bytes': 1048576,
        'max_ip_bytes': 5242880,
        'files': [],
      };

      final mock = MockClient((req) async {
        calls.add('${req.method} ${req.url.path}');
        if (expired) {
          return http.Response(jsonEncode({'error': 'room_expired'}), 410);
        }
        if (req.method == 'PUT' &&
            req.url.path == '/apps/annotations/v1/instant/ROOM12') {
          return http.Response(jsonEncode(roomJson()), 200);
        }
        if (req.method == 'GET' &&
            req.url.path == '/apps/annotations/v1/instant/ROOM12') {
          return http.Response(jsonEncode(roomJson()), 200);
        }
        if (req.method == 'POST' &&
            req.url.path == '/apps/annotations/v1/instant/ROOM12/items') {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          expect(body['expected_revision'], 0);
          final item = Map<String, Object?>.from(body['item'] as Map);
          if (item['force_rule_error'] == true) {
            return http.Response(
              jsonEncode({'error': 'invalid_integer_field'}),
              422,
            );
          }
          final id = '${item['id']}';
          serverItems[id] = item;
          itemRevs[id] = 1;
          roomRev++;
          return http.Response(jsonEncode(roomJson()), 200);
        }
        if (req.method == 'PUT' &&
            req.url.path.contains('/instant/ROOM12/items/')) {
          final id = req.url.pathSegments.last;
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          final expectedRev = (body['expected_revision'] as num).toInt();
          final currentRev = itemRevs[id] ?? 0;
          if (expectedRev != currentRev) {
            return http.Response(
              jsonEncode({
                'error': 'item_revision_conflict',
                'current_item': serverItems[id],
                'item_revision': currentRev,
                'revision': roomRev,
              }),
              409,
            );
          }
          final item = Map<String, Object?>.from(body['item'] as Map);
          serverItems[id] = item;
          itemRevs[id] = currentRev + 1;
          roomRev++;
          return http.Response(jsonEncode(roomJson()), 200);
        }
        return http.Response('{}', 404);
      });

      final base = 'https://api.asodya.com/apps/annotations/v1';
      final clientA = InstantRoomService(ApiAdapter(client: mock, base: base));
      final clientB = InstantRoomService(ApiAdapter(client: mock, base: base));

      await clientA.createRoom(code: 'ROOM12');
      await clientB.joinRoom(
        'https://annotations.asodya.com/v1/instant/ROOM12',
      );
      expect(clientA.state, InstantSharingState.shared);
      expect(
        clientA.expiresAt,
        DateTime.fromMillisecondsSinceEpoch(1700086400 * 1000, isUtc: true),
      );
      expect(clientA.hasHistory, isFalse);

      // Unfinished gesture never sends.
      expect(
        await clientA.sendCompletedEdit({
          'id': 'a1',
          'x': 10.0,
          'y': 20.0,
        }, isGestureInProgress: true),
        isFalse,
      );

      // New items POST /items (expected_revision 0); integer fields encoded as ints.
      expect(
        await clientA.sendCompletedEdit({
          'id': 'a1',
          'x': 10.0,
          'y': 20.0,
          'text': 'Client A',
        }),
        isTrue,
      );
      expect(
        await clientB.sendCompletedEdit({
          'id': 'b1',
          'x': 30,
          'y': 40,
          'text': 'Client B',
        }),
        isTrue,
      );
      expect(serverItems['a1']!['x'], isA<int>());
      expect(clientA.itemRevisions['a1'], 1);

      // Existing item update uses PUT /items/{id} with expected_revision 1.
      expect(
        await clientA.sendCompletedEdit({
          'id': 'a1',
          'x': 12,
          'y': 20,
          'text': 'Client A v2',
        }),
        isTrue,
      );
      expect(clientA.itemRevisions['a1'], 2);

      // Stale item on clientB (still thinks a1 is rev 0) -> 409 applies current_item & item_revision.
      final okConflict = await clientB.sendCompletedEdit({
        'id': 'a1',
        'x': 10,
        'y': 20,
        'text': 'Conflicting B text',
      });
      expect(okConflict, isFalse);
      expect(clientB.conflicts.length, 1);
      expect(clientB.conflicts.first.keptText, 'Conflicting B text');
      expect(clientB.itemRevisions['a1'], 2);
      expect(clientB.items['a1']?['text'], 'Client A v2');

      // Server rule rejection (422) raises InstantRuleError.
      await expectLater(
        clientA.sendCompletedEdit({
          'id': 'a2',
          'x': 5,
          'y': 5,
          'force_rule_error': true,
        }),
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

      expect(
        calls,
        containsAll([
          'PUT /apps/annotations/v1/instant/ROOM12',
          'GET /apps/annotations/v1/instant/ROOM12',
          'POST /apps/annotations/v1/instant/ROOM12/items',
          'PUT /apps/annotations/v1/instant/ROOM12/items/a1',
        ]),
      );
    },
  );

  test(
    'file upload reserves via POST /files, uploads bytes, checks allowance, and marks failed upload not ready',
    () async {
      final calls = <String>[];
      final mock = MockClient((req) async {
        calls.add('${req.method} ${req.url.path}');
        if (req.method == 'PUT' && req.url.path.endsWith('/instant/ROOM99')) {
          return http.Response(
            jsonEncode({
              'code': 'ROOM99',
              'expires_at': 1700086400,
              'revision': 1,
              'schema_version': 1,
              'document': {'items': []},
              'item_revisions': {},
              'max_file_bytes': 1000,
              'max_ip_bytes': 1500,
              'files': [],
            }),
            200,
          );
        }
        if (req.method == 'POST' &&
            req.url.path.endsWith('/instant/ROOM99/files')) {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          expect(body['filename'], isNotNull);
          expect(body['content_type'], 'application/pdf');
          return http.Response(jsonEncode({'id': 'file_1'}), 200);
        }
        if (req.method == 'PUT' &&
            req.url.path.endsWith('/instant/ROOM99/files/file_1/content')) {
          return http.Response(jsonEncode({'id': 'file_1'}), 200);
        }
        return http.Response('{}', 404);
      });

      final api = ApiAdapter(
        client: mock,
        base: 'https://api.asodya.com/apps/annotations/v1',
      );
      final service = InstantRoomService(api);
      await service.createRoom(code: 'ROOM99');

      // Oversize file is blocked before hitting the server.
      await expectLater(
        service.uploadFile(
          name: 'huge.pdf',
          contentType: 'application/pdf',
          sizeBytes: 1200,
          uploadBytes: (_) async {},
        ),
        throwsA(isA<InstantRuleError>()),
      );

      // Valid upload reserves + uploads content (no /commit endpoint).
      final uploaded = await service.uploadFile(
        name: 'ok.pdf',
        contentType: 'application/pdf',
        sizeBytes: 800,
        uploadBytes: (id) async {
          await api.request(
            '/instant/ROOM99/files/$id/content',
            method: 'PUT',
            body: {},
          );
        },
      );
      expect(uploaded.ready, isTrue);
      expect(service.allowance.remainingBytes, 700);
      expect(calls.any((c) => c.contains('/commit')), isFalse);

      // Failed upload leaves file marked ready: false.
      await expectLater(
        service.uploadFile(
          name: 'fail.pdf',
          contentType: 'application/pdf',
          sizeBytes: 500,
          uploadBytes: (_) async => throw Exception('network drop'),
        ),
        throwsException,
      );
      expect(service.files.last.ready, isFalse);

      // Disconnected state queues edits locally in pendingEdits.
      service.markDisconnected();
      expect(service.state, InstantSharingState.connectionLost);
      expect(
        await service.sendCompletedEdit({'id': 'q1', 'x': 1, 'y': 1}),
        isFalse,
      );
      expect(service.pendingEdits.length, 1);
    },
  );
}
