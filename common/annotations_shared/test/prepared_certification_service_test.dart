import 'dart:convert';

import 'package:annotations_shared/dal/remote/api_adapter.dart';
import 'package:annotations_shared/domain/models/local_note.dart';
import 'package:annotations_shared/domain/services/native_auth_service.dart';
import 'package:annotations_shared/domain/services/prepared_certification_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

void main() {
  const session = NativeSession(sessionId: 'sid-test', csrfToken: 'csrf-test');

  test(
    'creates a study with the exact selected revisions and config',
    () async {
      late http.Request request;
      final service = PreparedCertificationService(
        api: ApiAdapter(
          base: 'https://api.test/apps/annotations/v1',
          client: MockClient((value) async {
            request = value;
            return http.Response(
              jsonEncode({
                'study': {
                  'id': 'study-1',
                  'title': 'Biology',
                  'status': 'draft',
                  'config': {'language': 'pt-BR', 'count': 12},
                },
                'sources': [],
                'quota': {'used_bytes': 0, 'max_bytes': 100},
              }),
              201,
            );
          }),
        ),
        session: session,
      );

      final study = await service.create(
        noteId: 'note/7',
        title: 'Biology',
        expectedRevision: 9,
        sources: const [
          PreparedCertificationSource(
            kind: 'note_original',
            revisionId: 'revision-original-3',
            selectionKind: 'pages',
            selectionSpec: '2-4',
          ),
        ],
        config: const PreparedCertificationConfig(language: 'pt-BR', count: 12),
      );

      expect(request.method, 'POST');
      expect(
        request.url.path,
        '/apps/annotations/v1/me/notes/note%2F7/certifications/prepared',
      );
      expect(request.headers['cookie'], 'sid=sid-test; csrf=csrf-test');
      expect(request.headers['x-csrf-token'], 'csrf-test');
      expect(jsonDecode(request.body), {
        'title': 'Biology',
        'expected_revision': 9,
        'sources': [
          {
            'kind': 'note_original',
            'revision_id': 'revision-original-3',
            'selection_kind': 'pages',
            'selection_spec': '2-4',
          },
        ],
        'config': {'language': 'pt-BR', 'count': 12},
      });
      expect(study.id, 'study-1');
      expect(study.config?.language, 'pt-BR');
      expect(study.config?.count, 12);
    },
  );

  test(
    'setup uses durable GET config instead of the create response',
    () async {
      final requests = <http.Request>[];
      final service = PreparedCertificationService(
        api: ApiAdapter(
          base: 'https://api.test',
          client: MockClient((request) async {
            requests.add(request);
            if (request.method == 'POST') {
              return http.Response(
                jsonEncode({
                  'study': {
                    'id': 'study-2',
                    'title': 'Study',
                    'status': 'draft',
                    'config': {'language': 'en', 'count': 10},
                  },
                }),
                201,
              );
            }
            return http.Response(
              jsonEncode({
                'id': 'study-2',
                'title': 'Study',
                'status': 'draft',
                'config': {'language': 'th', 'count': 18},
              }),
              200,
            );
          }),
        ),
        session: session,
      );

      final resumed = await service.prepare(
        noteId: 'note-2',
        title: 'Study',
        expectedRevision: 1,
        sources: const [PreparedCertificationSource(kind: 'note_typed')],
        config: const PreparedCertificationConfig(language: 'th', count: 18),
      );
      expect(requests.map((request) => request.method), ['POST', 'GET']);
      expect(requests.last.url.path, '/apps/certifications/v1/studies/study-2');
      expect(resumed.config?.language, 'th');
      expect(resumed.config?.count, 18);
    },
  );

  test('does not continue when the server has not saved the config', () async {
    var calls = 0;
    final service = PreparedCertificationService(
      api: ApiAdapter(
        base: 'https://api.test',
        client: MockClient((request) async {
          calls++;
          if (request.method == 'POST') {
            return http.Response(
              jsonEncode({
                'study': {
                  'id': 'study-3',
                  'title': 'Study',
                  'status': 'draft',
                  'config': {'language': 'pt-BR', 'count': 8},
                },
              }),
              201,
            );
          }
          return http.Response(
            jsonEncode({
              'data': {
                'id': 'study-3',
                'title': 'Study',
                'status': 'draft',
                'config': null,
              },
            }),
            200,
          );
        }),
      ),
      session: session,
    );

    await expectLater(
      service.prepare(
        noteId: 'note-3',
        title: 'Study',
        expectedRevision: 1,
        sources: const [PreparedCertificationSource(kind: 'note_original')],
        config: const PreparedCertificationConfig(language: 'pt-BR', count: 8),
      ),
      throwsA(isA<PreparedCertificationPersistenceException>()),
    );
    expect(calls, 2);
  });

  test('rejects invalid durable config', () async {
    final service = PreparedCertificationService(
      api: ApiAdapter(
        base: 'https://api.test',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'id': 'study-4',
              'title': 'Study',
              'status': 'draft',
              'config': {'language': 'fr', 'count': 0},
            }),
            200,
          ),
        ),
      ),
      session: session,
    );

    await expectLater(service.read('study-4'), throwsFormatException);
  });

  test(
    'uploads only a selected local attachment after owner lookup misses',
    () async {
      final requests = <http.Request>[];
      final service = PreparedCertificationService(
        api: ApiAdapter(
          base: 'https://api.test/apps/annotations/v1',
          client: MockClient((request) async {
            requests.add(request);
            if (request.method == 'GET') {
              return http.Response('{"error":"not found"}', 404);
            }
            if (request.method == 'POST') {
              expect(jsonDecode(request.body)['purpose'], 'attachment');
              return http.Response('{"file_id":"server-file-1"}', 201);
            }
            return http.Response('{"status":"ready"}', 200);
          }),
        ),
        session: session,
      );

      final fileId = await service.prepareAttachmentSource(
        fileId: 'local-file-1',
        attachment: const LocalAttachment(
          id: 'local-file-1',
          name: 'selected.pdf',
          type: 'application/pdf',
          size: 3,
          path: 'fixture-copy',
        ),
        bytes: const [1, 2, 3],
      );

      expect(fileId, 'server-file-1');
      expect(requests.map((request) => request.method), ['GET', 'POST', 'PUT']);
      expect(
        requests.first.url.path,
        '/apps/annotations/v1/me/files/local-file-1',
      );
      expect(
        requests.last.url.path,
        '/apps/annotations/v1/me/files/server-file-1/content',
      );
      expect(requests.last.bodyBytes, [1, 2, 3]);
      expect(requests.last.headers['cookie'], 'sid=sid-test; csrf=csrf-test');
    },
  );

  test(
    'catalog exposes exact readable revisions and attached file references',
    () async {
      final service = PreparedCertificationService(
        api: ApiAdapter(
          base: 'https://api.test/apps/annotations/v1',
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'note_id': 'note-5',
                'revision': 7,
                'title': 'Server note title',
                'representations': [
                  {
                    'representation': 'original',
                    'revision_id': 'orig-current-7',
                    'document': {
                      'items': [
                        {
                          'id': 'text-1',
                          'kind': 'text',
                          'spans': [
                            {'text': 'Current server text'},
                          ],
                        },
                        {
                          'id': 'ink-1',
                          'kind': 'stroke',
                          'file_id': 'file-image-1',
                        },
                      ],
                    },
                  },
                  {
                    'representation': 'typed',
                    'revision_id': 'typed-current-7',
                    'document': {
                      'blocks': [
                        {
                          'id': 'heading-1',
                          'kind': 'heading',
                          'spans': [
                            {'text': 'Typed text'},
                          ],
                        },
                        {'id': 'ink-2', 'kind': 'handwriting'},
                        {
                          'id': 'card-1',
                          'kind': 'task_card',
                          'file_id': 'file-card-1',
                        },
                      ],
                    },
                  },
                ],
              }),
              200,
            ),
          ),
        ),
        session: session,
      );

      final catalog = await service.readNoteSourceCatalog('note-5');

      expect(catalog.revision, 7);
      expect(catalog.title, 'Server note title');
      expect(
        catalog.noteSources.map((source) => (source.kind, source.revisionId)),
        [
          ('note_original', 'orig-current-7'),
          ('note_typed', 'typed-current-7'),
        ],
      );
      expect(catalog.fileIds.toSet(), {'file-image-1', 'file-card-1'});
    },
  );

  test(
    'empty original ink/image revision is not offered as a text source',
    () async {
      final service = PreparedCertificationService(
        api: ApiAdapter(
          base: 'https://api.test/apps/annotations/v1',
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'revision': 8,
                'representations': [
                  {
                    'representation': 'original',
                    'revision_id': 'orig-ink-only-8',
                    'document': {
                      'items': [
                        {'kind': 'stroke'},
                        {'kind': 'image', 'file_id': 'image-2'},
                      ],
                    },
                  },
                ],
              }),
              200,
            ),
          ),
        ),
        session: session,
      );

      final catalog = await service.readNoteSourceCatalog('note-6');

      expect(catalog.noteSources, isEmpty);
      expect(catalog.fileIds, ['image-2']);
    },
  );
}
