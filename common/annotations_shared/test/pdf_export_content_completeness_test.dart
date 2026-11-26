import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:annotations_shared/domain/models/local_note.dart';
import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/local_note_store.dart';
import 'package:annotations_shared/domain/services/krilla_pdf_backend.dart';
import 'package:annotations_shared/domain/services/pdf_export_mapper.dart';
import 'package:annotations_shared/domain/services/task_card_service.dart';
import 'package:annotations_shared/presentation/frontend/handlers/export_handler.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;

import 'note_capacity_test.dart' show handwriting;
import 'pdf_raster.dart';

void main() {
  final paperSchema = DocumentSchema(DocumentFamily.original.schemaName, 1);
  final typedSchema = DocumentSchema(DocumentFamily.typed.schemaName, 1);

  pw.Font? loadFont(String path) {
    final file = File(path);
    if (!file.existsSync()) return null;
    return pw.Font.ttf(file.readAsBytesSync().buffer.asByteData());
  }

  final baseFont = loadFont(
    'lib/presentation/frontend/assets/fonts/UbuntuSans-Variable.ttf',
  );
  final boldFont = loadFont(
    'lib/presentation/frontend/assets/fonts/UbuntuSans-Variable.ttf',
  );
  final thaiFont = loadFont(
    'lib/presentation/frontend/assets/fonts/IBMPlexSansThai-Regular.ttf',
  );
  final logo = File(
    'lib/presentation/frontend/assets/images/asodya_logo.png',
  ).readAsBytesSync();

  PdfExportOptions options({bool continueWithPlaceholders = false}) =>
      PdfExportOptions(
        mode: PdfExportMode.both,
        continueWithPlaceholders: continueWithPlaceholders,
      );

  test(
    'Original and Typed file cards print CSV rows and a PDF page image; export ZIP retains source files',
    () async {
      final sourceCsv = Uint8List.fromList(
        utf8.encode('Name,Value\nCSV_CONTENT_SENTINEL,42\n'),
      );
      final sourcePdfDocument = pw.Document()
        ..addPage(pw.Page(build: (_) => pw.Text('PDF_SOURCE_SENTINEL')));
      final sourcePdf = await sourcePdfDocument.save();
      final original = NoteDocument.fromJson({
        'page': {
          'width': 1000,
          'background': {'kind': 'blank'},
        },
        'items': [
          {
            'id': 'csv-original',
            'kind': 'csv_table',
            'file_id': 'csv-source',
            'x': 20,
            'y': 20,
            'width': 420,
            'height': 180,
          },
          {
            'id': 'pdf-original',
            'kind': 'pdf_preview',
            'file_id': 'pdf-source',
            'x': 20,
            'y': 230,
            'width': 320,
            'height': 360,
          },
        ],
      }, schema: paperSchema);
      final typed = NoteDocument.fromJson({
        'blocks': [
          {'id': 'csv-typed', 'kind': 'csv_table', 'file_id': 'csv-source'},
          {'id': 'pdf-typed', 'kind': 'pdf_preview', 'file_id': 'pdf-source'},
        ],
      }, schema: typedSchema);

      final output = await PdfExportMapper().export(
        title: 'File references',
        slug: 'file-references',
        original: original,
        typed: typed,
        options: const PdfExportOptions(
          mode: PdfExportMode.both,
          continueWithPlaceholders: true,
        ),
        availableFileIds: const {'csv-source', 'pdf-source'},
        attachments: {'csv-source': sourceCsv, 'pdf-source': sourcePdf},
        csvTables: const {
          'csv-source': [
            ['Name', 'Value'],
            ['CSV_CONTENT_SENTINEL', '42'],
          ],
        },
        // In production this is the PNG from the existing first-page PDF
        // renderer. Reuse the real bundled logo bytes as a deterministic
        // raster input to verify the mapper places an image XObject.
        pdfPreviews: {'pdf-source': Uint8List.fromList(logo)},
        baseFont: baseFont,
        boldFont: boldFont,
        thaiFont: thaiFont,
      );

      expect(output.preflight.ok, isTrue);
      expect(output.engine, 'pdf');
      expect(output.pdfs, hasLength(2));
      expect(output.companions, hasLength(2));
      final companionBytes = {
        for (final companion in output.companions)
          companion.filename: companion.bytes,
      };
      expect(companionBytes['source-csv-source.csv'], sourceCsv);
      expect(companionBytes['source-pdf-source.pdf'], sourcePdf);
      for (final file in output.pdfs) {
        final text = await _extractPdfText(file.bytes);
        expect(text, contains('CSV_CONTENT_SENTINEL'));
        expect(text, isNot(contains('CSV file: csv-source')));
        expect(
          latin1.decode(file.bytes, allowInvalid: true),
          contains('/Subtype/Image'),
        );
        final raster = await PdfRaster.page(file.bytes);
        expect(
          raster.count((r, g, b) => r < 245 || g < 245 || b < 245),
          greaterThan(500),
        );
      }
    },
  );

  testWidgets('ExportHandler loads CSV rows and renders attached PDF pages', (
    tester,
  ) async {
    final csvBytes = Uint8List.fromList(
      utf8.encode('Name,Value\nHANDLER_CSV_SENTINEL,42\n'),
    );
    final sourcePdf = await tester.runAsync(() async {
      final document = pw.Document()
        ..addPage(pw.Page(build: (_) => pw.Text('Attached source page')));
      return document.save();
    });
    expect(sourcePdf, isNotNull);
    final renderedSources = <Uint8List>[];
    final noteDocument = NoteDocument.fromJson({
      'page': {
        'width': 1000,
        'background': {'kind': 'blank'},
      },
      'items': [
        {
          'id': 'csv-card',
          'kind': 'csv_table',
          'file_id': 'csv-file',
          'x': 16,
          'y': 16,
          'width': 480,
          'height': 180,
        },
        {
          'id': 'pdf-card',
          'kind': 'pdf_preview',
          'file_id': 'pdf-file',
          'x': 16,
          'y': 220,
          'width': 360,
          'height': 420,
        },
      ],
    }, schema: paperSchema);
    final now = DateTime.utc(2026, 1, 1);
    final note = LocalNote(
      id: 'note-with-references',
      schema: paperSchema,
      document: noteDocument,
      title: 'References',
      revision: 1,
      createdAt: now,
      updatedAt: now,
      syncState: LocalSyncState.local,
      accountId: null,
    );
    final store = _ReferenceNoteStore({
      'csv-file': _StoredBytes('table.csv', 'text/csv', csvBytes),
      'pdf-file': _StoredBytes(
        'source.pdf',
        'application/pdf',
        Uint8List.fromList(sourcePdf!),
      ),
    });
    final handler = ExportHandler(
      note: note,
      store: store,
      renderPdfPage: (bytes, _) async {
        renderedSources.add(Uint8List.fromList(bytes));
        return _onePixelImage();
      },
      renderPages: (_, _) async => [await _onePixelImage()],
    );
    addTearDown(handler.dispose);

    await tester.runAsync(() => handler.build());

    expect(
      handler.stage,
      ExportStage.ready,
      reason:
          'preflight=${handler.preflight?.issues.map((issue) => '${issue.kind}/${issue.refId}: ${issue.message}').join('; ')}',
    );
    expect(handler.output?.preflight.ok, isTrue);
    expect(handler.output?.pdfs, hasLength(1));
    expect(handler.output?.companions, hasLength(2));
    expect(renderedSources, [Uint8List.fromList(sourcePdf)]);
    final pdf = handler.output!.pdfs.single.bytes;
    final pdfText = await tester.runAsync(() => _extractPdfText(pdf));
    expect(pdfText, contains('HANDLER_CSV_SENTINEL'));
    expect(latin1.decode(pdf, allowInvalid: true), contains('/Subtype/Image'));
    final zip = ZipDecoder().decodeBytes(handler.bytes());
    final entries = {
      for (final entry in zip.files)
        if (entry.isFile)
          entry.name: Uint8List.fromList(entry.content as List<int>),
    };
    expect(
      entries.keys,
      containsAll([
        'references-original.pdf',
        'source-csv-file.csv',
        'source-pdf-file.pdf',
      ]),
    );
    expect(entries['source-csv-file.csv'], csvBytes);
    expect(entries['source-pdf-file.pdf'], sourcePdf);
  });

  test(
    'missing or corrupt CSV/PDF references need explicit continuation',
    () async {
      final original = NoteDocument.fromJson({
        'page': {
          'width': 1000,
          'background': {'kind': 'blank'},
        },
        'items': [
          {
            'id': 'missing-csv-card',
            'kind': 'csv_table',
            'file_id': 'missing-csv',
            'x': 20,
            'y': 20,
            'width': 420,
            'height': 140,
          },
          {
            'id': 'corrupt-pdf-card',
            'kind': 'pdf_preview',
            'file_id': 'corrupt-pdf',
            'x': 20,
            'y': 190,
            'width': 320,
            'height': 300,
          },
        ],
      }, schema: paperSchema);
      final corruptPdf = Uint8List.fromList(utf8.encode('not a PDF'));

      final stopped = await PdfExportMapper().export(
        title: 'Unavailable references',
        slug: 'unavailable-references',
        original: original,
        options: const PdfExportOptions(mode: PdfExportMode.original),
        availableFileIds: const {'corrupt-pdf'},
        attachments: {'corrupt-pdf': corruptPdf},
        baseFont: baseFont,
        thaiFont: thaiFont,
      );
      expect(stopped.preflight.ok, isFalse);
      expect(stopped.pdfs, isEmpty);
      expect(
        stopped.preflight.issues.map((issue) => issue.kind),
        containsAll(['missing_file', 'unsupported_content']),
      );

      final continued = await PdfExportMapper().export(
        title: 'Unavailable references',
        slug: 'unavailable-references',
        original: original,
        options: const PdfExportOptions(
          mode: PdfExportMode.original,
          continueWithPlaceholders: true,
        ),
        availableFileIds: const {'corrupt-pdf'},
        attachments: {'corrupt-pdf': corruptPdf},
        baseFont: baseFont,
        thaiFont: thaiFont,
      );
      expect(continued.pdfs, hasLength(1));
      expect(continued.companions, isEmpty);
      final text = await _extractPdfText(continued.pdfs.single.bytes);
      expect(text, contains('CSV content unavailable'));
      expect(text, contains('PDF page preview unavailable'));
      expect(text, isNot(contains('CSV file: missing-csv')));
    },
  );

  test(
    'Paper images and Typed figures print the referenced image pixels',
    () async {
      final original = NoteDocument.fromJson({
        'page': {
          'width': 1000,
          'background': {'kind': 'blank'},
        },
        'items': [
          {
            'id': 'paper-logo',
            'kind': 'image',
            'file_id': 'logo',
            'x': 20,
            'y': 20,
            'width': 180,
            'height': 180,
          },
        ],
      }, schema: paperSchema);
      final typed = NoteDocument.fromJson({
        'blocks': [
          {
            'id': 'typed-logo',
            'kind': 'figure',
            'file_id': 'logo',
            'caption': [
              {'text': 'Typed image caption sentinel'},
            ],
          },
        ],
      }, schema: typedSchema);

      final output = await PdfExportMapper().export(
        title: 'Image export',
        slug: 'image-export',
        original: original,
        typed: typed,
        options: options(),
        availableFileIds: const {'logo'},
        attachments: {'logo': Uint8List.fromList(logo)},
        baseFont: baseFont,
        boldFont: boldFont,
        thaiFont: thaiFont,
      );

      expect(output.engine, 'pdf');
      expect(
        output.preflight.ok,
        isTrue,
        reason: output.preflight.issues
            .map((issue) => '${issue.kind}:${issue.refId}')
            .join(', '),
      );
      expect(output.pdfs, hasLength(2));
      for (final pdf in output.pdfs) {
        expect(
          latin1.decode(pdf.bytes, allowInvalid: true),
          contains('/Subtype/Image'),
        );
        final raster = await PdfRaster.page(pdf.bytes);
        // The bundled mark contains vivid green and purple pixels. Text-only
        // placeholders cannot satisfy this rendered-pixel check.
        expect(
          raster.count((r, g, b) => g > 180 && r < 150 && b < 100),
          greaterThan(20),
        );
        expect(
          raster.count((r, g, b) => r > 100 && b > 180 && g < 100),
          greaterThan(20),
        );
      }
    },
  );

  test(
    'missing and invalid image bytes require explicit marked continuation',
    () async {
      final original = NoteDocument.fromJson({
        'page': {
          'width': 1000,
          'background': {'kind': 'blank'},
        },
        'items': [
          {
            'id': 'missing-image',
            'kind': 'image',
            'file_id': 'missing',
            'x': 20,
            'y': 20,
            'width': 160,
            'height': 100,
          },
          {
            'id': 'bad-image',
            'kind': 'image',
            'file_id': 'bad',
            'x': 20,
            'y': 140,
            'width': 160,
            'height': 100,
          },
        ],
      }, schema: paperSchema);

      final stopped = await PdfExportMapper().export(
        title: 'Missing images',
        slug: 'missing-images',
        original: original,
        options: options(),
        availableFileIds: const {'bad'},
        attachments: {
          'bad': Uint8List.fromList([1, 2, 3]),
        },
        baseFont: baseFont,
        boldFont: boldFont,
        thaiFont: thaiFont,
      );
      expect(stopped.pdfs, isEmpty);
      expect(
        stopped.preflight.issues.map((issue) => issue.kind),
        containsAll(['missing_file', 'unsupported_content']),
      );

      final continued = await PdfExportMapper().export(
        title: 'Missing images',
        slug: 'missing-images',
        original: original,
        options: options(continueWithPlaceholders: true),
        availableFileIds: const {'bad'},
        attachments: {
          'bad': Uint8List.fromList([1, 2, 3]),
        },
        baseFont: baseFont,
        boldFont: boldFont,
        thaiFont: thaiFont,
      );
      expect(continued.pdfs, hasLength(1));
      final text = await _extractPdfText(continued.pdfs.single.bytes);
      expect(continued.pdfs.single.bytes.take(5), [37, 80, 68, 70, 45]);
      final normalizedText = text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
      expect(normalizedText, contains('image unavailable'));
      expect(normalizedText, contains('marked placeholder'));
      expect(
        latin1.decode(continued.pdfs.single.bytes, allowInvalid: true),
        isNot(contains('/Subtype/Image')),
      );
    },
  );

  test(
    'Typed handwriting stays vector and renders its captured stroke',
    () async {
      final stroke = handwriting(7, hz: 24, seconds: 0.2);
      final typed = NoteDocument.fromJson({
        'blocks': [
          {
            'id': 'handwriting-block',
            'kind': 'handwriting',
            'width': 180,
            'height': 100,
            'ink': [stroke],
          },
        ],
      }, schema: typedSchema);

      final output = await PdfExportMapper().export(
        title: 'Vector handwriting',
        slug: 'vector-handwriting',
        typed: typed,
        options: const PdfExportOptions(mode: PdfExportMode.typed),
        baseFont: baseFont,
        boldFont: boldFont,
        thaiFont: thaiFont,
      );
      expect(output.engine, 'pdf');
      expect(output.preflight.ok, isTrue);
      final bytes = output.pdfs.single.bytes;
      expect(
        latin1.decode(bytes, allowInvalid: true),
        isNot(contains('/Subtype/Image')),
      );
      final raster = await PdfRaster.page(bytes);
      expect(
        raster.count((r, g, b) => r < 100 && g < 100 && b < 100),
        greaterThan(15),
      );

      final unsupportedStroke = Map<String, Object?>.from(stroke)
        ..['brush_version'] = 999;
      final unsupported = NoteDocument.fromJson({
        'blocks': [
          {
            'id': 'future-brush-block',
            'kind': 'handwriting',
            'width': 180,
            'height': 100,
            'ink': [unsupportedStroke],
          },
        ],
      }, schema: typedSchema);
      final marked = await PdfExportMapper().export(
        title: 'Unsupported brush',
        slug: 'unsupported-brush',
        typed: unsupported,
        options: const PdfExportOptions(
          mode: PdfExportMode.typed,
          continueWithPlaceholders: true,
        ),
        baseFont: baseFont,
        boldFont: boldFont,
        thaiFont: thaiFont,
      );
      expect(
        marked.preflight.issues.map((issue) => issue.kind),
        contains('unsupported_content'),
      );
      expect(
        await _extractPdfText(marked.pdfs.single.bytes),
        contains('Some handwriting is unavailable'),
      );
    },
  );

  test(
    'legal tall Typed handwriting uses a visible preview page and exact companion',
    () async {
      final stroke = handwriting(8, hz: 24, seconds: 0.2);
      Future<PdfExportOutput> exportHeight(double height) {
        final typed = NoteDocument.fromJson({
          'blocks': [
            {
              'id': 'tall-ink',
              'kind': 'handwriting',
              'width': 180,
              'height': height,
              'ink': [stroke],
            },
          ],
        }, schema: typedSchema);
        return PdfExportMapper().export(
          title: 'Tall handwriting',
          slug: 'tall-handwriting',
          typed: typed,
          options: const PdfExportOptions(mode: PdfExportMode.typed),
          baseFont: baseFont,
          boldFont: boldFont,
          thaiFont: thaiFont,
        );
      }

      final normal = await exportHeight(100);
      expect(normal.preflight.ok, isTrue);
      expect(normal.pdfs, hasLength(1));
      expect(normal.companions, isEmpty);
      expect(
        latin1.decode(normal.pdfs.single.bytes, allowInvalid: true),
        isNot(contains('/Subtype/Image')),
      );
      final normalRaster = await PdfRaster.page(normal.pdfs.single.bytes);
      expect(
        normalRaster.count((r, g, b) => r < 100 && g < 100 && b < 100),
        greaterThan(15),
      );

      final tall = await exportHeight(1000);
      expect(tall.preflight.ok, isTrue);
      expect(tall.pdfs, hasLength(1));
      expect(tall.companions, hasLength(1));
      expect(tall.companions.single.filename, 'companion-typed-tall-ink.json');
      final savedBlock =
          jsonDecode(utf8.decode(tall.companions.single.bytes))
              as Map<String, dynamic>;
      expect(savedBlock['height'], 1000);
      expect(savedBlock['ink'], [stroke]);
      final previewText = await _extractPdfText(tall.pdfs.single.bytes);
      expect(previewText, contains('Preview, see full content'));
      expect(previewText, contains('companion-typed-tall-ink.json'));
      final previewRaster = await PdfRaster.page(tall.pdfs.single.bytes);
      expect(
        previewRaster.count((r, g, b) => r < 230 && g < 230 && b < 230),
        greaterThan(100),
      );
    },
  );

  test(
    'canonical Task card uses owner summary; Quiz card stays marked and private',
    () async {
      final original = NoteDocument.fromJson({
        'page': {
          'width': 1000,
          'background': {'kind': 'blank'},
        },
        'items': [
          {
            'id': 'task-card',
            'kind': 'task_card',
            'task_id': 'task-owner-1',
            'x': 20,
            'y': 20,
            'width': 350,
            'height': 90,
          },
          {
            'id': 'quiz-card',
            'kind': 'quiz_card',
            'quiz_id': 'private-quiz-1',
            'x': 20,
            'y': 130,
            'width': 350,
            'height': 60,
          },
        ],
      }, schema: paperSchema);
      const task = TaskSummary(
        taskId: 'task-owner-1',
        title: 'Saved task title',
        description: 'Saved task description',
        dueDate: '2026-12-01',
        completed: false,
      );

      final personal = await PdfExportMapper().export(
        title: 'Cards',
        slug: 'cards',
        original: original,
        options: const PdfExportOptions(
          mode: PdfExportMode.original,
          continueWithPlaceholders: true,
        ),
        taskSummaries: const {'task-owner-1': task},
        baseFont: baseFont,
        boldFont: boldFont,
        thaiFont: thaiFont,
      );
      final text = await _extractPdfText(personal.pdfs.single.bytes);
      expect(text, contains('Saved task title'));
      expect(text, contains('Saved task description'));
      expect(text, contains('Quiz details unavailable'));
      expect(
        text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), ''),
        contains('privatequiz1'),
      );
      expect(
        personal.preflight.issues.map((issue) => issue.refId),
        contains('private-quiz-1'),
      );

      final public = await PdfExportMapper().export(
        title: 'Cards',
        slug: 'cards',
        original: original,
        options: const PdfExportOptions(
          mode: PdfExportMode.original,
          audience: PdfAudience.public,
        ),
        taskSummaries: const {'task-owner-1': task},
        baseFont: baseFont,
        boldFont: boldFont,
        thaiFont: thaiFont,
      );
      expect(
        public.pdfs,
        isNotEmpty,
        reason: public.preflight.issues
            .map((issue) => '${issue.kind}:${issue.refId}')
            .join(', '),
      );
      final publicText = await _extractPdfText(public.pdfs.single.bytes);
      expect(publicText, contains('Restricted content (lock notice)'));
      expect(publicText, isNot(contains('Saved task title')));
      expect(
        publicText.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), ''),
        isNot(contains('privatequiz1')),
      );
    },
  );

  testWidgets('ExportHandler loads Task summaries only for personal exports', (
    tester,
  ) async {
    final document = NoteDocument.fromJson({
      'page': {
        'width': 1000,
        'background': {'kind': 'blank'},
      },
      'items': [
        {
          'id': 'task-card',
          'kind': 'task_card',
          'task_id': 'owner-task',
          'x': 20,
          'y': 20,
          'width': 350,
          'height': 90,
        },
      ],
    }, schema: paperSchema);
    final note = LocalNote(
      id: 'note-export-task',
      schema: paperSchema,
      document: document,
      title: 'Task export',
      revision: 1,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      syncState: LocalSyncState.local,
      accountId: null,
    );
    var personalLoads = 0;
    final personal = ExportHandler(
      note: note,
      store: _EmptyNoteStore(),
      loadTaskSummary: (taskId) async {
        personalLoads++;
        expect(taskId, 'owner-task');
        return const TaskSummary(
          taskId: 'owner-task',
          title: 'Owner task summary',
          completed: false,
        );
      },
      renderPages: (_, _) async => [await _onePixelImage()],
    );
    addTearDown(personal.dispose);
    await tester.runAsync(personal.build);
    expect(personalLoads, 1);
    expect(personal.stage, ExportStage.ready);
    expect(
      await tester.runAsync(
        () => _extractPdfText(personal.output!.pdfs.single.bytes),
      ),
      contains('Owner task summary'),
    );

    var publicLoads = 0;
    final public = ExportHandler(
      note: note,
      store: _EmptyNoteStore(),
      audience: PdfAudience.public,
      loadTaskSummary: (_) async {
        publicLoads++;
        throw StateError('public export must not fetch owner metadata');
      },
      renderPages: (_, _) async => [await _onePixelImage()],
    );
    addTearDown(public.dispose);
    await tester.runAsync(public.build);
    expect(publicLoads, 0);
    expect(public.stage, ExportStage.ready);
    final publicText = await tester.runAsync(
      () => _extractPdfText(public.output!.pdfs.single.bytes),
    );
    expect(publicText, contains('Restricted content (lock notice)'));
    expect(publicText, isNot(contains('Owner task summary')));
  });

  test('unknown document kind is marked in preflight and output', () async {
    final original = NoteDocument.fromJson({
      'page': {
        'width': 1000,
        'background': {'kind': 'blank'},
      },
      'items': [
        {
          'id': 'unknown-1',
          'kind': 'future_widget',
          'text': 'future raw payload',
          'x': 20,
          'y': 20,
          'width': 250,
          'height': 60,
        },
      ],
    }, schema: paperSchema);
    final output = await PdfExportMapper().export(
      title: 'Unknown item',
      slug: 'unknown-item',
      original: original,
      options: options(continueWithPlaceholders: true),
      baseFont: baseFont,
      boldFont: boldFont,
      thaiFont: thaiFont,
    );
    expect(
      output.preflight.issues.map((issue) => issue.kind),
      contains('unsupported_content'),
    );
    final text = await _extractPdfText(output.pdfs.single.bytes);
    expect(text, contains('Unsupported content'));
    expect(text, contains('future_widget'));
  });

  test('Krilla Original title never overlaps the first document item', () async {
    if (!await KrillaPdfBackend.isAvailable()) return;
    final title =
        'TITLE_BEGIN ${List.filled(12, 'wrap phrase').join(' ')} TITLE_END';
    final original = NoteDocument.fromJson({
      'page': {
        'width': 1000,
        'background': {'kind': 'blank'},
      },
      'items': [
        {
          'id': 'first-content',
          'kind': 'text',
          'x': 20,
          'y': 0,
          'width': 800,
          'height': 40,
          'spans': [
            {'text': 'CONTENT_SENTINEL'},
          ],
        },
      ],
    }, schema: paperSchema);
    final output = await PdfExportMapper().export(
      title: title,
      slug: 'title-overlap',
      original: original,
      options: const PdfExportOptions(mode: PdfExportMode.original),
    );
    expect(output.engine, 'krilla');
    final directory = await Directory.systemTemp.createTemp('pdf_bbox_');
    try {
      final file = File('${directory.path}/title.pdf')
        ..writeAsBytesSync(output.pdfs.single.bytes);
      final bbox = await Process.run('pdftotext', ['-bbox', file.path, '-']);
      expect(bbox.exitCode, 0, reason: '${bbox.stderr}');
      final wordPattern = RegExp(
        r'<word xMin="[^"]+" yMin="([^"]+)" xMax="[^"]+" yMax="([^"]+)">([^<]+)</word>',
      );
      final words = [
        for (final match in wordPattern.allMatches('${bbox.stdout}'))
          (
            match.group(3)!,
            double.parse(match.group(1)!),
            double.parse(match.group(2)!),
          ),
      ];
      final titleEnd = words.firstWhere((word) => word.$1 == 'TITLE_END');
      final content = words.firstWhere((word) => word.$1 == 'CONTENT_SENTINEL');
      expect(
        titleEnd.$3,
        lessThanOrEqualTo(content.$2),
        reason: 'the title and first content item share the same PDF area',
      );
    } finally {
      directory.deleteSync(recursive: true);
    }
  });
}

Future<String> _extractPdfText(Uint8List pdf) async {
  final directory = await Directory.systemTemp.createTemp('pdf_text_');
  try {
    final file = File('${directory.path}/result.pdf')..writeAsBytesSync(pdf);
    final result = await Process.run('pdftotext', [file.path, '-']);
    if (result.exitCode != 0) {
      throw StateError('pdftotext failed: ${result.stderr}');
    }
    return '${result.stdout}';
  } finally {
    directory.deleteSync(recursive: true);
  }
}

Future<ui.Image> _onePixelImage() {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xFF123456), ui.BlendMode.src);
  return recorder.endRecording().toImage(1, 1);
}

final class _EmptyNoteStore implements LocalNoteStore {
  @override
  Future<LocalNote?> load(String id) async => null;

  @override
  Future<Uint8List?> readAttachment(String id) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ReferenceNoteStore implements LocalNoteStore {
  _ReferenceNoteStore(this.files);

  final Map<String, _StoredBytes> files;

  @override
  Future<LocalNote?> load(String id) async => null;

  @override
  Future<LocalAttachment?> attachment(String id) async {
    final file = files[id];
    if (file == null) return null;
    return LocalAttachment(
      id: id,
      name: file.name,
      type: file.type,
      size: file.bytes.length,
      path: '/private-test-cache/$id',
    );
  }

  @override
  Future<Uint8List?> readAttachment(String id) async => files[id]?.bytes;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _StoredBytes {
  const _StoredBytes(this.name, this.type, this.bytes);

  final String name;
  final String type;
  final Uint8List bytes;
}
