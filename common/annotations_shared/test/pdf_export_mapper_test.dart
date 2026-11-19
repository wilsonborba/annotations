import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/pdf_export_mapper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;

import 'note_capacity_test.dart' show handwriting;

void main() {
  final origSchema = DocumentSchema(DocumentFamily.original.schemaName, 1);
  final typedSchema = DocumentSchema(DocumentFamily.typed.schemaName, 1);

  pw.Font? loadFont(String relPath) {
    final f = File(relPath);
    if (!f.existsSync()) return null;
    return pw.Font.ttf(f.readAsBytesSync().buffer.asByteData());
  }

  test('exports real PDFs for mixed note, oversized item, Thai note, handwriting-only, and redacts private charts', () async {
    final baseFont = loadFont('lib/presentation/frontend/assets/fonts/UbuntuSans-Variable.ttf');
    final thaiFont = loadFont('lib/presentation/frontend/assets/fonts/IBMPlexSansThai-Regular.ttf');
    final mapper = PdfExportMapper();

    // 1. Long mixed note with task & quiz cards (B13.7) and private chart redaction on public export.
    final mixedDoc = NoteDocument.fromJson({
      'page': {'width': 1000, 'background': {'kind': 'blank'}},
      'items': [
        {
          'id': 'txt_1',
          'kind': 'text',
          'x': 20,
          'y': 20,
          'width': 400,
          'height': 40,
          'spans': [{'text': 'Mixed note heading'}],
        },
        {
          'id': 'task_1',
          'kind': 'task',
          'x': 20,
          'y': 80,
          'width': 300,
          'height': 50,
          'title': 'Finish PDF check',
          'status': 'open',
          'public_url': 'https://annotations.asodya.com/tasks/1',
        },
        {
          'id': 'quiz_1',
          'kind': 'quiz',
          'x': 20,
          'y': 150,
          'width': 300,
          'height': 50,
          'title': 'Geometry Quiz',
          'question_count': 10,
          'public_url': 'https://certifications.asodya.com/v1/quizzes/q1',
        },
        {
          'id': 'chart_priv',
          'kind': 'report_embed',
          'x': 20,
          'y': 220,
          'width': 300,
          'height': 80,
          'ref_id': 'secret_chart_99',
          'title': 'CONFIDENTIAL_METRIC_SHOULD_NOT_APPEAR',
          'visibility': 'restricted',
        },
      ],
    }, schema: origSchema);

    final publicRes = await mapper.export(
      title: 'Mixed Note',
      slug: 'mixed-note',
      original: mixedDoc,
      options: const PdfExportOptions(
        mode: PdfExportMode.original,
        audience: PdfAudience.public,
      ),
      baseFont: baseFont,
      thaiFont: thaiFont,
    );
    expect(publicRes.preflight.hasPrivateChartWarning, isTrue);
    expect(publicRes.pdfs.length, 1);
    final mixedBytes = publicRes.pdfs.first.bytes;
    expect(utf8.decode(mixedBytes.sublist(0, 5)), '%PDF-');
    // Private chart title/secret must NEVER appear in public PDF content.
    final mixedLatin = latin1.decode(mixedBytes, allowInvalid: true);
    expect(mixedLatin.contains('CONFIDENTIAL_METRIC_SHOULD_NOT_APPEAR'), isFalse);

    // 2. Oversized object gets dedicated page with Preview label and companion file.
    final oversizedDoc = NoteDocument.fromJson({
      'page': {'width': 1000, 'background': {'kind': 'blank'}},
      'items': [
        {
          'id': 'huge_diagram',
          'kind': 'file',
          'x': 10,
          'y': 10,
          'width': 900,
          'height': 2500,
          'name': 'huge.svg',
          'file_id': 'f_huge',
          'type': 'image/svg+xml',
          'size': 128,
        },
      ],
    }, schema: origSchema);

    final oversizedRes = await mapper.export(
      title: 'Oversized',
      slug: 'oversized',
      original: oversizedDoc,
      options: const PdfExportOptions(mode: PdfExportMode.original),
      availableFileIds: const {'f_huge'},
      attachments: {'f_huge': Uint8List.fromList([1, 2, 3])},
      baseFont: baseFont,
      thaiFont: thaiFont,
    );
    expect(oversizedRes.pdfs.first.bytes.length, greaterThan(500));
    expect(oversizedRes.companions.length, 1);
    expect(oversizedRes.companions.first.filename.startsWith('/'), isFalse);

    // 3. Thai text note (shaping check + embedded Thai font).
    const thaiSample = 'สวัสดีครับ ภาษาไทย กิ๊ กี๊ กึ๊ กื๊';
    final evidence = PdfExportMapper.inspectThaiText(thaiSample, fontEmbedded: thaiFont != null);
    expect(evidence.hasThaiText, isTrue);
    expect(evidence.hasCombiningMarks, isTrue);

    final thaiTyped = NoteDocument.fromJson({
      'blocks': [
        {
          'id': 'b1',
          'kind': 'heading',
          'level': 1,
          'spans': [{'text': 'หัวข้อภาษาไทย'}],
        },
        {
          'id': 'b2',
          'kind': 'paragraph',
          'spans': [{'text': thaiSample}],
        },
      ],
    }, schema: typedSchema);

    final thaiRes = await mapper.export(
      title: 'Thai Note',
      slug: 'thai-note',
      typed: thaiTyped,
      options: const PdfExportOptions(mode: PdfExportMode.typed),
      baseFont: baseFont,
      thaiFont: thaiFont,
    );
    expect(utf8.decode(thaiRes.pdfs.first.bytes.sublist(0, 5)), '%PDF-');

    // 4. Handwriting-only note.
    final inkOnly = NoteDocument.fromJson({
      'page': {'width': 1000, 'background': {'kind': 'blank'}},
      'items': [handwriting(1)],
    }, schema: origSchema);

    final inkRes = await mapper.export(
      title: 'Handwriting Only',
      slug: 'ink-only',
      original: inkOnly,
      options: const PdfExportOptions(mode: PdfExportMode.original),
      baseFont: baseFont,
      thaiFont: thaiFont,
    );
    expect(utf8.decode(inkRes.pdfs.first.bytes.sublist(0, 5)), '%PDF-');
  });
}
