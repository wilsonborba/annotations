import 'dart:convert';
import 'dart:io';

import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/models/reports_card_reference.dart';
import 'package:annotations_shared/domain/models/reports_embed_data.dart';
import 'package:annotations_shared/domain/services/krilla_pdf_backend.dart';
import 'package:annotations_shared/domain/services/pdf_export_mapper.dart';
import 'package:annotations_shared/presentation/frontend/handlers/reports_pdf_capture.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:reports_view/reports_view.dart';

final _typedSchema = DocumentSchema('note-typed', 1);
const _thaiText =
    'ภาษาไทย: กิ่งไม้ดูแลต้นไม้ กิ๊ กี๊ กึ๊ กื๊ ปู่ ฟุ้ง อยู่ใกล้ผู้อื่นอย่างละเอียด';
const _typedSentinels = [
  'LIST FIRST SENTINEL',
  'LIST SECOND SENTINEL',
  'TABLE HEADER ALPHA',
  'TABLE HEADER BETA',
  'TABLE CELL GAMMA',
  'TABLE CELL DELTA',
  'FIGURE CAPTION SENTINEL',
];

Future<Uint8List> _fontBytes(String name) async => Uint8List.fromList(
  await File('lib/presentation/frontend/assets/fonts/$name').readAsBytes(),
);

Future<void> _loadReportFonts() async {
  await (FontLoader(ReportPalette.font)
        ..addFont(
          Future.value(
            ByteData.sublistView(await _fontBytes('UbuntuSans-Variable.ttf')),
          ),
        )
        ..addFont(
          Future.value(
            ByteData.sublistView(
              await _fontBytes('UbuntuSans-Italic-Variable.ttf'),
            ),
          ),
        ))
      .load();
  await (FontLoader(ReportPalette.thaiFont)..addFont(
        Future.value(
          ByteData.sublistView(await _fontBytes('IBMPlexSansThai-Regular.ttf')),
        ),
      ))
      .load();
}

ReportsEmbedData _reportData() {
  const descriptor = DatasetDescriptor(
    datasetId: 'dataset',
    title: 'Visits',
    description: 'Visits by source',
    equation: null,
    fields: [
      FieldInfo(
        name: 'source',
        label: 'Source',
        type: 'string',
        role: 'dimension',
      ),
      FieldInfo(
        name: 'visits',
        label: 'Visits',
        type: 'integer',
        role: 'measure',
      ),
    ],
    filters: [],
    canView: true,
  );
  return ReportsEmbedData(
    state: ReportsEmbedState.readable,
    reference: const ReportsCardReference(
      project: 'project',
      report: 'report',
      dataset: 'dataset',
    ),
    descriptor: descriptor,
    page: DatasetPage(
      descriptor: descriptor,
      rows: [
        {'source': 'Direct', 'visits': 20},
        {'source': 'Search', 'visits': 13},
      ],
      offset: 0,
      limit: 5000,
      totalRows: 2,
    ),
    complete: true,
  );
}

NoteDocument _document() => NoteDocument.fromJson({
  'blocks': [
    {
      'id': 'typed-paragraph',
      'kind': 'paragraph',
      'spans': [
        {'text': _thaiText},
      ],
    },
    {
      'id': 'typed-list',
      'kind': 'list',
      'ordered': true,
      'items': [
        {
          'spans': [
            {'text': 'LIST FIRST SENTINEL'},
          ],
        },
        {
          'spans': [
            {'text': 'LIST SECOND SENTINEL'},
          ],
        },
      ],
    },
    {
      'id': 'typed-table',
      'kind': 'table',
      'header': true,
      'rows': [
        {
          'cells': [
            {
              'spans': [
                {'text': 'TABLE HEADER ALPHA'},
              ],
            },
            {
              'spans': [
                {'text': 'TABLE HEADER BETA'},
              ],
            },
          ],
        },
        {
          'cells': [
            {
              'spans': [
                {'text': 'TABLE CELL GAMMA'},
              ],
            },
            {
              'spans': [
                {'text': 'TABLE CELL DELTA'},
              ],
            },
          ],
        },
      ],
    },
    {
      'id': 'typed-figure',
      'kind': 'figure',
      'file_id': 'missing-figure-file',
      'caption': [
        {'text': 'FIGURE CAPTION SENTINEL'},
      ],
    },
    {
      'id': 'report-card',
      'kind': 'reports_embed',
      'report_id': 'report',
      'project_slug': 'project',
      'report_slug': 'report',
      'dataset_id': 'dataset',
      'mode': 'snapshot',
      'source': 'link',
      'snapshot_id': 'snapshot-1',
      'captured_at': 1795520000,
    },
  ],
}, schema: _typedSchema);

String _extractPdfText(Uint8List bytes) {
  final dir = Directory(
    '${Directory.systemTemp.path}/typed_pdf_text_${pid}_${DateTime.now().microsecondsSinceEpoch}',
  )..createSync();
  try {
    final file = File('${dir.path}/note.pdf')..writeAsBytesSync(bytes);
    final result = Process.runSync('pdftotext', [file.path, '-']);
    if (result.exitCode != 0) {
      throw StateError('pdftotext failed: ${result.stderr}');
    }
    return (result.stdout as String).replaceAll(RegExp(r'\s+'), '');
  } finally {
    dir.deleteSync(recursive: true);
  }
}

void _expectPdfContainsImage(Uint8List bytes) {
  final dir = Directory(
    '${Directory.systemTemp.path}/typed_pdf_image_${pid}_${DateTime.now().microsecondsSinceEpoch}',
  )..createSync();
  try {
    final file = File('${dir.path}/note.pdf')..writeAsBytesSync(bytes);
    final result = Process.runSync('pdfimages', ['-list', file.path]);
    expect(result.exitCode, 0, reason: 'pdfimages failed: ${result.stderr}');
    expect('${result.stdout}', contains(' image '));
  } finally {
    dir.deleteSync(recursive: true);
  }
}

void _expectTypedContentInOrder(String text) {
  expect(text, contains('กิ๊'));
  expect(text, contains('กี๊'));
  expect(text, contains('กึ๊'));
  expect(text, contains('กื๊'));
  expect(text, contains('ปู่'));
  expect(text, contains('ฟุ้ง'));
  var previous = -1;
  for (final sentinel in _typedSentinels) {
    final index = text.indexOf(sentinel.replaceAll(' ', ''), previous + 1);
    expect(index, greaterThan(previous), reason: 'preserve order: $sentinel');
    previous = index;
  }
}

void main() {
  testWidgets(
    'Typed lists, table cells, and figure caption survive Reports PDF paths',
    (tester) async {
      await tester.runAsync(_loadReportFonts);
      const hostKey = Key('typed-structure-capture-host');
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Builder(
              key: hostKey,
              builder: (_) => const Text('Typed PDF capture'),
            ),
          ),
        ),
      );
      final context = tester.element(find.byKey(hostKey));
      final capture = captureReportsPdfChart(
        context,
        _reportData(),
        language: 'en',
      );
      await tester.pump();
      final chartPng = await tester.runAsync(() => capture);
      // The real Reports charts keep an animation ticker active. The chart
      // raster is captured by the awaited future, so settling the host would
      // wait forever without adding evidence.
      expect(chartPng, isNotNull);
      expect(chartPng!.length, greaterThan(1000));

      final document = _document();
      final regularBytes = await tester.runAsync(
        () => _fontBytes('IBMPlexSansThai-Regular.ttf'),
      );
      final boldBytes = await tester.runAsync(
        () => _fontBytes('IBMPlexSansThai-Bold.ttf'),
      );
      final baseFont = pw.Font.ttf(
        ByteData.sublistView(
          (await tester.runAsync(() => _fontBytes('UbuntuSans-Variable.ttf')))!,
        ),
      );
      final thaiFont = pw.Font.ttf(ByteData.sublistView(regularBytes!));
      final mapper = PdfExportMapper();
      final reportKey = jsonEncode([
        'report',
        'project',
        'report',
        'dataset',
        'snapshot',
        'snapshot-1',
      ]);
      final fallback = await mapper.export(
        title: 'Typed structures',
        slug: 'typed-structures',
        typed: document,
        options: const PdfExportOptions(
          mode: PdfExportMode.typed,
          continueWithPlaceholders: true,
        ),
        reportImages: {reportKey: chartPng},
        baseFont: baseFont,
        thaiFont: thaiFont,
      );
      expect(fallback.engine, 'pdf');
      expect(fallback.pdfs, hasLength(1));
      expect(
        fallback.preflight.issues.map((issue) => issue.kind),
        contains('missing_file'),
        reason: 'the caption is tested; no figure image bytes are provided',
      );
      _expectTypedContentInOrder(_extractPdfText(fallback.pdfs.single.bytes));
      _expectPdfContainsImage(fallback.pdfs.single.bytes);

      PdfExportOutput? native;
      if (await KrillaPdfBackend.isAvailable()) {
        native = await mapper.export(
          title: 'Typed structures',
          slug: 'typed-native-structures',
          typed: document,
          options: const PdfExportOptions(
            mode: PdfExportMode.typed,
            continueWithPlaceholders: true,
          ),
          regularFontBytes: regularBytes,
          boldFontBytes: boldBytes,
        );
        expect(native.engine, 'krilla');
        expect(native.pdfs, hasLength(1));
        _expectTypedContentInOrder(_extractPdfText(native.pdfs.single.bytes));
      }

      final evidencePath = Platform.environment['ANNOTATIONS_PDF_EVIDENCE_DIR'];
      if (evidencePath != null && evidencePath.isNotEmpty) {
        final evidence = Directory(evidencePath);
        evidence.createSync(recursive: true);
        File('${evidence.path}/reports-chart.png').writeAsBytesSync(chartPng);
        File(
          '${evidence.path}/reports-image-typed.pdf',
        ).writeAsBytesSync(fallback.pdfs.single.bytes);
        if (native != null) {
          File(
            '${evidence.path}/native-typed-control.pdf',
          ).writeAsBytesSync(native.pdfs.single.bytes);
        }
      }
    },
  );
}
