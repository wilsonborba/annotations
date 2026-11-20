import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/note_document.dart';
import 'krilla_pdf_backend.dart';

enum PdfExportMode { original, typed, both }

enum PdfPaperSize { a4, letter }

enum PdfOrientation { portrait, landscape }

enum PdfAudience { public, personal }

final class PdfExportOptions {
  final PdfExportMode mode;
  final PdfPaperSize paperSize;
  final PdfOrientation orientation;
  final PdfAudience audience;
  final bool continueWithPlaceholders;
  final String? publicBaseUrl;

  const PdfExportOptions({
    this.mode = PdfExportMode.original,
    this.paperSize = PdfPaperSize.a4,
    this.orientation = PdfOrientation.portrait,
    this.audience = PdfAudience.personal,
    this.continueWithPlaceholders = false,
    this.publicBaseUrl,
  });

  PdfPageFormat get pageFormat {
    final base = paperSize == PdfPaperSize.a4
        ? PdfPageFormat.a4
        : PdfPageFormat.letter;
    return orientation == PdfOrientation.landscape ? base.landscape : base;
  }
}

final class PdfPreflightIssue {
  final String kind; // missing_file | failed_chart | missing_font
  final String refId;
  final String message;

  const PdfPreflightIssue({
    required this.kind,
    required this.refId,
    required this.message,
  });
}

final class PdfPreflightResult {
  final List<PdfPreflightIssue> issues;
  final bool hasPrivateChartWarning;

  const PdfPreflightResult({
    required this.issues,
    required this.hasPrivateChartWarning,
  });

  bool get ok => issues.isEmpty;
}

final class PdfNamedFile {
  final String filename;
  final Uint8List bytes;

  const PdfNamedFile({required this.filename, required this.bytes});
}

final class PdfCompanionFile {
  final String filename;
  final Uint8List bytes;

  const PdfCompanionFile({required this.filename, required this.bytes});
}

final class PdfExportOutput {
  final PdfPreflightResult preflight;
  final List<PdfNamedFile> pdfs;
  final List<PdfCompanionFile> companions;
  final String engine;

  const PdfExportOutput({
    required this.preflight,
    required this.pdfs,
    this.companions = const [],
    this.engine = 'pdf',
  });
}

final class ThaiShapingEvidence {
  final bool hasThaiText;
  final bool hasCombiningMarks;
  final bool fontEmbedded;
  final String note;

  const ThaiShapingEvidence({
    required this.hasThaiText,
    required this.hasCombiningMarks,
    required this.fontEmbedded,
    required this.note,
  });
}

/// Canonical document-to-PDF mapper for Original and Typed views (annotations#41).
/// Never starts transcription, never mutates the note, and never renders from screenshots.
class PdfExportMapper {
  static const double marginPt = 36.0;
  static final _thaiRegex = RegExp(r'[\u0E00-\u0E7F]');
  static final _thaiCombiningRegex = RegExp(
    r'[\u0E31\u0E34-\u0E3A\u0E47-\u0E4E]',
  );

  static ThaiShapingEvidence inspectThaiText(
    String text, {
    required bool fontEmbedded,
  }) {
    final hasThai = _thaiRegex.hasMatch(text);
    final hasCombining = _thaiCombiningRegex.hasMatch(text);
    return ThaiShapingEvidence(
      hasThaiText: hasThai,
      hasCombiningMarks: hasCombining,
      fontEmbedded: fontEmbedded,
      note: hasThai
          ? 'Embedded IBM Plex Sans Thai; pdf package places combining marks without full HarfBuzz GPOS.'
          : 'No Thai characters present.',
    );
  }

  /// Runs preflight checks before export without modifying the note.
  static PdfPreflightResult preflight({
    required NoteDocument? original,
    required NoteDocument? typed,
    required PdfExportOptions options,
    Set<String> availableFileIds = const {},
    Set<String> failedChartIds = const {},
    bool fontsAvailable = true,
  }) {
    final issues = <PdfPreflightIssue>[];
    var hasPrivateChartWarning = false;

    if (!fontsAvailable) {
      issues.add(
        const PdfPreflightIssue(
          kind: 'missing_font',
          refId: 'ubuntu_sans_thai',
          message: 'Embedded Latin/Thai fonts are unavailable.',
        ),
      );
    }

    void scan(Object? node) {
      if (node is Map) {
        final kind = '${node['kind'] ?? node['type'] ?? ''}';
        final fileId = node['file_id'] as String?;
        if (fileId != null &&
            fileId.isNotEmpty &&
            !availableFileIds.contains(fileId)) {
          issues.add(
            PdfPreflightIssue(
              kind: 'missing_file',
              refId: fileId,
              message: 'Missing local or synced file $fileId.',
            ),
          );
        }
        if (kind == 'report_embed') {
          final refId = '${node['ref_id'] ?? node['id'] ?? ''}';
          if (failedChartIds.contains(refId)) {
            issues.add(
              PdfPreflightIssue(
                kind: 'failed_chart',
                refId: refId,
                message: 'Chart $refId failed to load.',
              ),
            );
          }
          if ('${node['visibility'] ?? 'public'}' != 'public') {
            hasPrivateChartWarning = true;
          }
        }
        for (final v in node.values) {
          scan(v);
        }
      } else if (node is List) {
        for (final v in node) {
          scan(v);
        }
      }
    }

    if (options.mode != PdfExportMode.typed && original != null) {
      scan(original.toJson());
    }
    if (options.mode != PdfExportMode.original && typed != null) {
      scan(typed.toJson());
    }

    return PdfPreflightResult(
      issues: issues,
      hasPrivateChartWarning: hasPrivateChartWarning,
    );
  }

  /// Computes page break Y positions for a long Original canvas at clear spaces
  /// so no item (drawing, card, group, text box) is cut mid-object.
  static List<double> computeOriginalPageBreaks({
    required List<Map<String, dynamic>> items,
    required double printableHeight,
  }) {
    if (items.isEmpty) return const [0.0];
    final sorted = [...items]
      ..sort(
        (a, b) => ((a['y'] as num?)?.toDouble() ?? 0).compareTo(
          (b['y'] as num?)?.toDouble() ?? 0,
        ),
      );

    final breaks = <double>[0.0];
    var pageTop = 0.0;
    for (final it in sorted) {
      final y = (it['y'] as num?)?.toDouble() ?? 0.0;
      final h = (it['height'] as num?)?.toDouble() ?? 40.0;
      if (h > printableHeight) {
        // Oversized item gets its own dedicated page.
        if (y > pageTop) breaks.add(y);
        breaks.add(y + h);
        pageTop = y + h;
        continue;
      }
      if (y + h - pageTop > printableHeight && y > pageTop) {
        breaks.add(y);
        pageTop = y;
      }
    }
    return breaks;
  }

  Future<Uint8List?> _tryLoadBundledFont(String fileName) async {
    for (final path in [
      'packages/annotations_shared/lib/presentation/frontend/assets/fonts/$fileName',
      'lib/presentation/frontend/assets/fonts/$fileName',
    ]) {
      try {
        final data = await rootBundle.load(path);
        return data.buffer.asUint8List();
      } on Object {
        // Ignore and try next asset path.
      }
    }
    return null;
  }

  Future<PdfExportOutput> export({
    required String title,
    required String slug,
    NoteDocument? original,
    NoteDocument? typed,
    required PdfExportOptions options,
    Set<String> availableFileIds = const {},
    Set<String> failedChartIds = const {},
    Map<String, Uint8List> attachments = const {},
    pw.Font? baseFont,
    pw.Font? boldFont,
    pw.Font? thaiFont,
    Uint8List? regularFontBytes,
    Uint8List? boldFontBytes,
  }) async {
    final pre = preflight(
      original: original,
      typed: typed,
      options: options,
      availableFileIds: availableFileIds,
      failedChartIds: failedChartIds,
    );

    if (!pre.ok && !options.continueWithPlaceholders) {
      return PdfExportOutput(preflight: pre, pdfs: const []);
    }

    final krillaReady = await KrillaPdfBackend.isAvailable();
    final resolvedRegular = krillaReady
        ? (regularFontBytes ??
            await _tryLoadBundledFont('IBMPlexSansThai-Regular.ttf'))
        : null;
    final resolvedBold = krillaReady
        ? (boldFontBytes ??
            await _tryLoadBundledFont('IBMPlexSansThai-Bold.ttf'))
        : null;
    final useKrilla = krillaReady && resolvedRegular != null;

    final pdfs = <PdfNamedFile>[];
    final companions = <PdfCompanionFile>[];

    if ((options.mode == PdfExportMode.original ||
            options.mode == PdfExportMode.both) &&
        original != null) {
      final bytes = useKrilla
          ? await _buildOriginalPdfKrilla(
              title: title,
              document: original,
              options: options,
              attachments: attachments,
              companions: companions,
              regularFontBytes: resolvedRegular,
              boldFontBytes: resolvedBold,
            )
          : await _buildOriginalPdf(
              title: title,
              document: original,
              options: options,
              attachments: attachments,
              companions: companions,
              baseFont: baseFont,
              boldFont: boldFont,
              thaiFont: thaiFont,
            );
      pdfs.add(PdfNamedFile(filename: '$slug-original.pdf', bytes: bytes));
    }

    if ((options.mode == PdfExportMode.typed ||
            options.mode == PdfExportMode.both) &&
        typed != null) {
      final bytes = useKrilla
          ? await _buildTypedPdfKrilla(
              title: title,
              document: typed,
              options: options,
              regularFontBytes: resolvedRegular,
              boldFontBytes: resolvedBold,
            )
          : await _buildTypedPdf(
              title: title,
              document: typed,
              options: options,
              baseFont: baseFont,
              boldFont: boldFont,
              thaiFont: thaiFont,
            );
      pdfs.add(PdfNamedFile(filename: '$slug-typed.pdf', bytes: bytes));
    }

    return PdfExportOutput(
      preflight: pre,
      pdfs: pdfs,
      companions: companions,
      engine: useKrilla ? 'krilla' : 'pdf',
    );
  }

  String _itemTextSummary(
    Map<String, dynamic> item, {
    required String kind,
    required PdfExportOptions options,
  }) {
    if (kind == 'report_embed') {
      final visibility = '${item['visibility'] ?? 'public'}';
      if (options.audience == PdfAudience.public && visibility != 'public') {
        return 'Restricted content (lock notice)';
      }
      return 'Report snapshot: ${item['title'] ?? item['ref_id'] ?? 'chart'}';
    }
    if (kind == 'task') {
      final taskTitle = '${item['title'] ?? 'Task'}';
      final status = '${item['status'] ?? 'open'}';
      final link =
          options.audience == PdfAudience.public && item['public_url'] != null
          ? ' | ${item['public_url']}'
          : '';
      return 'Task: $taskTitle [$status]$link';
    }
    if (kind == 'quiz') {
      final quizTitle = '${item['title'] ?? 'Quiz'}';
      final count = item['question_count'] ?? 0;
      final link =
          options.audience == PdfAudience.public && item['public_url'] != null
          ? ' | ${item['public_url']}'
          : '';
      return 'Quiz: $quizTitle ($count questions)$link';
    }
    if (kind == 'text') {
      final spans = (item['spans'] as List?) ?? const [];
      return spans.map((s) => s is Map ? '${s['text'] ?? ''}' : '$s').join();
    }
    return '${item['name'] ?? item['title'] ?? kind}';
  }

  Future<Uint8List> _buildOriginalPdfKrilla({
    required String title,
    required NoteDocument document,
    required PdfExportOptions options,
    required Map<String, Uint8List> attachments,
    required List<PdfCompanionFile> companions,
    required Uint8List regularFontBytes,
    Uint8List? boldFontBytes,
  }) async {
    final format = options.pageFormat;
    final printableW = format.width - marginPt * 2;
    final printableH = format.height - marginPt * 2;

    final json = document.toJson();
    final pageMap = (json['page'] as Map?) ?? const {};
    final canvasW = ((pageMap['width'] as num?)?.toDouble() ?? 1000.0).clamp(
      200.0,
      4000.0,
    );
    final scale = printableW / canvasW;

    final rawItems = ((json['items'] as List?) ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    final scaledPrintableH = printableH / scale;
    final breaks = computeOriginalPageBreaks(
      items: rawItems,
      printableHeight: scaledPrintableH,
    );

    final pagesOut = <Map<String, dynamic>>[];
    for (var p = 0; p < breaks.length; p++) {
      final yStart = breaks[p];
      final yEnd = p + 1 < breaks.length ? breaks[p + 1] : double.infinity;
      final pageItems = [
        for (final it in rawItems)
          if (((it['y'] as num?)?.toDouble() ?? 0.0) >= yStart &&
              ((it['y'] as num?)?.toDouble() ?? 0.0) < yEnd)
            it,
      ];
      if (pageItems.isEmpty && p > 0) continue;

      final rects = <Map<String, dynamic>>[];
      final strokes = <Map<String, dynamic>>[];
      final runs = <Map<String, dynamic>>[];

      var contentTop = marginPt;
      if (p == 0 && title.isNotEmpty) {
        runs.add({
          'text': title,
          'x': marginPt,
          'y': marginPt + 16.0,
          'max_width': printableW,
          'font_size': 16.0,
          'line_height': 22.0,
          'bold': true,
        });
        contentTop += 28.0;
      }

      final hasOversized = pageItems.any(
        (it) => ((it['height'] as num?)?.toDouble() ?? 40.0) > scaledPrintableH,
      );

      if (hasOversized) {
        final item = pageItems.first;
        final id = '${item['id'] ?? 'item'}';
        final fileId = item['file_id'] as String?;
        final companionName = 'companion-$id.json';
        final payloadBytes = fileId != null && attachments.containsKey(fileId)
            ? attachments[fileId]!
            : Uint8List.fromList(utf8.encode(jsonEncode(item)));
        companions.add(
          PdfCompanionFile(filename: companionName, bytes: payloadBytes),
        );
        final publicLink =
            options.publicBaseUrl != null &&
                options.audience == PdfAudience.public
            ? '${options.publicBaseUrl}/items/$id'
            : null;
        rects.add({
          'x': marginPt,
          'y': contentTop,
          'width': printableW,
          'height': printableH - (contentTop - marginPt),
          'stroke_width': 1.0,
          'gray': 120,
        });
        runs.add({
          'text': 'Preview, see full content',
          'x': marginPt + 12.0,
          'y': contentTop + 24.0,
          'max_width': printableW - 24.0,
          'font_size': 13.0,
          'line_height': 18.0,
          'bold': true,
        });
        runs.add({
          'text': 'Item: $id (${item['kind'] ?? 'object'})',
          'x': marginPt + 12.0,
          'y': contentTop + 52.0,
          'max_width': printableW - 24.0,
          'font_size': 11.0,
          'line_height': 16.0,
        });
        runs.add({
          'text': publicLink != null
              ? 'Full content link: $publicLink'
              : 'Companion file: $companionName',
          'x': marginPt + 12.0,
          'y': contentTop + 76.0,
          'max_width': printableW - 24.0,
          'font_size': 11.0,
          'line_height': 16.0,
        });
      } else {
        for (final item in pageItems) {
          final x =
              marginPt +
              math.max(0.0, ((item['x'] as num?)?.toDouble() ?? 0.0) * scale);
          final y =
              contentTop +
              math.max(
                0.0,
                (((item['y'] as num?)?.toDouble() ?? 0.0) - yStart) * scale,
              );
          final w = math.max(
            24.0,
            ((item['width'] as num?)?.toDouble() ?? 160.0) * scale,
          );
          final h = math.max(
            18.0,
            ((item['height'] as num?)?.toDouble() ?? 40.0) * scale,
          );
          final kind = '${item['kind'] ?? 'text'}';

          if (kind != 'text' && kind != 'ink' && kind != 'stroke') {
            rects.add({
              'x': x,
              'y': y,
              'width': w,
              'height': h,
              'stroke_width': 0.8,
              'gray': 170,
            });
          }

          if (kind == 'ink' || kind == 'stroke') {
            final rawPts =
                (item['points'] as List?) ??
                ((item['strokes'] as List?)?.firstOrNull is Map
                    ? ((item['strokes'] as List).first as Map)['points']
                          as List?
                    : null) ??
                const [];
            if (rawPts.length >= 2) {
              final poly = <List<double>>[];
              for (final pt in rawPts) {
                final px = pt is Map
                    ? (pt['x'] as num).toDouble()
                    : (pt[0] as num).toDouble();
                final py = pt is Map
                    ? (pt['y'] as num).toDouble()
                    : (pt[1] as num).toDouble();
                poly.add([x + px, y + py]);
              }
              strokes.add({'points': poly, 'width': 1.2});
            }
          } else {
            final summary = _itemTextSummary(item, kind: kind, options: options);
            final isRestricted =
                kind == 'report_embed' &&
                options.audience == PdfAudience.public &&
                '${item['visibility'] ?? 'public'}' != 'public';
            final fontSize = kind == 'text' ? 10.0 : 9.0;
            runs.add({
              'text': summary,
              'x': x + 4.0,
              'y': y + 4.0 + fontSize,
              'max_width': math.max(20.0, w - 8.0),
              'font_size': fontSize,
              'line_height': fontSize * 1.4,
              'muted': isRestricted,
            });
          }
        }
      }
      pagesOut.add({'rects': rects, 'strokes': strokes, 'runs': runs});
    }

    final payload = jsonEncode({
      'title': title,
      'paper_width': format.width,
      'paper_height': format.height,
      'margin': marginPt,
      'mode': 'pages',
      'pages': pagesOut,
    });
    final rendered = await KrillaPdfBackend.renderPdf(
      modelJsonBytes: Uint8List.fromList(utf8.encode(payload)),
      regularFontBytes: regularFontBytes,
      boldFontBytes: boldFontBytes,
    );
    if (rendered == null) {
      throw StateError('KrillaPdfBackend returned null for Original PDF');
    }
    return rendered;
  }

  Future<Uint8List> _buildTypedPdfKrilla({
    required String title,
    required NoteDocument document,
    required PdfExportOptions options,
    required Uint8List regularFontBytes,
    Uint8List? boldFontBytes,
  }) async {
    final format = options.pageFormat;
    final rawBlocks = ((document.toJson()['blocks'] as List?) ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    final blocksOut = <Map<String, dynamic>>[];
    for (final b in rawBlocks) {
      final kind = '${b['kind'] ?? b['type'] ?? 'paragraph'}';
      final spans = (b['spans'] as List?) ?? const [];
      final text = spans.isNotEmpty
          ? spans.map((s) => s is Map ? '${s['text'] ?? ''}' : '$s').join()
          : '${b['text'] ?? ''}';
      if (kind == 'heading' || kind == 'h1' || kind == 'h2' || kind == 'h3') {
        blocksOut.add({
          'kind': kind,
          'text': text,
          'font_size': 14.0,
          'line_height': 20.0,
          'bold': true,
          'keep_with_next': true,
          'space_after': 6.0,
        });
      } else if (kind == 'report_embed' || kind == 'task' || kind == 'quiz') {
        final isRestricted =
            kind == 'report_embed' &&
            options.audience == PdfAudience.public &&
            '${b['visibility'] ?? 'public'}' != 'public';
        blocksOut.add({
          'kind': kind,
          'text': _itemTextSummary(b, kind: kind, options: options),
          'font_size': 9.5,
          'line_height': 14.0,
          'muted': isRestricted,
          'space_after': 6.0,
        });
      } else {
        blocksOut.add({
          'kind': kind,
          'text': text,
          'font_size': 11.0,
          'line_height': 16.5,
          'space_after': 6.0,
        });
      }
    }

    final payload = jsonEncode({
      'title': title,
      'paper_width': format.width,
      'paper_height': format.height,
      'margin': marginPt,
      'mode': 'flow',
      'blocks': blocksOut,
    });
    final rendered = await KrillaPdfBackend.renderPdf(
      modelJsonBytes: Uint8List.fromList(utf8.encode(payload)),
      regularFontBytes: regularFontBytes,
      boldFontBytes: boldFontBytes,
    );
    if (rendered == null) {
      throw StateError('KrillaPdfBackend returned null for Typed PDF');
    }
    return rendered;
  }

  pw.ThemeData? _theme(
    pw.Font? baseFont,
    pw.Font? boldFont,
    pw.Font? thaiFont,
  ) {
    if (baseFont == null && thaiFont == null) return null;
    final fallbacks = <pw.Font>[?thaiFont];
    return pw.ThemeData.withFont(
      base: baseFont ?? thaiFont,
      bold: boldFont ?? baseFont ?? thaiFont,
      fontFallback: fallbacks,
    );
  }

  Future<Uint8List> _buildOriginalPdf({
    required String title,
    required NoteDocument document,
    required PdfExportOptions options,
    required Map<String, Uint8List> attachments,
    required List<PdfCompanionFile> companions,
    pw.Font? baseFont,
    pw.Font? boldFont,
    pw.Font? thaiFont,
  }) async {
    final doc = pw.Document(
      title: title,
      theme: _theme(baseFont, boldFont, thaiFont),
    );
    final format = options.pageFormat;
    final printableW = format.width - marginPt * 2;
    final printableH = format.height - marginPt * 2;

    final json = document.toJson();
    final pageMap = (json['page'] as Map?) ?? const {};
    final canvasW = ((pageMap['width'] as num?)?.toDouble() ?? 1000.0).clamp(
      200.0,
      4000.0,
    );
    final scale = printableW / canvasW;

    final rawItems = ((json['items'] as List?) ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    final scaledPrintableH = printableH / scale;
    final breaks = computeOriginalPageBreaks(
      items: rawItems,
      printableHeight: scaledPrintableH,
    );

    for (var p = 0; p < breaks.length; p++) {
      final yStart = breaks[p];
      final yEnd = p + 1 < breaks.length ? breaks[p + 1] : double.infinity;
      final pageItems = [
        for (final it in rawItems)
          if (((it['y'] as num?)?.toDouble() ?? 0.0) >= yStart &&
              ((it['y'] as num?)?.toDouble() ?? 0.0) < yEnd)
            it,
      ];
      if (pageItems.isEmpty && p > 0) continue;

      final hasOversized = pageItems.any(
        (it) => ((it['height'] as num?)?.toDouble() ?? 40.0) > scaledPrintableH,
      );

      doc.addPage(
        pw.Page(
          pageFormat: format,
          margin: const pw.EdgeInsets.all(marginPt),
          build: (_) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              if (p == 0)
                pw.Padding(
                  padding: const pw.EdgeInsets.only(bottom: 8),
                  child: pw.Text(
                    title,
                    style: pw.TextStyle(
                      fontSize: 16,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ),
              if (hasOversized)
                _buildOversizedPage(
                  pageItems.first,
                  options: options,
                  attachments: attachments,
                  companions: companions,
                  printableW: printableW,
                  printableH: printableH - 40,
                )
              else
                pw.Expanded(
                  child: pw.Stack(
                    children: [
                      for (final it in pageItems)
                        _buildPositionedOriginalItem(
                          it,
                          yOrigin: yStart,
                          scale: scale,
                          options: options,
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );
    }

    return doc.save();
  }

  pw.Widget _buildOversizedPage(
    Map<String, dynamic> item, {
    required PdfExportOptions options,
    required Map<String, Uint8List> attachments,
    required List<PdfCompanionFile> companions,
    required double printableW,
    required double printableH,
  }) {
    final id = '${item['id'] ?? 'item'}';
    final fileId = item['file_id'] as String?;
    final companionName = 'companion-$id.json';
    final payloadBytes = fileId != null && attachments.containsKey(fileId)
        ? attachments[fileId]!
        : Uint8List.fromList(utf8.encode(jsonEncode(item)));
    companions.add(
      PdfCompanionFile(filename: companionName, bytes: payloadBytes),
    );

    final publicLink =
        options.publicBaseUrl != null && options.audience == PdfAudience.public
        ? '${options.publicBaseUrl}/items/$id'
        : null;

    return pw.Container(
      width: printableW,
      height: printableH,
      padding: const pw.EdgeInsets.all(12),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey600),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            'Preview, see full content',
            style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold),
          ),
          pw.Text('Item: $id (${item['kind'] ?? 'object'})'),
          pw.Text(
            publicLink != null
                ? 'Full content link: $publicLink'
                : 'Companion file: $companionName',
          ),
        ],
      ),
    );
  }

  pw.Widget _buildPositionedOriginalItem(
    Map<String, dynamic> item, {
    required double yOrigin,
    required double scale,
    required PdfExportOptions options,
  }) {
    final x = ((item['x'] as num?)?.toDouble() ?? 0.0) * scale;
    final y = (((item['y'] as num?)?.toDouble() ?? 0.0) - yOrigin) * scale;
    final w = math.max(
      24.0,
      ((item['width'] as num?)?.toDouble() ?? 160.0) * scale,
    );
    final h = math.max(
      18.0,
      ((item['height'] as num?)?.toDouble() ?? 40.0) * scale,
    );
    final kind = '${item['kind'] ?? 'text'}';

    return pw.Positioned(
      left: math.max(0, x),
      top: math.max(0, y),
      child: pw.Container(
        width: w,
        height: h,
        padding: const pw.EdgeInsets.all(4),
        decoration: kind == 'text' || kind == 'ink'
            ? null
            : pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey400)),
        child: _renderItemBody(
          item,
          kind: kind,
          options: options,
          width: w,
          height: h,
        ),
      ),
    );
  }

  pw.Widget _renderItemBody(
    Map<String, dynamic> item, {
    required String kind,
    required PdfExportOptions options,
    required double width,
    required double height,
  }) {
    if (kind == 'report_embed') {
      final visibility = '${item['visibility'] ?? 'public'}';
      if (options.audience == PdfAudience.public && visibility != 'public') {
        return pw.Text(
          'Restricted content (lock notice)',
          style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
        );
      }
      return pw.Text(
        'Report snapshot: ${item['title'] ?? item['ref_id'] ?? 'chart'}',
        style: const pw.TextStyle(fontSize: 9),
      );
    }

    if (kind == 'task') {
      final taskTitle = '${item['title'] ?? 'Task'}';
      final status = '${item['status'] ?? 'open'}';
      final link =
          options.audience == PdfAudience.public && item['public_url'] != null
          ? ' | ${item['public_url']}'
          : '';
      return pw.Text(
        'Task: $taskTitle [$status]$link',
        style: const pw.TextStyle(fontSize: 9),
      );
    }

    if (kind == 'quiz') {
      final quizTitle = '${item['title'] ?? 'Quiz'}';
      final count = item['question_count'] ?? 0;
      final link =
          options.audience == PdfAudience.public && item['public_url'] != null
          ? ' | ${item['public_url']}'
          : '';
      return pw.Text(
        'Quiz: $quizTitle ($count questions)$link',
        style: const pw.TextStyle(fontSize: 9),
      );
    }

    if (kind == 'ink' || kind == 'stroke') {
      final pts =
          (item['points'] as List?) ??
          ((item['strokes'] as List?)?.firstOrNull is Map
              ? ((item['strokes'] as List).first as Map)['points'] as List?
              : null) ??
          const [];
      return pw.CustomPaint(
        size: PdfPoint(width, height),
        painter: (canvas, size) {
          canvas
            ..setStrokeColor(PdfColors.blueGrey800)
            ..setLineWidth(1.2);
          if (pts.length >= 2) {
            final first = pts.first;
            final x0 = first is Map
                ? (first['x'] as num).toDouble()
                : (first[0] as num).toDouble();
            final y0 = first is Map
                ? (first['y'] as num).toDouble()
                : (first[1] as num).toDouble();
            canvas.moveTo(x0, size.y - y0);
            for (var i = 1; i < pts.length; i++) {
              final pt = pts[i];
              final xi = pt is Map
                  ? (pt['x'] as num).toDouble()
                  : (pt[0] as num).toDouble();
              final yi = pt is Map
                  ? (pt['y'] as num).toDouble()
                  : (pt[1] as num).toDouble();
              canvas.lineTo(xi, size.y - yi);
            }
            canvas.strokePath();
          }
        },
      );
    }

    if (kind == 'text') {
      final spans = (item['spans'] as List?) ?? const [];
      final text = spans
          .map((s) => s is Map ? '${s['text'] ?? ''}' : '$s')
          .join();
      return pw.Text(text, style: const pw.TextStyle(fontSize: 10));
    }

    return pw.Text(
      '${item['name'] ?? item['title'] ?? kind}',
      style: const pw.TextStyle(fontSize: 9),
    );
  }

  Future<Uint8List> _buildTypedPdf({
    required String title,
    required NoteDocument document,
    required PdfExportOptions options,
    pw.Font? baseFont,
    pw.Font? boldFont,
    pw.Font? thaiFont,
  }) async {
    final doc = pw.Document(
      title: title,
      theme: _theme(baseFont, boldFont, thaiFont),
    );
    final blocks = ((document.toJson()['blocks'] as List?) ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    doc.addPage(
      pw.MultiPage(
        pageFormat: options.pageFormat,
        margin: const pw.EdgeInsets.all(marginPt),
        build: (_) => [
          pw.Header(
            level: 0,
            child: pw.Text(
              title,
              style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold),
            ),
          ),
          for (var i = 0; i < blocks.length; i++)
            ..._buildTypedBlock(blocks, i, options: options),
        ],
      ),
    );
    return doc.save();
  }

  List<pw.Widget> _buildTypedBlock(
    List<Map<String, dynamic>> blocks,
    int index, {
    required PdfExportOptions options,
  }) {
    final b = blocks[index];
    final kind = '${b['kind'] ?? b['type'] ?? 'paragraph'}';
    final spans = (b['spans'] as List?) ?? const [];
    final text = spans.isNotEmpty
        ? spans.map((s) => s is Map ? '${s['text'] ?? ''}' : '$s').join()
        : '${b['text'] ?? ''}';
    if (kind == 'heading' || kind == 'h1' || kind == 'h2' || kind == 'h3') {
      return [
        pw.Header(
          level: 1,
          child: pw.Text(
            text,
            style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
          ),
        ),
      ];
    }
    if (kind == 'report_embed' || kind == 'task' || kind == 'quiz') {
      return [
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 4),
          child: _renderItemBody(
            b,
            kind: kind,
            options: options,
            width: 400,
            height: 40,
          ),
        ),
      ];
    }
    return [pw.Paragraph(text: text, style: const pw.TextStyle(fontSize: 11))];
  }
}
