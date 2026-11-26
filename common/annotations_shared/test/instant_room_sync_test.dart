// Instant room sharing (annotations#44, C1.3 to C1.6) against a stateful fake
// that follows annotations_api rooms.rs.
import 'dart:async';

import 'package:annotations_shared/dal/remote/api_adapter.dart';
import 'package:annotations_shared/domain/services/instant_room_service.dart';
import 'package:annotations_shared/domain/services/instant_room_sync.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_room_server.dart';

const _base = 'https://api.example.test/apps/annotations/v1';

Json text(String id, String value, {num y = 32}) => {
  'id': id,
  'kind': 'text',
  'x': 96,
  'y': y,
  'width': 320,
  'height': 38.0,
  'spans': [
    {'text': value},
  ],
};

Json doc(List<Json> items, {String background = 'blank'}) => {
  'page': {
    'width': 1000,
    'background': {'kind': background},
  },
  'items': items,
};

Future<(InstantRoomService, InstantRoomSync)> join(
  FakeRoomServer server,
) async {
  final room = InstantRoomService(
    ApiAdapter(client: server.client(), base: _base),
  );
  await room.joinRoom(server.code);
  return (room, InstantRoomSync(room));
}

List<String> ids(Json d) => [
  for (final it in d['items'] as List) '${(it as Map)['id']}',
];

void main() {
  test('diff: ungrouped items go alone; a group member or the page needs a '
      'room operation; key order and 38 vs 38.0 are no change', () {
    final a = text('a', 'one');
    final sortedCopy = {for (final k in (a.keys.toList()..sort())) k: a[k]}
      ..['height'] = 38;
    expect(InstantRoomSync.diff(doc([a]), doc([sortedCopy])).isEmpty, isTrue);

    final edited = InstantRoomSync.diff(
      doc([a]),
      doc([text('a', 'two'), text('b', 'new')]),
    );
    expect(edited.replaced.map((it) => it['id']), ['a']);
    expect(edited.added.map((it) => it['id']), ['b']);
    expect(edited.needsRoomOperation, isFalse);

    final group = {
      'id': 'g',
      'kind': 'group',
      'members': ['a'],
    };
    final member = InstantRoomSync.diff(
      doc([a, group]),
      doc([text('a', 'two'), group]),
    );
    expect(member.needsRoomOperation, isTrue);
    expect(
      InstantRoomSync.diff(
        doc([a]),
        doc([a], background: 'ruled'),
      ).needsRoomOperation,
      isTrue,
    );
  });

  test(
    'two people edit different blocks at the same time: both are shared',
    () async {
      final server = FakeRoomServer();
      final (roomA, syncA) = await join(server);
      final (roomB, syncB) = await join(server);

      expect(await syncA.push(doc([text('a', 'from A')])), isTrue);
      // B did not see A's block yet and adds its own.
      expect(await syncB.push(doc([text('b', 'from B', y: 96)])), isTrue);
      expect(server.items.keys, ['a', 'b']);

      final localB = syncB.rebase(doc([text('b', 'from B', y: 96)]));
      expect(ids(localB), ['a', 'b']);
      await roomA.refresh();
      expect(ids(syncA.rebase(doc([text('a', 'from A')]))), ['a', 'b']);
      expect(roomB.state, InstantSharingState.shared);
    },
  );

  test('the same block edited by two people: the later change is refused, '
      'kept for review, and the room version is shown', () async {
    final server = FakeRoomServer();
    final (_, syncA) = await join(server);
    expect(await syncA.push(doc([text('a', 'start')])), isTrue);
    syncA.rebase(doc([text('a', 'start')]));
    final (roomB, syncB) = await join(server);

    expect(await syncA.push(doc([text('a', 'A wins')])), isTrue);
    // B's poll refreshed the room while B was still typing on the old base:
    // B's write must still carry the revision B's change was made on.
    await roomB.refresh();
    final ok = await syncB.push(doc([text('a', 'B late')]));
    expect(ok, isFalse);
    expect(syncB.conflicts.single.text, 'B late');
    expect(server.items['a']!['spans'], [
      {'text': 'A wins'},
    ]);
    final shown = syncB.rebase(doc([text('a', 'B late')]));
    expect(
      (shown['items'] as List).single,
      containsPair('spans', [
        {'text': 'A wins'},
      ]),
    );
  });

  test(
    'a change made on an outdated view never reverts the newer room',
    () async {
      final server = FakeRoomServer();
      final (_, syncA) = await join(server);
      await syncA.push(doc([text('a', 'v1'), text('b', 'b1', y: 96)]));
      syncA.rebase(doc([text('a', 'v1'), text('b', 'b1', y: 96)]));
      final (roomB, syncB) = await join(server);

      // A changes a. B refreshes its mirror but its editor still shows a = v1,
      // and B changes only b.
      await syncA.push(doc([text('a', 'v2'), text('b', 'b1', y: 96)]));
      await roomB.refresh();
      expect(
        await syncB.push(doc([text('a', 'v1'), text('b', 'b2', y: 96)])),
        isTrue,
      );
      expect(server.items['a']!['spans'], [
        {'text': 'v2'},
      ]);
      expect(server.items['b']!['spans'], [
        {'text': 'b2'},
      ]);
      final shown = syncB.rebase(
        doc([text('a', 'v1'), text('b', 'b2', y: 96)]),
      );
      expect(
        (shown['items'] as List).first,
        containsPair('spans', [
          {'text': 'v2'},
        ]),
      );
    },
  );

  test(
    'deleting a block sends DELETE with the item revision in If-Match',
    () async {
      final server = FakeRoomServer();
      final (_, sync) = await join(server);
      await sync.push(doc([text('a', 'x'), text('b', 'y', y: 96)]));
      sync.rebase(doc([text('a', 'x'), text('b', 'y', y: 96)]));
      expect(await sync.push(doc([text('b', 'y', y: 96)])), isTrue);
      expect(server.calls.last, 'DELETE /instant/ROOM12/items/a');
      expect(server.items.keys, ['b']);
    },
  );

  test('a group goes as one room operation; a room revision that moved for '
      'another block is retried once, a real overlap is refused', () async {
    final server = FakeRoomServer();
    final (_, syncA) = await join(server);
    final start = doc([
      text('a', 'x'),
      text('b', 'y', y: 96),
      text('c', 'z', y: 160),
    ]);
    await syncA.push(start);
    syncA.rebase(start);
    final (roomB, syncB) = await join(server);

    // B edits c alone, which moves the room revision.
    await syncB.push(
      doc([text('a', 'x'), text('b', 'y', y: 96), text('c', 'zz', y: 160)]),
    );
    syncB.rebase(
      doc([text('a', 'x'), text('b', 'y', y: 96), text('c', 'zz', y: 160)]),
    );

    // A groups a and b on its older base: refused once, then sent again.
    final grouped = doc([
      text('a', 'x'),
      text('b', 'y', y: 96),
      text('c', 'z', y: 160),
      {
        'id': 'g',
        'kind': 'group',
        'members': ['a', 'b'],
      },
    ]);
    expect(await syncA.push(grouped), isTrue);
    expect(server.items.keys, containsAll(['g']));
    expect(
      server.items['c']!['spans'],
      [
        {'text': 'zz'},
      ],
      reason: 'the retry must not revert the other block',
    );
    expect(server.calls.where((c) => c == 'PATCH /instant/ROOM12').length, 2);

    // Now B changes a member through its own room operation on an old base,
    // after A changed the same member: refused, not replayed.
    await roomB.refresh();
    syncB.rebase(doc([]));
    final aShown = syncA.rebase(grouped);
    await syncA.push({
      ...aShown,
      'items': [
        for (final it in aShown['items'] as List)
          (it as Map)['id'] == 'a' ? text('a', 'A edit') : it,
      ],
    });
    final bLocal = {
      ...syncB.base,
      'items': [
        for (final it in syncB.base['items'] as List)
          (it as Map)['id'] == 'a' ? text('a', 'B edit') : it,
      ],
    };
    expect(await syncB.push(bLocal), isFalse);
    expect(syncB.conflicts.single.text, 'B edit');
    expect(server.items['a']!['spans'], [
      {'text': 'A edit'},
    ]);
  });

  test(
    'a lost connection keeps the change for later and marks the room',
    () async {
      final server = FakeRoomServer();
      final (room, sync) = await join(server);
      server.offline = true;
      await expectLater(sync.push(doc([text('a', 'kept')])), throwsA(anything));
      expect(room.state, InstantSharingState.connectionLost);
      // Reconnect: compare with the room first, then share.
      server.offline = false;
      await room.refresh();
      final local = sync.rebase(doc([text('a', 'kept')]));
      expect(ids(local), ['a']);
      expect(await sync.push(local), isTrue);
      expect(server.items.keys, ['a']);
    },
  );

  test('a refused page edit is not returned by rebase or replayed', () async {
    final server = FakeRoomServer();
    final (_, syncA) = await join(server);
    final (roomB, syncB) = await join(server);
    final stale = doc([], background: 'lined');
    final current = doc([], background: 'ruled');
    expect(await syncA.push(current), isTrue);

    expect(await syncB.push(stale), isFalse);
    final rebased = syncB.rebase(stale);
    expect(rebased['page'], roomB.page);
    final patches = server.calls
        .where((c) => c == 'PATCH /instant/ROOM12')
        .length;
    expect(await syncB.push(rebased), isTrue);
    expect(
      server.calls.where((c) => c == 'PATCH /instant/ROOM12').length,
      patches,
    );
    expect(server.page['background'], {'kind': 'ruled'});
  });

  test(
    'an in-flight refresh cannot restore room content after expiry',
    () async {
      final server = FakeRoomServer()..items['a'] = text('a', 'secret');
      server.itemRevisions['a'] = 1;
      final (room, _) = await join(server);
      final response = Completer<void>();
      server.beforeRoomGet = () => response.future;
      final refresh = room.refresh();
      for (
        var i = 0;
        i < 100 &&
            server.calls.where((c) => c == 'GET /instant/ROOM12').length < 2;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(server.calls.where((c) => c == 'GET /instant/ROOM12').length, 2);
      room.expire();
      response.complete();
      await refresh;
      expect(room.state, InstantSharingState.expired);
      expect(room.items, isEmpty);
    },
  );

  test('an expired room stops sharing and clears the content', () async {
    final server = FakeRoomServer();
    final (room, sync) = await join(server);
    await sync.push(doc([text('a', 'x')]));
    server.expired = true;
    await expectLater(
      sync.push(doc([text('a', 'y')])),
      throwsA(isA<ApiError>()),
    );
    expect(room.state, InstantSharingState.expired);
    expect(room.items, isEmpty);
  });
}
