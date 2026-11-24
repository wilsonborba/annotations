// Instant room files (annotations#44, C1.7, C1.8): two-step upload, the
// other person downloads the bytes, a failed upload is never ready, and an
// expired room downloads nothing.
import 'dart:typed_data';

import 'package:annotations_shared/dal/remote/api_adapter.dart';
import 'package:annotations_shared/domain/services/instant_room_files.dart';
import 'package:annotations_shared/domain/services/instant_room_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_room_server.dart';

const _api = 'https://api.example.test/apps/annotations/v1';

Future<(InstantRoomService, RoomFiles)> join(FakeRoomServer server) async {
  final room = InstantRoomService(
    ApiAdapter(client: server.client(), base: _api),
  );
  await room.joinRoom(server.code);
  return (room, RoomFiles(room, readPath: (_) async => Uint8List(0)));
}

void main() {
  final png = Uint8List.fromList([137, 80, 78, 71, 1, 2, 3, 4]);

  test(
    'a file goes in two steps and the other person downloads its bytes',
    () async {
      final server = FakeRoomServer();
      final (_, filesA) = await join(server);
      final added = await filesA.importBytes(
        png,
        name: 'map.png',
        type: 'image/png',
      );
      expect(
        server.calls,
        containsAllInOrder([
          'POST /instant/ROOM12/files',
          'PUT /instant/ROOM12/files/${added.id}/content',
        ]),
      );
      expect(server.fileBytes[added.id], png);

      final (roomB, filesB) = await join(server);
      final meta = await filesB.attachment(added.id);
      expect(meta?.name, 'map.png');
      expect(meta?.size, png.length);
      expect(await filesB.readAttachment(added.id), png);
      expect(server.calls.last, 'GET /instant/ROOM12/files/${added.id}');
      expect(roomB.state, InstantSharingState.shared);
    },
  );

  test('a failed upload is never ready', () async {
    final server = FakeRoomServer()..failUploads = true;
    final (room, files) = await join(server);
    await expectLater(
      files.importBytes(png, name: 'x.png', type: 'image/png'),
      throwsA(isA<ApiError>()),
    );
    final id = room.files.single.fileId;
    expect(room.files.single.ready, isFalse);
    expect(await files.attachment(id), isNull);
  });

  test('an expired room downloads nothing and drops kept bytes', () async {
    final server = FakeRoomServer();
    final (room, files) = await join(server);
    final added = await files.importBytes(
      png,
      name: 'm.png',
      type: 'image/png',
    );
    room.expire();
    files.clear();
    final calls = server.calls.length;
    expect(await files.readAttachment(added.id), isNull);
    expect(await files.attachment(added.id), isNull);
    expect(server.calls.length, calls);
  });
}
