import 'dart:convert';

import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/transcription_draft_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'note_capacity_test.dart' show handwriting;

void main() {
  final origSchema = DocumentSchema(DocumentFamily.original.schemaName, 1);

  test('correction survives a changed-part update and Original strokes stay byte-identical after acceptance', () {
    final stroke1 = Map<String, dynamic>.from(handwriting(1));
    final stroke2 = Map<String, dynamic>.from(handwriting(2));
    final decorative = <String, dynamic>{...handwriting(3), 'decorative': true};

    final originalDoc = NoteDocument.fromJson({
      'page': {'width': 1000, 'background': {'kind': 'blank'}},
      'items': [stroke2, stroke1, decorative],
    }, schema: origSchema);
    final originalJsonBefore = jsonEncode(originalDoc.toJson());

    final service = TranscriptionDraftService();
    final ordered = TranscriptionDraftService.orderForTyped([stroke2, stroke1, decorative]);
    // Decorative mark excluded; stroke1 ordered before stroke2.
    expect(ordered.length, 2);

    final draft = service.saveDraft(
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

    // Owner corrects part 1 and reopens draft.
    service.applyUserCorrection('n1', '${stroke1['id']}', correctedText: 'User Corrected 1');
    expect(service.reopenDraft('n1')!.passages.first.text, 'User Corrected 1');

    // Source changes on stroke2 -> sourceRevision advances to 2.
    final changedStroke2 = <String, dynamic>{...stroke2, 'color': '#222222'};
    service.markSourceChanged('n1', newSourceRevision: 2);
    final toReprocess = service.changedPartIds('n1', [stroke1, changedStroke2]);
    expect(toReprocess, ['${stroke2['id']}']);

    // Stale result from revision 1 is ignored.
    service.applyChangedPartResults(
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
    expect(service.reopenDraft('n1')!.passages.last.text, 'Raw OCR 2');

    // Current revision 2 update applies to stroke2 while preserving user correction on stroke1.
    service.applyChangedPartResults(
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

    final afterUpdate = service.reopenDraft('n1')!;
    expect(afterUpdate.passages.first.text, 'User Corrected 1');
    expect(afterUpdate.passages.last.text, 'Updated OCR 2');

    // Cancel keeps completed draft results.
    expect(service.cancel('n1')!.passages.last.text, 'Updated OCR 2');

    // Accept writes TypedDocument while Original strokes remain byte-identical.
    final typedDoc = service.acceptToTyped('n1');
    expect(typedDoc.toJson()['blocks'], isNotEmpty);
    expect(jsonEncode(originalDoc.toJson()), originalJsonBefore);
  });
}
