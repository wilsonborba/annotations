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

        final originalDoc = NoteDocument.fromJson({
          'page': {
            'width': 1000,
            'background': {'kind': 'blank'},
          },
          'items': [stroke2, stroke1, decorative],
        }, schema: origSchema);
        await store.save(
          LocalNoteDraft(
            id: 'n1',
            schema: origSchema,
            document: originalDoc,
            title: 'Handwritten Note',
          ),
        );
        final originalStoredBefore = jsonEncode(
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
}
