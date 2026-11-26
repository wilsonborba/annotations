// Instant room files (annotations#44, C1.7, C1.8): two-step upload, the
// other person downloads the bytes, a failed upload is never ready, and an
// expired room downloads nothing.
import 'dart:async';
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

  test(
    'a delayed reservation cannot start content upload after expiry',
    () async {
      final server = FakeRoomServer();
      final (room, files) = await join(server);
      final reservation = Completer<void>();
      server.beforeFileReservation = () => reservation.future;
      final upload = files.importBytes(
        png,
        name: 'late.png',
        type: 'image/png',
      );
      for (
        var i = 0;
        i < 100 && !server.calls.contains('POST /instant/ROOM12/files');
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(server.calls, contains('POST /instant/ROOM12/files'));
      room.expire();
      reservation.complete();
      await expectLater(upload, throwsA(anything));
      expect(server.calls.where((c) => c.contains('/content')), isEmpty);
      expect(room.files, isEmpty);
    },
  );

  test('a closed room does not read a newly selected local file', () async {
    final server = FakeRoomServer();
    final (room, _) = await join(server);
    var reads = 0;
    final files = RoomFiles(
      room,
      readPath: (_) async {
        reads++;
        return png;
      },
    );
    room.expire();
    await expectLater(
      files.importFile('/private/local.png', type: 'image/png'),
      throwsA(isA<StateError>()),
    );
    expect(reads, 0);
  });

  test(
    'a delayed content response cannot restore local file state after expiry',
    () async {
      final server = FakeRoomServer();
      final (room, files) = await join(server);
      final content = Completer<void>();
      server.beforeFileContent = () => content.future;
      final upload = files.importBytes(
        png,
        name: 'late.png',
        type: 'image/png',
      );
      for (
        var i = 0;
        i < 100 && !server.calls.any((c) => c.contains('/content'));
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(server.calls.any((c) => c.contains('/content')), isTrue);
      room.expire();
      content.complete();
      await expectLater(upload, throwsA(anything));
      expect(room.files, isEmpty);
      expect(await files.readAttachment('f1'), isNull);
    },
  );
}
