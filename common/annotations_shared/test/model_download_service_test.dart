import 'dart:convert';
import 'dart:io';

import 'package:annotations_shared/dal/remote/api_adapter.dart';
import 'package:annotations_shared/dal/remote/transcription_api_adapter.dart';
import 'package:annotations_shared/domain/models/transcription_session.dart';
import 'package:annotations_shared/domain/services/model_download_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('annotations-model-');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'resumes a partial artifact with the granted Range and verifies bytes',
    () async {
      final bytes = [1, 2, 3, 4, 5];
      final hash = sha256.convert(bytes).toString();
      final store = DirectoryModelArtifactStore(directory);
      await store.appendPartial('download-1', Stream.value([1, 2]));
      var contentRange = '';
      var rangeHeader = '';
      final client = MockClient((request) async {
        if (request.url.path == '/models/v1') {
          expect(request.method, 'GET');
          expect(request.headers['authorization'], 'Bearer owner-a');
          return _manifest(hash, bytes.length);
        }
        if (request.url.path == '/me/model_downloads' &&
            request.method == 'POST') {
          expect(request.headers['authorization'], 'Bearer owner-a');
          expect(request.headers['x-csrf-token'], 'csrf-owner-a');
          expect(jsonDecode(request.body), {
            'model_version': 'v1',
            'platform': 'linux',
          });
          return _grant(hash, bytes.length);
        }
        if (request.url.path == '/me/model_downloads/download-1/content') {
          expect(request.method, 'GET');
          expect(request.headers['authorization'], 'Bearer owner-a');
          expect(request.headers['accept'], 'application/octet-stream');
          rangeHeader = request.headers['range'] ?? '';
          contentRange = 'bytes 2-4/5';
          return http.Response.bytes(
            [3, 4, 5],
            206,
            headers: {'content-range': contentRange, 'etag': hash},
          );
        }
        return http.Response('{"error":"unexpected route"}', 404);
      });

      final downloaded = await _service(
        client,
        store,
      ).download(version: 'v1', platform: 'linux');

      expect(rangeHeader, 'bytes=2-');
      expect(contentRange, 'bytes 2-4/5');
      expect(await downloaded.file.readAsBytes(), bytes);
      expect(
        await store.hasValidArtifact(
          version: 'v1',
          platform: 'linux',
          size: bytes.length,
          sha256: hash,
        ),
        isTrue,
      );
      client.close();
    },
  );

  test('rejects corrupt bytes and clears the partial model', () async {
    final expected = [1, 2, 3, 4];
    final hash = sha256.convert(expected).toString();
    final store = DirectoryModelArtifactStore(directory);
    final client = MockClient((request) async {
      if (request.url.path == '/models/v1') {
        expect(request.method, 'GET');
        expect(request.headers['authorization'], 'Bearer owner-a');
        return _manifest(hash, 4);
      }
      if (request.url.path == '/me/model_downloads' &&
          request.method == 'POST') {
        expect(request.headers['authorization'], 'Bearer owner-a');
        expect(request.headers['x-csrf-token'], 'csrf-owner-a');
        expect(jsonDecode(request.body), {
          'model_version': 'v1',
          'platform': 'linux',
        });
        return _grant(hash, 4);
      }
      if (request.url.path == '/me/model_downloads/download-1/content') {
        expect(request.method, 'GET');
        expect(request.headers['authorization'], 'Bearer owner-a');
        expect(request.headers['accept'], 'application/octet-stream');
        return http.Response.bytes([4, 3, 2, 1], 200);
      }
      return http.Response('{"error":"unexpected route"}', 404);
    });

    await expectLater(
      _service(client, store).download(version: 'v1', platform: 'linux'),
      throwsA(isA<ModelChecksumMismatchException>()),
    );
    expect(await store.partialSize('download-1'), 0);
    expect(
      await store.hasValidArtifact(
        version: 'v1',
        platform: 'linux',
        size: 4,
        sha256: hash,
      ),
      isFalse,
    );
    client.close();
  });
}

ModelDownloadService _service(http.Client client, ModelArtifactStore store) =>
    ModelDownloadService(
      api: TranscriptionApiAdapter(
        ApiAdapter(client: client, base: 'https://api.test'),
      ),
      store: store,
      sessionProvider: () async => TranscriptionSession(
        accountId: 'owner-a',
        readHeaders: {'authorization': 'Bearer owner-a'},
        mutationHeaders: {
          'authorization': 'Bearer owner-a',
          'x-csrf-token': 'csrf-owner-a',
        },
        isCurrent: () => true,
      ),
      enabled: true,
    );

http.Response _manifest(String hash, int size) => http.Response(
  jsonEncode({
    'version': 'v1',
    'status': 'published',
    'is_default': true,
    'created_at': 1,
    'artifacts': [
      {'platform': 'linux', 'size': size, 'sha256': hash},
    ],
    'languages': ['en'],
    'capabilities': ['transcription'],
  }),
  200,
  headers: {'content-type': 'application/json'},
);

http.Response _grant(String hash, int size) => http.Response(
  jsonEncode({
    'download_id': 'download-1',
    'model_version': 'v1',
    'platform': 'linux',
    'size': size,
    'sha256': hash,
    'model_status': 'published',
    'created_at': 1,
  }),
  201,
  headers: {'content-type': 'application/json'},
);
