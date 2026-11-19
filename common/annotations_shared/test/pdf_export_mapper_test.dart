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

  Future<String> extractPdfText(Uint8List pdfBytes, String name) async {
    final dir = await Directory.systemTemp.createTemp('pdf_text_check_');
    try {
      final pdfFile = File('${dir.path}/$name.pdf')..writeAsBytesSync(pdfBytes);
      final dumpDir = Platform.environment['ANNOTATIONS_PDF_DUMP_DIR'];
      if (dumpDir != null && dumpDir.isNotEmpty) {
        Directory(dumpDir).createSync(recursive: true);
        pdfFile.copySync('$dumpDir/$name.pdf');
      }
      final res = Process.runSync('pdftotext', [pdfFile.path, '-']);
      expect(res.exitCode, 0, reason: 'pdftotext failed: ${res.stderr}');
      return '${res.stdout}';
    } finally {
      dir.deleteSync(recursive: true);
    }
  }

  test(
    'public export redacts private charts (verified via pdftotext and no image XObject)',
    () async {
      final baseFont = loadFont(
        'lib/presentation/frontend/assets/fonts/UbuntuSans-Variable.ttf',
      );
      final thaiFont = loadFont(
        'lib/presentation/frontend/assets/fonts/IBMPlexSansThai-Regular.ttf',
      );
      final mapper = PdfExportMapper();

      final mixedDoc = NoteDocument.fromJson({
        'page': {
          'width': 1000,
          'background': {'kind': 'blank'},
        },
        'items': [
          {
            'id': 'txt_1',
            'kind': 'text',
            'x': 20,
            'y': 20,
            'width': 400,
            'height': 40,
            'spans': [
              {'text': 'Mixed note heading'},
            ],
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

      // Control: personal audience includes the chart title in extracted text.
      final personalRes = await mapper.export(
        title: 'Mixed Note',
        slug: 'mixed-note',
        original: mixedDoc,
        options: const PdfExportOptions(
          mode: PdfExportMode.original,
          audience: PdfAudience.personal,
        ),
        baseFont: baseFont,
        thaiFont: thaiFont,
      );
      final personalText = await extractPdfText(
        personalRes.pdfs.first.bytes,
        'mixed_personal',
      );
      expect(
        personalText.replaceAll(RegExp(r'\s+'), ''),
        contains('CONFIDENTIAL_METRIC_SHOULD_NOT_APPEAR'),
      );

      // Public audience must redact the private chart and contain no raster image XObjects.
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
      expect(
        latin1.decode(mixedBytes, allowInvalid: true),
        isNot(contains('/Subtype /Image')),
      );

      final publicText = await extractPdfText(mixedBytes, 'mixed_public');
      expect(publicText, contains('Mixed note heading'));
      expect(
        publicText.replaceAll(RegExp(r'\s+'), ''),
        isNot(contains('CONFIDENTIAL_METRIC_SHOULD_NOT_APPEAR')),
      );
    },
  );

  test(
    'oversized object gets dedicated preview page and relative companion file',
    () async {
      final baseFont = loadFont(
        'lib/presentation/frontend/assets/fonts/UbuntuSans-Variable.ttf',
      );
      final thaiFont = loadFont(
        'lib/presentation/frontend/assets/fonts/IBMPlexSansThai-Regular.ttf',
      );
      final mapper = PdfExportMapper();

      final oversizedDoc = NoteDocument.fromJson({
        'page': {
          'width': 1000,
          'background': {'kind': 'blank'},
        },
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
        attachments: {
          'f_huge': Uint8List.fromList([1, 2, 3]),
        },
        baseFont: baseFont,
        thaiFont: thaiFont,
      );
      expect(oversizedRes.pdfs.first.bytes.length, greaterThan(500));
      expect(oversizedRes.companions.length, 1);
      expect(oversizedRes.companions.first.filename.startsWith('/'), isFalse);
      final text = await extractPdfText(
        oversizedRes.pdfs.first.bytes,
        'oversized',
      );
      expect(text, contains('Preview, see full content'));
      expect(text, contains('huge_diagram'));
      expect(text, contains('companion-huge_diagram.json'));
    },
  );

  test(
    'Thai text note embeds IBM Plex Sans Thai and renders selectable Thai text',
    () async {
      final baseFont = loadFont(
        'lib/presentation/frontend/assets/fonts/UbuntuSans-Variable.ttf',
      );
      final thaiFont = loadFont(
        'lib/presentation/frontend/assets/fonts/IBMPlexSansThai-Regular.ttf',
      );
      final mapper = PdfExportMapper();

      const thaiSample = 'สวัสดีครับ ภาษาไทย กิ๊ กี๊ กึ๊ กื๊';
      final evidence = PdfExportMapper.inspectThaiText(
        thaiSample,
        fontEmbedded: thaiFont != null,
      );
      expect(evidence.hasThaiText, isTrue);
      expect(evidence.hasCombiningMarks, isTrue);

      final thaiTyped = NoteDocument.fromJson({
        'blocks': [
          {
            'id': 'b1',
            'kind': 'heading',
            'level': 1,
            'spans': [
              {'text': 'หัวข้อภาษาไทย'},
            ],
          },
          {
            'id': 'b2',
            'kind': 'paragraph',
            'spans': [
              {'text': thaiSample},
            ],
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
      final extracted = await extractPdfText(
        thaiRes.pdfs.first.bytes,
        'thai_note',
      );
      expect(extracted, contains('สวัสดี'));
    },
  );

  test(
    'handwriting-only note renders vector strokes without image XObjects',
    () async {
      final baseFont = loadFont(
        'lib/presentation/frontend/assets/fonts/UbuntuSans-Variable.ttf',
      );
      final thaiFont = loadFont(
        'lib/presentation/frontend/assets/fonts/IBMPlexSansThai-Regular.ttf',
      );
      final mapper = PdfExportMapper();

      final inkOnly = NoteDocument.fromJson({
        'page': {
          'width': 1000,
          'background': {'kind': 'blank'},
        },
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
      expect(
        latin1.decode(inkRes.pdfs.first.bytes, allowInvalid: true),
        isNot(contains('/Subtype /Image')),
      );
      await extractPdfText(inkRes.pdfs.first.bytes, 'ink_only');
    },
  );
}
