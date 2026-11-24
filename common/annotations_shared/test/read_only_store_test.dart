import 'dart:typed_data';

import 'package:annotations_shared/domain/services/read_only_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'reader media loads only through the note and view scoped public route',
    () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        expect(request.method, 'GET');
        expect(request.url.path, '/apps/annotations/v1/media/file-123');
        expect(request.url.queryParameters, {
          'note_id': 'public-note',
          'view': 'typed',
        });
        expect(request.headers, isNot(contains('authorization')));
        return http.Response.bytes(
          Uint8List.fromList([0x25, 0x50, 0x44, 0x46]),
          200,
          headers: {
            'content-type': 'application/pdf',
            'content-disposition':
                "attachment; filename*=UTF-8''notes%20%E2%9C%93.pdf",
          },
        );
      });
      final store = ReadOnlyNoteStore(
        noteId: 'public-note',
        view: 'typed',
        apiBase: 'https://api.asodya.com/apps/annotations/v1',
        client: client,
      );
      addTearDown(client.close);

      final file = await store.attachment('file-123');
      final bytes = await store.readAttachment('file-123');

      expect(file?.name, 'notes ✓.pdf');
      expect(file?.type, 'application/pdf');
      expect(file?.size, 4);
      expect(file?.path, '');
      expect(bytes, [0x25, 0x50, 0x44, 0x46]);
      expect(
        calls,
        1,
        reason: 'metadata and bytes share the same fetched response',
      );
    },
  );

  test('an unconfigured read-only store does not guess media URLs', () async {
    final store = ReadOnlyNoteStore();

    await expectLater(store.readAttachment('file-123'), throwsUnsupportedError);
  });
}
