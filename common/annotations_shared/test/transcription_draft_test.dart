import 'dart:convert';
import 'dart:io';

import 'package:annotations_shared/dal/local/sqlite_note_store.dart';
import 'package:annotations_shared/domain/models/local_note.dart';
import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/transcription_draft_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'note_capacity_test.dart' show handwriting;

void main() {
  final origSchema = DocumentSchema(DocumentFamily.original.schemaName, 1);

  test(
    'draft persists across new service instances, correction survives changed-part update, stale revision is rejected, and acceptToTypedNote keeps Original strokes byte-identical in SqliteNoteStore',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'annotations_46_test_',
      );
      final store = await SqliteNoteStore.open('${tempDir.path}/notes');
      final draftFile = File('${tempDir.path}/transcription_drafts.json');
      try {
        final stroke1 = Map<String, dynamic>.from(handwriting(1));
        final stroke2 = Map<String, dynamic>.from(handwriting(2));
        final decorative = <String, dynamic>{
          ...handwriting(3),
          'decorative': true,
        };

        final originalDoc =
            NoteDocument.fromJson({
                  'page': {
                    'width': 1000,
                    'background': {'kind': 'blank'},
                  },
                  'items': [stroke2, stroke1, decorative],
                }, schema: origSchema)
                as OriginalDocument;
        await store.save(
          LocalNoteDraft(
            id: 'n1',
            schema: origSchema,
            document: originalDoc,
            title: 'Handwritten Note',
          ),
        );
        var originalStoredBefore = jsonEncode(
          (await store.load('n1'))!.document.toJson(),
        );

        final service1 = TranscriptionDraftService(persistenceFile: draftFile);
        final ordered = TranscriptionDraftService.orderForTyped([
          stroke2,
          stroke1,
          decorative,
        ]);
        expect(ordered.length, 2);

        final draft = service1.saveDraft(
          noteId: 'n1',
          sourceRevision: 1,
          passages: [
            TranscriptionPassage(
              partId: '${stroke1['id']}',
              sourceHash: TranscriptionDraftService.hashPart(stroke1),
              y: 10,
              x: 10,
              kind: TranscriptionPassageKind.text,
              text: 'Raw OCR 1',
              uncertain: true,
            ),
            TranscriptionPassage(
              partId: '${stroke2['id']}',
              sourceHash: TranscriptionDraftService.hashPart(stroke2),
              y: 80,
              x: 10,
              kind: TranscriptionPassageKind.text,
              text: 'Raw OCR 2',
            ),
          ],
        );
        expect(draft.passages.first.uncertain, isTrue);

        // Owner corrects part 1, then closes & reopens in a brand new service instance.
        service1.applyUserCorrection(
          'n1',
          '${stroke1['id']}',
          correctedText: 'User Corrected 1',
        );
        final service2 = TranscriptionDraftService(persistenceFile: draftFile);
        expect(
          service2.reopenDraft('n1')?.passages.first.text,
          'User Corrected 1',
        );
        expect(
          service2.reopenDraft('n1')?.passages.first.userCorrected,
          isTrue,
        );

        // Source changes on stroke2 -> sourceRevision advances to 2.
        final changedStroke2 = <String, dynamic>{
          ...stroke2,
          'color': '#222222',
        };
        await store.save(
          LocalNoteDraft(
            id: 'n1',
            schema: origSchema,
            document: originalDoc.withItems([
              changedStroke2,
              stroke1,
              decorative,
            ]),
            title: 'Handwritten Note',
          ),
        );
        final originalAfterSourceChange = await store.load('n1');
        originalStoredBefore = jsonEncode(
          originalAfterSourceChange!.document.toJson(),
        );
        service2.markSourceChanged('n1', newSourceRevision: 2);
        final toReprocess = service2.changedPartIds('n1', [
          stroke1,
          changedStroke2,
        ]);
        expect(toReprocess, ['${stroke2['id']}']);

        // Stale result from revision 1 is ignored.
        service2.applyChangedPartResults(
          noteId: 'n1',
          resultBaseRevision: 1,
          updatedResultsByPartId: {
            '${stroke2['id']}': TranscriptionPassage(
              partId: '${stroke2['id']}',
              sourceHash: 'old',
              y: 80,
              x: 10,
              kind: TranscriptionPassageKind.text,
              text: 'Stale OCR 2',
            ),
          },
        );
        expect(service2.reopenDraft('n1')!.passages.last.text, 'Raw OCR 2');

        // Current revision 2 update applies to stroke2 while preserving user correction on stroke1.
        service2.applyChangedPartResults(
          noteId: 'n1',
          resultBaseRevision: 2,
          updatedResultsByPartId: {
            '${stroke1['id']}': TranscriptionPassage(
              partId: '${stroke1['id']}',
              sourceHash: TranscriptionDraftService.hashPart(stroke1),
              y: 10,
              x: 10,
              kind: TranscriptionPassageKind.text,
              text: 'Should NOT overwrite user correction',
            ),
            '${stroke2['id']}': TranscriptionPassage(
              partId: '${stroke2['id']}',
              sourceHash: TranscriptionDraftService.hashPart(changedStroke2),
              y: 80,
              x: 10,
              kind: TranscriptionPassageKind.text,
              text: 'Updated OCR 2',
            ),
          },
        );

        final service3 = TranscriptionDraftService(persistenceFile: draftFile);
        final afterUpdate = service3.reopenDraft('n1')!;
        expect(afterUpdate.passages.first.text, 'User Corrected 1');
        expect(afterUpdate.passages.last.text, 'Updated OCR 2');

        // Cancel keeps completed draft results.
        expect(service3.cancel('n1')!.passages.last.text, 'Updated OCR 2');

        // Accept writes Typed note into SqliteNoteStore while Original strokes remain byte-identical.
        final savedTyped = await service3.acceptToTypedNote('n1', store: store);
        expect(savedTyped.schema.family, DocumentFamily.typed);
        expect(savedTyped.document.toJson()['blocks'], isNotEmpty);

        final originalStoredAfter = jsonEncode(
          (await store.load('n1'))!.document.toJson(),
        );
        expect(originalStoredAfter, originalStoredBefore);
      } finally {
        await store.close();
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      }
    },
  );

  test('accepted Keep Ink becomes a real Typed HandwritingBlock', () {
    final stroke = Map<String, Object?>.from(handwriting(44));
    final service = TranscriptionDraftService();
    service.saveDraft(
      noteId: 'ink-note',
      accountId: 'owner-a',
      runId: 'run-1',
      downloadId: 'download-1',
      modelVersion: 'model-1',
      platform: 'linux-x64',
      selectedSourceItemIds: const ['stroke-44'],
      sourceRevision: 0,
      sourceHash: List.filled(64, 'a').join(),
      passages: [
        TranscriptionPassage(
          partId: 'stroke-44',
          sourceHash: List.filled(64, 'b').join(),
          y: 20,
          x: 10,
          kind: TranscriptionPassageKind.inkFallback,
          text: 'recognized text',
          keepAsInk: true,
          preservedData: {
            'width': 240,
            'height': 80,
            'ink': [stroke],
          },
        ),
      ],
    );

    final typed = service.acceptToTyped('ink-note', accountId: 'owner-a');
    final block = typed.toJson()['blocks'] as List;
    expect(block, hasLength(1));
    expect(block.single['kind'], 'handwriting');
    expect(block.single['ink'], [stroke]);
    expect(
      TranscriptionDraftService().reopenDraft('ink-note', accountId: 'owner-b'),
      isNull,
    );
  });

  test('Keep Ink fails closed when selected source ink was not retained', () {
    final service = TranscriptionDraftService();
    service.saveDraft(
      noteId: 'missing-ink',
      sourceRevision: 0,
      passages: [
        TranscriptionPassage(
          partId: 'stroke-missing',
          sourceHash: List.filled(64, 'c').join(),
          y: 0,
          x: 0,
          kind: TranscriptionPassageKind.inkFallback,
          text: '',
          keepAsInk: true,
        ),
      ],
    );

    expect(
      () => service.acceptToTyped('missing-ink'),
      throwsA(isA<UnsupportedTranscriptionStructureException>()),
    );
  });

  test('source change keeps the transcription base identity until update', () {
    final service = TranscriptionDraftService();
    final original = service.saveDraft(
      noteId: 'changed-source',
      sourceRevision: 7,
      sourceHash: List.filled(64, 'd').join(),
      passages: [
        TranscriptionPassage(
          partId: 'part-1',
          sourceHash: List.filled(64, 'e').join(),
          y: 0,
          x: 0,
          kind: TranscriptionPassageKind.text,
          text: 'saved text',
        ),
      ],
    );
    final changed = service.markSourceChanged(
      'changed-source',
      newSourceRevision: 8,
      newSourceHash: List.filled(64, 'f').join(),
    );
    expect(changed.sourceRevision, 7);
    expect(changed.baseSourceHash, original.baseSourceHash);
    expect(changed.currentSourceRevision, 8);
    expect(changed.currentSourceHash, List.filled(64, 'f').join());
    final applied = service.applyChangedPartResults(
      noteId: 'changed-source',
      resultBaseRevision: 8,
      updatedResultsByPartId: const {},
    );
    expect(applied.sourceRevision, 8);
    expect(applied.baseSourceHash, 'f' * 64);
    expect(applied.currentSourceRevision, isNull);
    expect(applied.needsReview, isFalse);
  });

  test('saving recovered run output preserves source-change review state', () {
    final service = TranscriptionDraftService();
    service.saveDraft(
      noteId: 'recovered-run',
      accountId: 'owner-a',
      runId: 'run-1',
      sourceRevision: 7,
      sourceHash: 'd' * 64,
      passages: const [],
    );
    service.markSourceChanged(
      'recovered-run',
      accountId: 'owner-a',
      newSourceRevision: 8,
      newSourceHash: 'f' * 64,
    );

    final recovered = service.saveRecognizedPassages('recovered-run', [
      TranscriptionPassage(
        partId: 'part-1',
        sourceHash: 'e' * 64,
        y: 1,
        x: 2,
        kind: TranscriptionPassageKind.text,
        text: 'Recovered result',
      ),
    ], accountId: 'owner-a');

    expect(recovered.runId, 'run-1');
    expect(recovered.sourceRevision, 7);
    expect(recovered.baseSourceHash, 'd' * 64);
    expect(recovered.currentSourceRevision, 8);
    expect(recovered.currentSourceHash, 'f' * 64);
    expect(recovered.needsReview, isTrue);
    expect(recovered.passages.single.text, 'Recovered result');
    expect(service.reopenDraft('recovered-run', accountId: 'owner-b'), isNull);
  });

  test('accepted structured passages keep their actual Typed block kinds', () {
    final service = TranscriptionDraftService();
    final table = <String, Object?>{
      'id': 'table-1',
      'kind': 'table',
      'header': true,
      'rows': [
        {
          'cells': [
            {
              'spans': [
                {'text': 'Month'},
              ],
            },
            {
              'spans': [
                {'text': 'Sales'},
              ],
            },
          ],
        },
        {
          'cells': [
            {
              'spans': [
                {'text': 'Jan'},
              ],
            },
            {
              'spans': [
                {'text': '15'},
              ],
            },
          ],
        },
      ],
    };
    service.saveDraft(
      noteId: 'structured',
      sourceRevision: 1,
      passages: [
        TranscriptionPassage(
          partId: 'table-source',
          sourceHash: 'table-hash',
          y: 1,
          x: 0,
          kind: TranscriptionPassageKind.table,
          text: '',
          preservedData: {
            'typed_blocks': [table],
          },
        ),
      ],
    );

    final blocks =
        service.acceptToTyped('structured').toJson()['blocks'] as List;
    expect(blocks, [table]);
    expect(blocks.single['kind'], 'table');
  });

  test(
    'correction and pending feedback commit together or neither does',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'annotations_feedback_atomic_',
      );
      final file = File('${tempDir.path}/drafts.json');
      try {
        final service = TranscriptionDraftService(persistenceFile: file);
        service.saveDraft(
          noteId: 'atomic',
          accountId: 'owner-a',
          runId: 'run-atomic',
          sourceRevision: 1,
          passages: [
            TranscriptionPassage(
              partId: 'part-a',
              sourceHash: 'source-a',
              y: 0,
              x: 0,
              kind: TranscriptionPassageKind.text,
              text: 'suggestion',
            ),
          ],
        );
        final firstEvent = <String, Object?>{
          'event_id': 'event-first',
          'segment_id': 'part-a',
          'correction': 'first correction',
          'stage': 'intermediate',
        };
        service.applyCorrectionWithPendingFeedback(
          'atomic',
          'part-a',
          accountId: 'owner-a',
          correctedText: 'first correction',
          event: firstEvent,
        );
        final committed = TranscriptionDraftService(
          persistenceFile: file,
        ).reopenDraft('atomic', accountId: 'owner-a')!;
        expect(committed.passages.single.text, 'first correction');
        expect(committed.pendingFeedbackEvents, [firstEvent]);
        final staleRunAck = service.acknowledgePendingFeedback(
          'atomic',
          'event-first',
          accountId: 'owner-a',
          expectedRunId: 'replaced-run',
          expectedSourceRevisionId: null,
          expectedSourceHash: null,
        );
        expect(staleRunAck.pendingFeedbackEvents, [firstEvent]);

        // Force the next atomic-file replacement to fail before the rename.
        await Directory('${file.path}.writing').create();
        final secondEvent = <String, Object?>{
          'event_id': 'event-second',
          'segment_id': 'part-a',
          'correction': 'second correction',
          'stage': 'intermediate',
        };
        expect(
          () => service.applyCorrectionWithPendingFeedback(
            'atomic',
            'part-a',
            accountId: 'owner-a',
            correctedText: 'second correction',
            event: secondEvent,
          ),
          throwsA(isA<FileSystemException>()),
        );
        final afterFailure = service.reopenDraft(
          'atomic',
          accountId: 'owner-a',
        )!;
        expect(afterFailure.passages.single.text, 'first correction');
        expect(afterFailure.pendingFeedbackEvents, [firstEvent]);
        final afterRestart = TranscriptionDraftService(
          persistenceFile: file,
        ).reopenDraft('atomic', accountId: 'owner-a')!;
        expect(afterRestart.passages.single.text, 'first correction');
        expect(afterRestart.pendingFeedbackEvents, [firstEvent]);
      } finally {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      }
    },
  );

  test(
    'accepted Typed stays locally paired with its unchanged Original',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'annotations_46_pair_test_',
      );
      final store = await SqliteNoteStore.open('${tempDir.path}/notes');
      try {
        final original = NoteDocument.fromJson({
          'page': {
            'width': 1000,
            'background': {'kind': 'blank'},
          },
          'items': [handwriting(71)],
        }, schema: origSchema);
        final savedOriginal = await store.save(
          LocalNoteDraft(
            id: 'private-original',
            schema: origSchema,
            document: original,
            title: 'Source',
          ),
        );
        final sourceBytes = jsonEncode(savedOriginal.document.toJson());
        final drafts = TranscriptionDraftService(
          persistenceFile: File('${tempDir.path}/drafts.json'),
        );
        drafts.saveDraft(
          noteId: 'private-original',
          accountId: 'owner-a',
          runId: 'run-a',
          downloadId: 'download-a',
          modelVersion: 'release-a',
          platform: 'linux-x64',
          selectedSourceItemIds: const ['s71'],
          selectedInkDocument: {
            'items': [handwriting(71)],
          },
          schemaVersion: 1,
          language: 'en',
          sourceRevision: savedOriginal.revision,
          sourceHash: List.filled(64, 'a').join(),
          passages: [
            TranscriptionPassage(
              partId: 'segment-71',
              sourceItemIds: const ['s71'],
              sourceHash: List.filled(64, 'b').join(),
              y: 1,
              x: 1,
              kind: TranscriptionPassageKind.text,
              text: 'Corrected text',
            ),
          ],
        );

        await expectLater(
          drafts.acceptToTypedNote(
            'private-original',
            store: store,
            accountId: 'owner-b',
          ),
          throwsStateError,
        );
        final typed = await drafts.acceptToTypedNote(
          'private-original',
          store: store,
          accountId: 'owner-a',
        );
        final loadedTyped = (await store.load(typed.id))!;
        expect(loadedTyped.transcriptionSourceNoteId, 'private-original');
        expect(loadedTyped.transcriptionRunId, 'run-a');
        expect(
          loadedTyped.transcriptionSourceHash,
          List.filled(64, 'a').join(),
        );
        expect(
          loadedTyped.transcriptionSourceLocalRevision,
          savedOriginal.revision,
        );
        expect(loadedTyped.accountId, 'owner-a');
        expect(
          jsonEncode((await store.load('private-original'))!.document.toJson()),
          sourceBytes,
        );
      } finally {
        await store.close();
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      }
    },
  );

  test(
    'another owner cannot overwrite a Typed pair for the same unbound Original',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'annotations_46_typed_owner_',
      );
      final store = await SqliteNoteStore.open('${tempDir.path}/notes');
      try {
        final originalDocument =
            NoteDocument.fromJson({
                  'page': {
                    'width': 1000,
                    'background': {'kind': 'blank'},
                  },
                  'items': [handwriting(91)],
                }, schema: origSchema)
                as OriginalDocument;
        final original = await store.save(
          LocalNoteDraft(
            id: 'shared-local-original',
            schema: origSchema,
            document: originalDocument,
            title: 'Original',
          ),
        );
        final originalBytes = jsonEncode(original.document.toJson());
        final drafts = TranscriptionDraftService(
          persistenceFile: File('${tempDir.path}/drafts.json'),
        );
        void savePassage(String owner, String text) {
          drafts.saveDraft(
            noteId: original.id,
            accountId: owner,
            runId: 'run-$owner',
            sourceRevision: original.revision,
            passages: [
              TranscriptionPassage(
                partId: 'transcribed-part',
                sourceHash: 'source-part-hash',
                y: 1,
                x: 1,
                kind: TranscriptionPassageKind.text,
                text: text,
              ),
            ],
          );
        }

        savePassage('owner-a', 'Owner A typed text');
        final typedByA = await drafts.acceptToTypedNote(
          original.id,
          store: store,
          accountId: 'owner-a',
        );
        expect(typedByA.accountId, 'owner-a');
        expect(typedByA.transcriptionSourceNoteId, original.id);
        final typedBytesBeforeB = jsonEncode(typedByA.document.toJson());
        final typedRevisionBeforeB = typedByA.revision;

        savePassage('owner-b', 'Owner B must not replace this');
        await expectLater(
          drafts.acceptToTypedNote(
            original.id,
            store: store,
            accountId: 'owner-b',
          ),
          throwsStateError,
        );

        final typedAfterB = (await store.load(typedByA.id))!;
        expect(typedAfterB.accountId, 'owner-a');
        expect(typedAfterB.revision, typedRevisionBeforeB);
        expect(jsonEncode(typedAfterB.document.toJson()), typedBytesBeforeB);
        final originalAfterB = (await store.load(original.id))!;
        expect(originalAfterB.accountId, isNull);
        expect(jsonEncode(originalAfterB.document.toJson()), originalBytes);

        savePassage('owner-a', 'Owner A updated their Typed text');
        final typedUpdatedByA = await drafts.acceptToTypedNote(
          original.id,
          store: store,
          accountId: 'owner-a',
        );
        expect(typedUpdatedByA.accountId, 'owner-a');
        expect(typedUpdatedByA.transcriptionSourceNoteId, original.id);
        expect(typedUpdatedByA.revision, typedRevisionBeforeB + 1);
        expect(
          (await store.load(original.id))!.document.toJson(),
          original.document.toJson(),
        );
      } finally {
        await store.close();
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      }
    },
  );

  test(
    'concurrent first accepts cannot claim one unbound Typed pair for two owners',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'annotations_46_typed_race_',
      );
      final store = await SqliteNoteStore.open('${tempDir.path}/notes');
      try {
        final source = await store.save(
          LocalNoteDraft(
            id: 'racing-original',
            schema: origSchema,
            document:
                NoteDocument.fromJson({
                      'page': {
                        'width': 1000,
                        'background': {'kind': 'blank'},
                      },
                      'items': [handwriting(92)],
                    }, schema: origSchema)
                    as OriginalDocument,
            title: 'Original',
          ),
        );
        final sourceBytes = jsonEncode(source.document.toJson());
        final drafts = TranscriptionDraftService(
          persistenceFile: File('${tempDir.path}/drafts.json'),
        );
        for (final (owner, text) in [
          ('owner-a', 'Owner A result'),
          ('owner-b', 'Owner B result'),
        ]) {
          drafts.saveDraft(
            noteId: source.id,
            accountId: owner,
            runId: 'run-$owner',
            sourceRevision: source.revision,
            passages: [
              TranscriptionPassage(
                partId: 'source-part',
                sourceHash: 'source-hash',
                y: 1,
                x: 1,
                kind: TranscriptionPassageKind.text,
                text: text,
              ),
            ],
          );
        }

        Future<(String, LocalNote?, Object?)> accept(String owner) async {
          try {
            return (
              owner,
              await drafts.acceptToTypedNote(
                source.id,
                store: store,
                accountId: owner,
              ),
              null,
            );
          } on Object catch (error) {
            return (owner, null, error);
          }
        }

        final outcomes = await Future.wait([
          accept('owner-a'),
          accept('owner-b'),
        ]);
        final succeeded = outcomes.where((outcome) => outcome.$2 != null);
        final rejected = outcomes.where((outcome) => outcome.$3 != null);
        expect(succeeded, hasLength(1));
        expect(rejected, hasLength(1));
        expect(rejected.single.$3, isA<StateError>());

        final winner = succeeded.single;
        final typed = (await store.load('racing-original__typed'))!;
        expect(typed.accountId, winner.$1);
        expect(typed.transcriptionSourceNoteId, source.id);
        final typedJson = typed.document.toJson();
        expect(
          jsonEncode(typedJson),
          contains(
            winner.$1 == 'owner-a' ? 'Owner A result' : 'Owner B result',
          ),
        );
        final originalAfter = (await store.load(source.id))!;
        expect(originalAfter.accountId, isNull);
        expect(jsonEncode(originalAfter.document.toJson()), sourceBytes);
      } finally {
        await store.close();
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      }
    },
  );

  test(
    'accept rejects an Original revision that changes after it is loaded',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'annotations_46_typed_source_race_',
      );
      final store = await SqliteNoteStore.open('${tempDir.path}/notes');
      try {
        final source = await store.save(
          LocalNoteDraft(
            id: 'changing-original',
            schema: origSchema,
            document:
                NoteDocument.fromJson({
                      'page': {
                        'width': 1000,
                        'background': {'kind': 'blank'},
                      },
                      'items': [handwriting(93)],
                    }, schema: origSchema)
                    as OriginalDocument,
            title: 'Original',
          ),
        );
        final drafts = TranscriptionDraftService(
          persistenceFile: File('${tempDir.path}/drafts.json'),
        );
        drafts.saveDraft(
          noteId: source.id,
          accountId: 'owner-a',
          runId: 'run-a',
          sourceRevision: source.revision,
          passages: const [
            TranscriptionPassage(
              partId: 'source-part',
              sourceHash: 'source-hash',
              y: 1,
              x: 1,
              kind: TranscriptionPassageKind.text,
              text: 'Stale transcription',
            ),
          ],
        );

        final pendingAccept = drafts.acceptToTypedNote(
          source.id,
          store: store,
          accountId: 'owner-a',
        );
        final changedDocument =
            NoteDocument.fromJson({
                  'page': {
                    'width': 1000,
                    'background': {'kind': 'blank'},
                  },
                  'items': [handwriting(94)],
                }, schema: origSchema)
                as OriginalDocument;
        final updatedSource = await store.save(
          LocalNoteDraft(
            id: source.id,
            schema: origSchema,
            document: changedDocument,
            title: 'Original',
          ),
        );
        expect(updatedSource.revision, source.revision + 1);

        await expectLater(pendingAccept, throwsStateError);
        expect(await store.load('${source.id}__typed'), isNull);
        expect(
          (await store.load(source.id))!.document.toJson(),
          changedDocument.toJson(),
        );
      } finally {
        await store.close();
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      }
    },
  );
}
