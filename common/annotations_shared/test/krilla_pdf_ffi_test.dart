import 'dart:io';
import 'dart:typed_data';

import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/krilla_pdf_backend.dart';
import 'package:annotations_shared/domain/services/pdf_export_mapper.dart';
import 'package:flutter_test/flutter_test.dart';

import 'note_capacity_test.dart' show handwriting;
import 'pdf_export_mapper_test.dart' show redLine;
import 'pdf_raster.dart';

void main() {
  final origSchema = DocumentSchema(DocumentFamily.original.schemaName, 1);
  final typedSchema = DocumentSchema(DocumentFamily.typed.schemaName, 1);

  Uint8List loadFontBytes(String relPath) => File(relPath).readAsBytesSync();

  String extractAndMaybeDump(Uint8List pdfBytes, String name) {
    final dumpDir = Platform.environment['ANNOTATIONS_PDF_DUMP_DIR'];
    if (dumpDir != null && dumpDir.isNotEmpty) {
      Directory(dumpDir).createSync(recursive: true);
      File('$dumpDir/$name.pdf').writeAsBytesSync(pdfBytes);
    }
    final tmpDir = Directory.systemTemp.createTempSync('krilla_ffi_test_');
    try {
      final pdfFile = File('${tmpDir.path}/$name.pdf')
        ..writeAsBytesSync(pdfBytes);
      final res = Process.runSync('pdftotext', [pdfFile.path, '-']);
      expect(res.exitCode, 0, reason: 'pdftotext failed: ${res.stderr}');
      return '${res.stdout}';
    } finally {
      tmpDir.deleteSync(recursive: true);
    }
  }

  bool nativeLibBuiltOnDisk() {
    final repoRoot = Directory.current.parent.parent;
    final defaultLib = File(
      '${repoRoot.path}/native/pdf_krilla/target/release/libpdf_krilla.so',
    );
    if (defaultLib.existsSync()) return true;
    final targetDir = Platform.environment['CARGO_TARGET_DIR'];
    if (targetDir != null && targetDir.isNotEmpty) {
      return File('$targetDir/release/libpdf_krilla.so').existsSync();
    }
    return false;
  }

  test(
    'krilla FFI backend is available and exports Thai, mixed, oversized, and ink PDFs',
    () async {
      final available = await KrillaPdfBackend.isAvailable();
      if (!available && !nativeLibBuiltOnDisk()) {
        markTestSkipped(
          'libpdf_krilla.so is not built; run ./scripts/build_pdf_krilla.sh linux to execute krilla FFI tests.',
        );
        return;
      }
      expect(available, isTrue);

      final regularFont = loadFontBytes(
        'lib/presentation/frontend/assets/fonts/IBMPlexSansThai-Regular.ttf',
      );
      final boldFont = loadFontBytes(
        'lib/presentation/frontend/assets/fonts/IBMPlexSansThai-Bold.ttf',
      );
      final mapper = PdfExportMapper();

      // 1. Thai note (Typed)
      final thaiDoc = NoteDocument.fromJson({
        'blocks': [
          {
            'id': 'h1',
            'kind': 'heading',
            'level': 1,
            'spans': [
              {'text': 'บันทึกภาษาไทย: กิ๊ กี๊ กึ๊ กื๊'},
            ],
          },
          {
            'id': 'p1',
            'kind': 'paragraph',
            'spans': [
              {
                'text':
                    'การบันทึกข้อความภาษาไทยในระบบเอกสารดิจิทัลต้องรองรับการวางตำแหน่งสระและวรรณยุกต์อย่างถูกต้องรวมถึงการตัดคำขึ้นบรรทัดใหม่โดยไม่ตัดกลางคำเพื่อให้ผู้อ่านสามารถอ่านและค้นหาข้อความได้อย่างสมบูรณ์',
              },
            ],
          },
        ],
      }, schema: typedSchema);

      final thaiOut = await mapper.export(
        title: 'Thai Note Export',
        slug: 'thai-note',
        typed: thaiDoc,
        options: const PdfExportOptions(mode: PdfExportMode.typed),
        regularFontBytes: regularFont,
        boldFontBytes: boldFont,
      );
      expect(thaiOut.engine, 'krilla');
      expect(thaiOut.pdfs, hasLength(1));
      final thaiText = extractAndMaybeDump(
        thaiOut.pdfs.first.bytes,
        'thai_note',
      );
      expect(thaiText, contains('กิ๊ กี๊ กึ๊ กื๊'));
      expect(thaiText, contains('ระบบเอกสารดิจิทัล'));

      // 2. Mixed note (public vs personal)
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
            'width': 500,
            'height': 60,
            'spans': [
              {'text': 'Mixed note public summary'},
            ],
          },
          {
            'id': 'chart_pub',
            'kind': 'reports_embed',
            'report_id': 'rep_1',
            'mode': 'snapshot',
            'source': 'link',
            'snapshot_id': 'snap_1',
            'captured_at': 1795520000,
            'x': 20,
            'y': 100,
            'width': 400,
            'height': 120,
          },
          {
            'id': 'chart_priv',
            'kind': 'reports_embed',
            'report_id': 'rep_2',
            'mode': 'snapshot',
            'source': 'upload',
            'snapshot_id': 'snap_2',
            'captured_at': 1795520000,
            'x': 20,
            'y': 240,
            'width': 400,
            'height': 120,
          },
        ],
      }, schema: origSchema);

      final pubOut = await mapper.export(
        title: 'Mixed Public',
        slug: 'mixed-public',
        original: mixedDoc,
        options: const PdfExportOptions(
          mode: PdfExportMode.original,
          audience: PdfAudience.public,
          continueWithPlaceholders: true,
        ),
        failedChartIds: const {'rep_1', 'rep_2'},
        regularFontBytes: regularFont,
        boldFontBytes: boldFont,
      );
      expect(pubOut.engine, 'krilla');
      final pubText = extractAndMaybeDump(
        pubOut.pdfs.first.bytes,
        'mixed_public',
      );
      expect(pubText, contains('Restricted content (lock notice)'));
      expect(pubText, isNot(contains('Secret Revenue Chart')));
      expect(
        String.fromCharCodes(pubOut.pdfs.first.bytes),
        isNot(contains('/Subtype /Image')),
      );

      final persOut = await mapper.export(
        title: 'Mixed Personal',
        slug: 'mixed-personal',
        original: mixedDoc,
        options: const PdfExportOptions(
          mode: PdfExportMode.original,
          audience: PdfAudience.personal,
          continueWithPlaceholders: true,
        ),
        failedChartIds: const {'rep_1', 'rep_2'},
        regularFontBytes: regularFont,
        boldFontBytes: boldFont,
      );
      expect(persOut.engine, 'krilla');
      final persText = extractAndMaybeDump(
        persOut.pdfs.first.bytes,
        'mixed_personal',
      );
      expect(persOut.preflight.hasPrivateChartWarning, isTrue);
      expect(
        persText.replaceAll(RegExp(r'\s+'), ''),
        contains('Reportsnapshotunavailable(markedplaceholder)'),
      );

      // 3. Oversized item
      final oversizedDoc = NoteDocument.fromJson({
        'page': {
          'width': 1000,
          'background': {'kind': 'blank'},
        },
        'items': [
          {
            'id': 'big_table_1',
            'kind': 'file',
            'x': 20,
            'y': 20,
            'width': 900,
            'height': 2400,
            'name': 'huge.svg',
            'file_id': 'f_huge',
            'type': 'image/svg+xml',
            'size': 128,
          },
        ],
      }, schema: origSchema);

      final overOut = await mapper.export(
        title: 'Oversized Note',
        slug: 'oversized',
        original: oversizedDoc,
        options: const PdfExportOptions(mode: PdfExportMode.original),
        availableFileIds: const {'f_huge'},
        attachments: {
          'f_huge': Uint8List.fromList([1, 2, 3]),
        },
        regularFontBytes: regularFont,
        boldFontBytes: boldFont,
      );
      expect(overOut.engine, 'krilla');
      expect(overOut.companions, hasLength(1));
      final overText = extractAndMaybeDump(
        overOut.pdfs.first.bytes,
        'oversized',
      );
      expect(overText, contains('Preview, see full content'));
      expect(overText, contains('companion-big_table_1.json'));

      // 4. Handwriting-only note
      final inkDoc = NoteDocument.fromJson({
        'page': {
          'width': 1000,
          'background': {'kind': 'blank'},
        },
        'items': [handwriting(1)],
      }, schema: origSchema);

      final inkOut = await mapper.export(
        title: 'Ink Only Note',
        slug: 'ink-only',
        original: inkDoc,
        options: const PdfExportOptions(mode: PdfExportMode.original),
        regularFontBytes: regularFont,
        boldFontBytes: boldFont,
      );
      expect(inkOut.engine, 'krilla');
      extractAndMaybeDump(inkOut.pdfs.first.bytes, 'ink_only');
      expect(inkOut.pdfs.first.bytes.length, greaterThan(500));
      // The handwriting itself is drawn, below the title near its place.
      final inkRaster = await PdfRaster.page(inkOut.pdfs.first.bytes);
      var inkPixels = 0;
      for (var y = 80; y < 130; y++) {
        for (var x = 40; x < 110; x++) {
          final (r, g, b) = inkRaster.at(x, y);
          if (r < 120 && g < 120 && b < 120) inkPixels++;
        }
      }
      expect(inkPixels, greaterThan(15), reason: 'no handwriting pixels drawn');

      // 5. A colored stroke and a filled shape keep place, size and color.
      final scale = (595.28 - PdfExportMapper.marginPt * 2) / 1000;
      final colorDoc = NoteDocument.fromJson({
        'page': {
          'width': 1000,
          'background': {'kind': 'blank'},
        },
        'items': [
          redLine('s1', 100, 100, 500, 100),
          {
            'id': 'sh1',
            'kind': 'shape',
            'shape': 'rectangle',
            'color': '#DC2626FF',
            'line_width': 2,
            'opacity': 1,
            'x': 100,
            'y': 300,
            'width': 200,
            'height': 80,
            'fill': '#FEE2E280',
          },
        ],
      }, schema: origSchema);
      final colorOut = await mapper.export(
        title: 'Ink Colors',
        slug: 'ink-colors',
        original: colorDoc,
        options: const PdfExportOptions(mode: PdfExportMode.original),
        regularFontBytes: regularFont,
        boldFontBytes: boldFont,
      );
      expect(colorOut.engine, 'krilla');
      extractAndMaybeDump(colorOut.pdfs.first.bytes, 'ink_colors');
      final colors = await PdfRaster.page(colorOut.pdfs.first.bytes);
      final red = colors.box(isRed);
      expect(red, isNotNull, reason: 'stroke and shape line are not drawn');
      final (l, t, r, b) = red!;
      expect(l, closeTo(PdfExportMapper.marginPt + 100 * scale, 3));
      expect(r - l, closeTo(400 * scale, 4));
      // From the stroke top to the rectangle bottom: 280 units plus the line.
      expect(b - t, closeTo(282 * scale, 4));
      final (fr, fg, fb) = colors.at(
        (PdfExportMapper.marginPt + 200 * scale).round(),
        t + (240 * scale).round(),
      );
      expect(isPinkFill(fr, fg, fb), isTrue, reason: 'fill is $fr,$fg,$fb');
    },
  );

  test('pdf_krilla.wasm exists and is not older than its Rust sources', () {
    final repoRoot = Directory.current.parent.parent;
    final wasm = File(
      '${repoRoot.path}/common/annotations_shared/lib/presentation/frontend/assets/wasm/pdf_krilla.wasm',
    );
    final libRs = File('${repoRoot.path}/native/pdf_krilla/src/lib.rs');
    final cargoToml = File('${repoRoot.path}/native/pdf_krilla/Cargo.toml');

    if (!wasm.existsSync()) {
      markTestSkipped(
        'pdf_krilla.wasm is not built; run ./scripts/build_pdf_krilla.sh wasm to verify wasm output.',
      );
      return;
    }
    final wasmMtime = wasm.lastModifiedSync();
    expect(
      wasmMtime.isBefore(libRs.lastModifiedSync()),
      isFalse,
      reason:
          'pdf_krilla.wasm is older than lib.rs; rebuild with ./scripts/build_pdf_krilla.sh wasm',
    );
    expect(
      wasmMtime.isBefore(cargoToml.lastModifiedSync()),
      isFalse,
      reason:
          'pdf_krilla.wasm is older than Cargo.toml; rebuild with ./scripts/build_pdf_krilla.sh wasm',
    );
  });
}
