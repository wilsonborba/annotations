// Room sharing over time (annotations#44, C1.1 to C1.7): pause before
// sharing, no sharing during a gesture, polling with rebase, lost connection
// and retry, fixed expiry. Two editors share one stateful fake server.
import 'dart:typed_data';

import 'package:annotations_shared/dal/remote/api_adapter.dart';
import 'package:annotations_shared/domain/models/local_note.dart';
import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/editor_files.dart';
import 'package:annotations_shared/domain/services/instant_room_service.dart';
import 'package:annotations_shared/domain/services/instant_room_share.dart';
import 'package:annotations_shared/domain/services/note_autosave.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_room_server.dart';

const _api = 'https://api.example.test/apps/annotations/v1';
const _fast = RoomShareSettings(
  pause: Duration(milliseconds: 20),
  poll: Duration(milliseconds: 30),
);

Map<String, Object?> text(String id, String value, {num y = 32}) => {
  'id': id,
  'kind': 'text',
  'x': 96,
  'y': y,
  'width': 320,
  'height': 32,
  'spans': [
    {'text': value},
  ],
};

InstantRoomDocument roomDoc(List<Map<String, Object?>> items) =>
    RoomShare.documentOf({
      'page': {
        'width': 1000,
        'background': {'kind': 'blank'},
      },
      'items': items,
    });

final class _Editor implements RoomEditor {
  _Editor(this.document);
  @override
  InstantRoomDocument document;
  @override
  bool busy = false;
  int shown = 0;
  @override
  bool receive(InstantRoomDocument next) {
    if (busy) return false;
    document = next;
    shown++;
    return true;
  }

  /// A local accepted edit, handed to the share like the paper handler does.
  void edit(RoomShare share, List<Map<String, Object?>> items) {
    document = roomDoc(items);
    share.edited(
      LocalNoteDraft(id: 'room', schema: document.schema, document: document),
    );
  }

  List<String> get texts => [
    for (final it in document.toJson()['items'] as List)
      '${((it as Map)['spans'] as List).first['text']}',
  ];
}

final class _NoFiles implements EditorFiles {
  @override
  dynamic noSuchMethod(Invocation i) => throw UnsupportedError('files');
  @override
  Future<Uint8List?> readAttachment(String id) async => null;
}

Future<(RoomShare, _Editor)> open(
  FakeRoomServer server, {
  DateTime Function()? clock,
  RoomShareSettings settings = _fast,
}) async {
  final room = InstantRoomService(
    ApiAdapter(client: server.client(), base: _api),
  );
  await room.joinRoom(server.code);
  final share = RoomShare(
    room,
    files: _NoFiles(),
    settings: settings,
    clock: clock,
  );
  final editor = _Editor(RoomShare.documentOf(room.document));
  share.attach(editor);
  addTearDown(share.dispose);
  return (share, editor);
}

Future<void> until(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue);
}

void main() {
  test(
    'an edit is shared after the pause and reaches the other person',
    () async {
      final server = FakeRoomServer();
      final (shareA, a) = await open(
        server,
        settings: const RoomShareSettings(
          pause: Duration(milliseconds: 250),
          poll: Duration(milliseconds: 30),
        ),
      );
      final (_, b) = await open(server);

      a.edit(shareA, [text('t1', 'hello')]);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(server.items, isEmpty, reason: 'nothing before the pause');
      expect(shareA.state.value, SaveState.saving);
      await until(() => server.items.containsKey('t1'));
      await until(() => shareA.sharing.value == InstantSharingState.shared);
      await until(() => b.texts.contains('hello'));
    },
  );

  test('nothing is shared while a gesture holds the page', () async {
    final server = FakeRoomServer();
    final (share, a) = await open(server);
    a.busy = true;
    a.edit(share, [text('t1', 'mid gesture')]);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(server.items, isEmpty);
    a.busy = false;
    await until(() => server.items.containsKey('t1'));
  });

  test('a change from someone else does not drop my unshared change', () async {
    final server = FakeRoomServer();
    final (shareA, a) = await open(server);
    final (shareB, b) = await open(server);
    b.edit(shareB, [text('b1', 'from B', y: 96)]);
    await until(() => server.items.containsKey('b1'));
    // A types before A's poll brought b1 in.
    a.edit(shareA, [text('a1', 'from A')]);
    await until(() => server.items.containsKey('a1'));
    await until(() => a.texts.toSet().containsAll(['from A', 'from B']));
    await until(() => b.texts.toSet().containsAll(['from A', 'from B']));
  });

  test('connection lost keeps the change; Retry reads the room first, then '
      'shares it', () async {
    final server = FakeRoomServer();
    final (share, a) = await open(server);
    server.offline = true;
    a.edit(share, [text('t1', 'kept')]);
    await until(
      () => share.sharing.value == InstantSharingState.connectionLost,
    );
    expect(share.state.value, SaveState.failed);
    server.offline = false;
    final callsBefore = server.calls.length;
    await share.retry();
    await until(() => server.items.containsKey('t1'));
    expect(server.calls[callsBefore], 'GET /instant/ROOM12');
    expect(share.sharing.value, InstantSharingState.shared);
  });

  test('the room expires at its fixed time: sharing stops and the content is '
      'cleared, without extension', () async {
    final server = FakeRoomServer(expiresAt: 1700000900);
    var now = DateTime.fromMillisecondsSinceEpoch(
      1700000900 * 1000 - 150,
      isUtc: true,
    );
    final (share, a) = await open(server, clock: () => now);
    a.edit(share, [text('t1', 'x')]);
    await until(() => server.items.containsKey('t1'));
    expect(share.nearExpiry, isTrue);
    now = now.add(const Duration(seconds: 1));
    await until(() => share.sharing.value == InstantSharingState.expired);
    expect(a.texts, isEmpty);
    final calls = server.calls.length;
    a.edit(share, [text('t2', 'after')]);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(server.calls.length, calls, reason: 'no request after expiry');
    expect(share.remaining, Duration.zero);
  });

  test(
    'the same block edited by two people: the later one is kept for review',
    () async {
      final server = FakeRoomServer();
      final (shareA, a) = await open(server);
      final (shareB, b) = await open(server);
      a.edit(shareA, [text('t1', 'start')]);
      await until(() => b.texts.contains('start'));
      // Both change t1 at once; A is shared first.
      b.busy = true;
      a.edit(shareA, [text('t1', 'A wins')]);
      b.document = roomDoc([text('t1', 'B late')]);
      await until(
        () =>
            server.items['t1']?['spans'].toString().contains('A wins') ?? false,
      );
      b.busy = false;
      b.edit(shareB, [text('t1', 'B late')]);
      await until(() => shareB.conflicts.value.isNotEmpty);
      expect(shareB.conflicts.value.single.text, 'B late');
      await until(() => b.texts.single == 'A wins');
    },
  );
}
