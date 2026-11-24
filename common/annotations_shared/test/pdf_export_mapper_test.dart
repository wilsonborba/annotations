import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:annotations_shared/domain/models/ink.dart';
import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/editor_rules.dart';
import 'package:annotations_shared/domain/services/pdf_export_mapper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'note_capacity_test.dart' show handwriting;
import 'pdf_raster.dart';

/// A straight red pen line captured with the real editor capture code, as
/// the app stores it: Bezier nodes in hundredths, no x/y/height.
Map<String, Object?> redLine(
  String id,
  double x0,
  double y0,
  double x1,
  double y1,
) {
  final capture = StrokeCapture(
    const BrushSettings(tool: InkTool.round, width: 3, color: '#DC2626FF'),
    pageWidth: 1000,
  );
  for (var k = 0; k <= 20; k++) {
    final a = k / 20;
    capture.add(x0 + (x1 - x0) * a, y0 + (y1 - y0) * a, 1000 + k * 8);
  }
  return capture.toItem(id)!;
}

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
            'kind': 'reports_embed',
            'x': 20,
            'y': 220,
            'width': 300,
            'height': 80,
            'report_id': 'secret_chart_99',
            'mode': 'snapshot',
            'source': 'upload',
            'snapshot_id': 'snapshot_99',
            'captured_at': 1795520000,
          },
        ],
      }, schema: origSchema);

      // Personal export reports the unavailable chart as a marked placeholder.
      final personalRes = await mapper.export(
        title: 'Mixed Note',
        slug: 'mixed-note',
        original: mixedDoc,
        options: const PdfExportOptions(
          mode: PdfExportMode.original,
          audience: PdfAudience.personal,
          continueWithPlaceholders: true,
        ),
        failedChartIds: const {'secret_chart_99'},
        baseFont: baseFont,
        thaiFont: thaiFont,
      );
      final personalText = await extractPdfText(
        personalRes.pdfs.first.bytes,
        'mixed_personal',
      );
      expect(
        personalText.replaceAll(RegExp(r'\s+'), ''),
        contains('Reportsnapshotunavailable(markedplaceholder)'),
      );
      expect(personalRes.preflight.hasPrivateChartWarning, isTrue);
      expect(personalRes.preflight.issues, hasLength(1));

      // Public audience must redact the private chart and contain no raster image XObjects.
      final publicRes = await mapper.export(
        title: 'Mixed Note',
        slug: 'mixed-note',
        original: mixedDoc,
        options: const PdfExportOptions(
          mode: PdfExportMode.original,
          audience: PdfAudience.public,
          continueWithPlaceholders: true,
        ),
        failedChartIds: const {'secret_chart_99'},
        baseFont: baseFont,
        thaiFont: thaiFont,
      );
      expect(publicRes.preflight.hasPrivateChartWarning, isFalse);
      expect(publicRes.pdfs.length, 1);
      final mixedBytes = publicRes.pdfs.first.bytes;
      expect(utf8.decode(mixedBytes.sublist(0, 5)), '%PDF-');
      expect(
        latin1.decode(mixedBytes, allowInvalid: true),
        isNot(contains('/Subtype /Image')),
      );

      final publicText = await extractPdfText(mixedBytes, 'mixed_public');
      expect(publicText, contains('Mixed note heading'));
      expect(publicText, contains('Restricted content (lock notice)'));
      expect(
        publicText.replaceAll(RegExp(r'\s+'), ''),
        isNot(contains('CONFIDENTIAL_METRIC_SHOULD_NOT_APPEAR')),
      );
    },
  );

  test(
    'preflight identifies failed Reports snapshots and unavailable fonts',
    () {
      final doc = NoteDocument.fromJson({
        'page': {
          'width': 1000,
          'background': {'kind': 'blank'},
        },
        'items': [
          {
            'id': 'report-card',
            'kind': 'reports_embed',
            'report_id': 'report-1',
            'mode': 'snapshot',
            'source': 'upload',
            'snapshot_id': 'snapshot-1',
            'captured_at': 1795520000,
            'x': 20,
            'y': 20,
            'width': 300,
            'height': 80,
          },
        ],
      }, schema: origSchema);

      final preflight = PdfExportMapper.preflight(
        original: doc,
        typed: null,
        options: const PdfExportOptions(audience: PdfAudience.personal),
        failedChartIds: const {'report-1'},
        fontsAvailable: false,
      );

      expect(preflight.issues.map((issue) => issue.kind).toSet(), {
        'failed_chart',
        'missing_font',
      });
      expect(preflight.hasPrivateChartWarning, isTrue);
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
      // The handwriting itself is on the page: dark pixels below the title,
      // around the stroke's place (x 63..81, y 50..70 in page units).
      final raster = await PdfRaster.page(inkRes.pdfs.first.bytes);
      var ink = 0;
      for (var y = 80; y < 130; y++) {
        for (var x = 40; x < 110; x++) {
          final (r, g, b) = raster.at(x, y);
          if (r < 120 && g < 120 && b < 120) ink++;
        }
      }
      expect(ink, greaterThan(15), reason: 'no handwriting pixels drawn');
    },
  );

  group('Original ink is drawn from the stored nodes (annotations#42)', () {
    final format = PdfPageFormat.a4;
    final scale = (format.width - PdfExportMapper.marginPt * 2) / 1000;

    Future<PdfRaster> render(List<Map<String, Object?>> items) async {
      final doc = NoteDocument.fromJson({
        'page': {
          'width': 1000,
          'background': {'kind': 'blank'},
        },
        'items': items,
      }, schema: origSchema);
      final out = await PdfExportMapper().export(
        title: 'Ink',
        slug: 'ink',
        original: doc,
        options: const PdfExportOptions(mode: PdfExportMode.original),
        baseFont: loadFont(
          'lib/presentation/frontend/assets/fonts/UbuntuSans-Variable.ttf',
        ),
        thaiFont: loadFont(
          'lib/presentation/frontend/assets/fonts/IBMPlexSansThai-Regular.ttf',
        ),
      );
      expect(out.pdfs, hasLength(1));
      return PdfRaster.page(out.pdfs.first.bytes);
    }

    test('a stroke lands at its own place, length and color', () async {
      final a = (await render([redLine('s1', 100, 100, 500, 100)])).box(isRed);
      expect(a, isNotNull, reason: 'the stored stroke is not drawn at all');
      final (l, t, r, b) = a!;
      expect(l, closeTo(PdfExportMapper.marginPt + 100 * scale, 3));
      expect(r - l, closeTo(400 * scale, 4));
      expect(b - t, lessThan(6));

      // The same line 200 units lower prints 200 scaled units lower.
      final moved = (await render([
        redLine('s1', 100, 300, 500, 300),
      ])).box(isRed)!;
      expect(moved.$2 - t, closeTo(200 * scale, 2));
      expect(moved.$1, closeTo(l, 1));
    });

    test('ink on a later page prints at the top of that page', () async {
      final doc = NoteDocument.fromJson({
        'page': {
          'width': 1000,
          'background': {'kind': 'blank'},
        },
        'items': [
          {
            'id': 't1',
            'kind': 'text',
            'x': 96,
            'y': 32,
            'width': 320,
            'height': 32,
            'spans': [
              {'text': 'Top'},
            ],
          },
          redLine('s2', 100, 2000, 500, 2000),
        ],
      }, schema: origSchema);
      final out = await PdfExportMapper().export(
        title: 'Ink',
        slug: 'ink',
        original: doc,
        options: const PdfExportOptions(mode: PdfExportMode.original),
        baseFont: loadFont(
          'lib/presentation/frontend/assets/fonts/UbuntuSans-Variable.ttf',
        ),
        thaiFont: loadFont(
          'lib/presentation/frontend/assets/fonts/IBMPlexSansThai-Regular.ttf',
        ),
      );
      expect((await PdfRaster.page(out.pdfs.first.bytes)).box(isRed), isNull);
      final second = (await PdfRaster.page(
        out.pdfs.first.bytes,
        page: 2,
      )).box(isRed);
      expect(second, isNotNull, reason: 'the stroke is not on page 2');
      expect(second!.$2, inInclusiveRange(PdfExportMapper.marginPt, 80));
    });

    test('free text prints at the editor scale, span size and color', () async {
      Future<(int, int, int, int)> red(num size) async => (await render([
        {
          'id': 't1',
          'kind': 'text',
          'x': 96,
          'y': 96,
          'width': 640,
          'height': 64,
          'spans': [
            {'text': 'HHHH', 'size': size, 'color': '#DC2626FF'},
          ],
        },
      ])).box(isRed)!;
      final big = await red(48);
      final small = await red(24);
      // No inset: the glyphs start at the box corner (H has a small bearing).
      expect(big.$1, closeTo(PdfExportMapper.marginPt + 96 * scale, 3));
      // Cap height follows the span size: twice the size, twice the height.
      final hBig = big.$4 - big.$2, hSmall = small.$4 - small.$2;
      expect(hBig, closeTo(48 * scale * 0.69, 2.5));
      expect(hBig / hSmall, closeTo(2, 0.3));
    });

    test('a shape keeps its fill and its line, not a gray box', () async {
      final raster = await render([
        {
          'id': 'sh1',
          'kind': 'shape',
          'shape': 'rectangle',
          'color': '#DC2626FF',
          'line_width': 2,
          'opacity': 1,
          'x': 100,
          'y': 100,
          'width': 200,
          'height': 80,
          'fill': '#FEE2E280',
        },
      ]);
      final line = raster.box(isRed);
      expect(line, isNotNull);
      final (l, t, r, b) = line!;
      expect(r - l, closeTo(200 * scale, 3));
      expect(b - t, closeTo(80 * scale, 3));
      final cx = (l + r) ~/ 2, cy = (t + b) ~/ 2;
      final (pr, pg, pb) = raster.at(cx, cy);
      expect(isPinkFill(pr, pg, pb), isTrue, reason: 'fill is $pr,$pg,$pb');
    });

    test('pagination uses real ink bounds and keeps groups together', () {
      final doc = NoteDocument.fromJson({
        'page': {
          'width': 1000,
          'background': {'kind': 'blank'},
        },
        'items': [
          {
            'id': 't1',
            'kind': 'text',
            'x': 96,
            'y': 32,
            'width': 320,
            'height': 32,
            'spans': [
              {'text': 'Top'},
            ],
          },
          redLine('low', 100, 2000, 400, 2000),
          {
            'id': 't2',
            'kind': 'text',
            'x': 96,
            'y': 864,
            'width': 320,
            'height': 32,
            'spans': [
              {'text': 'Caption'},
            ],
          },
          redLine('under', 100, 980, 400, 1060),
          {
            'id': 'g1',
            'kind': 'group',
            'members': ['t2', 'under'],
          },
        ],
      }, schema: origSchema);
      final pages = PdfExportMapper.planOriginalPages(
        doc,
        printableHeight: 1000,
      );
      List<String> ids(int p) => [
        for (final it in pages[p].items) it['id'] as String,
      ];
      expect(pages, hasLength(3));
      expect(ids(0), ['t1']);
      // The group (caption and the ink under it) moves to the next page
      // together, because its ink reaches past the first page.
      expect(ids(1), ['t2', 'under']);
      expect(ids(2), ['low']);
      expect(pages[2].top, closeTo(2000 - 1.5, 0.01));
    });
  });
}
