import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/ink.dart';
import '../models/note_document.dart';
import 'editor_rules.dart';
import 'ink_outline.dart';
import 'krilla_pdf_backend.dart';

enum PdfExportMode { original, typed, both }

enum PdfPaperSize { a4, letter }

enum PdfOrientation { portrait, landscape }

enum PdfAudience { public, personal }

String _reportImageKey(Map<String, dynamic> item) => jsonEncode([
  item['report_id'] ?? '',
  item['project_slug'] ?? '',
  item['report_slug'] ?? '',
  item['dataset_id'] ?? '',
  item['mode'] ?? '',
  item['snapshot_id'] ?? '',
]);

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
  final String
  kind; // missing_file | failed_chart | partial_chart | missing_font
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

/// One printed page of an Original note: its top in page units, its items
/// in document order, and the oversized unit it previews instead, if any.
final class OriginalPrintPage {
  const OriginalPrintPage({
    required this.top,
    required this.items,
    this.oversized,
  });
  final double top;
  final List<Map<String, dynamic>> items;
  final Map<String, dynamic>? oversized;
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

  /// The editor's text size in page units (`annotationsTextStyle`).
  static const double editorTextSize = 16;
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
    Set<String> partialChartIds = const {},
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
        if (kind == 'reports_embed') {
          final refId = '${node['report_id'] ?? ''}';
          final cardKey = _reportImageKey(Map<String, dynamic>.from(node));
          if (failedChartIds.contains(refId) ||
              failedChartIds.contains(cardKey)) {
            issues.add(
              PdfPreflightIssue(
                kind: 'failed_chart',
                refId: refId,
                message: 'Report snapshot $refId is unavailable.',
              ),
            );
          }
          if (partialChartIds.contains(refId) ||
              partialChartIds.contains(cardKey)) {
            issues.add(
              PdfPreflightIssue(
                kind: 'partial_chart',
                refId: refId,
                message: 'Report snapshot $refId contains only some rows.',
              ),
            );
          }
          // Access visibility is owned by Reports, not the note document.
          // Warn for every personal export; public output uses a lock notice.
          if (options.audience == PdfAudience.personal) {
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

  /// The printed pages of an Original document. Pagination works on the
  /// top-level units the editor keeps together (a group with all its
  /// members, or one item) and on their real page bounds: strokes and shapes
  /// have no `x`/`y`/`height`, so their bounds come from their nodes and
  /// points plus half the line width, like the editor computes them.
  static List<OriginalPrintPage> planOriginalPages(
    NoteDocument document, {
    required double printableHeight,
  }) {
    final rawItems = ((document.toJson()['items'] as List?) ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final byId = <String, Map<String, dynamic>>{
      for (final it in rawItems)
        if (it['id'] case final String id) id: it,
    };
    final layout = DocumentLayout.of(document);
    final units =
        <
          ({
            Map<String, dynamic> root,
            List<Map<String, dynamic>> items,
            double top,
            double height,
          })
        >[];
    double boxTop(Map<String, dynamic> it) =>
        (it['y'] as num?)?.toDouble() ?? 0.0;
    double boxHeight(Map<String, dynamic> it) =>
        (it['height'] as num?)?.toDouble() ?? 40.0;
    if (layout == null) {
      for (final it in rawItems) {
        units.add((
          root: it,
          items: [it],
          top: boxTop(it),
          height: boxHeight(it),
        ));
      }
    } else {
      for (final id in layout.units) {
        final ids = layout.withDescendants(id);
        final members = [for (final m in ids) ?byId[m]]
          ..removeWhere((it) => it['kind'] == 'group');
        final rect = layout.boundsOf(ids);
        final root = byId[id]!;
        if (rect == null) {
          units.add((
            root: root,
            items: members,
            top: boxTop(root),
            height: boxHeight(root),
          ));
          continue;
        }
        var pad = 0.0;
        for (final it in members) {
          final line = switch (it['kind']) {
            'stroke' => (it['width'] as num?)?.toDouble() ?? 0.0,
            'shape' => (it['line_width'] as num?)?.toDouble() ?? 0.0,
            _ => 0.0,
          };
          pad = math.max(pad, line / 2);
        }
        units.add((
          root: root,
          items: members,
          top: rect.top.toDouble() - pad,
          height: rect.height.toDouble() + pad * 2,
        ));
      }
    }
    final breaks = computeOriginalPageBreaks(
      items: [
        for (final u in units) {'y': u.top, 'height': u.height},
      ],
      printableHeight: printableHeight,
    );
    final pages = <OriginalPrintPage>[];
    for (var p = 0; p < breaks.length; p++) {
      final yStart = breaks[p];
      final from = p == 0 ? double.negativeInfinity : yStart;
      final to = p + 1 < breaks.length ? breaks[p + 1] : double.infinity;
      final onPage = [
        for (final u in units)
          if (u.top >= from && u.top < to) u,
      ];
      if (onPage.isEmpty && p > 0) continue;
      final oversized = onPage
          .where((u) => u.height > printableHeight)
          .map((u) => u.root)
          .firstOrNull;
      // Document order is the drawing order (later is on top).
      final ids = {
        for (final u in onPage)
          for (final it in u.items) it,
      };
      pages.add(
        OriginalPrintPage(
          top: yStart,
          items: [
            for (final it in rawItems)
              if (ids.contains(it)) it,
          ],
          oversized: oversized,
        ),
      );
    }
    return pages;
  }

  /// The filled outlines of a stroke or shape [item] in page units, computed
  /// by the editor's own brush outlines (`ink_outline.dart`): one fill per
  /// outline with its color and opacity, a shape fill before its line. Empty
  /// for other kinds, and for a stroke whose brush this app does not know
  /// (it is never drawn with another brush).
  static List<({List<List<InkVec>> pieces, int argb})> inkFills(
    DocumentItem? item,
  ) {
    if (item is StrokeItem) {
      final o = strokeOutline(item);
      return o == null ? const [] : [(pieces: o.pieces, argb: o.argb)];
    }
    if (item is ShapeItem) {
      final o = shapeOutline(item);
      if (o == null) return const [];
      return [
        if (o.fill case final fill? when o.fillArgb != null)
          (pieces: [fill], argb: o.fillArgb!),
        (pieces: o.line.pieces, argb: o.line.argb),
      ];
    }
    return const [];
  }

  static Map<String, DocumentItem> _typedItems(NoteDocument document) => {
    if (document is PaperDocument)
      for (final it in document.items)
        if (it.id case final String id) id: it,
  };

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
    Set<String> partialChartIds = const {},
    Map<String, Uint8List> reportImages = const {},
    Map<String, Uint8List> attachments = const {},
    pw.Font? baseFont,
    pw.Font? boldFont,
    pw.Font? thaiFont,
    Uint8List? regularFontBytes,
    Uint8List? boldFontBytes,
  }) async {
    final exportReportImages = options.audience == PdfAudience.public
        ? const <String, Uint8List>{}
        : reportImages;
    final krillaReady = await KrillaPdfBackend.isAvailable();
    final resolvedRegular = krillaReady
        ? (regularFontBytes ??
              await _tryLoadBundledFont('IBMPlexSansThai-Regular.ttf'))
        : null;
    final resolvedBold = krillaReady
        ? (boldFontBytes ??
              await _tryLoadBundledFont('IBMPlexSansThai-Bold.ttf'))
        : null;
    // The native Krilla bridge currently has no raster-image payload. Keep
    // the generated preview and saved PDF on the same image-capable engine.
    final useKrilla =
        krillaReady && resolvedRegular != null && exportReportImages.isEmpty;
    final pre = preflight(
      original: original,
      typed: typed,
      options: options,
      availableFileIds: availableFileIds,
      failedChartIds: failedChartIds,
      partialChartIds: partialChartIds,
      fontsAvailable: useKrilla || (baseFont != null && thaiFont != null),
    );

    if (!pre.ok && !options.continueWithPlaceholders) {
      return PdfExportOutput(preflight: pre, pdfs: const []);
    }

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
              reportImages: exportReportImages,
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
              reportImages: exportReportImages,
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
    if (kind == 'reports_embed') {
      if (options.audience == PdfAudience.public) {
        return 'Restricted content (lock notice)';
      }
      return 'Report snapshot unavailable (marked placeholder)';
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

    final typedItems = _typedItems(document);
    final plan = planOriginalPages(
      document,
      printableHeight: printableH / scale,
    );

    final pagesOut = <Map<String, dynamic>>[];
    for (var p = 0; p < plan.length; p++) {
      final yStart = plan[p].top;
      final pageItems = plan[p].items;

      final rects = <Map<String, dynamic>>[];
      final fills = <Map<String, dynamic>>[];
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

      final oversized = plan[p].oversized;

      if (oversized != null) {
        final item = oversized;
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
          final kind = '${item['kind'] ?? 'text'}';
          if (kind == 'stroke' || kind == 'shape') {
            for (final f in inkFills(typedItems[item['id']])) {
              fills.add({
                'argb': f.argb,
                'pieces': [
                  for (final piece in f.pieces)
                    [
                      for (final v in piece)
                        [
                          marginPt + v.x * scale,
                          contentTop + (v.y - yStart) * scale,
                        ],
                    ],
                ],
              });
            }
            continue;
          }
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

          if (kind != 'text') {
            rects.add({
              'x': x,
              'y': y,
              'width': w,
              'height': h,
              'stroke_width': 0.8,
              'gray': 170,
            });
          }

          if (kind == 'text') {
            // The editor draws text at 16 page units (or the span size) from
            // the box corner, without an inset; print it at the same scale.
            // Each span keeps its size, bold, italic, strikethrough and
            // color; [y] is the top of the first line.
            final spans = nativeSpans(
              (item['spans'] as List?) ?? const [],
              baseSize: editorTextSize * scale,
              scale: scale,
            );
            runs.add({
              'text': spans.map((sp) => sp['text']).join(),
              'x': x,
              'y': y,
              'max_width': math.max(20.0, w),
              'font_size': editorTextSize * scale,
              'line_height': editorTextSize * scale * 1.25,
              'spans': spans,
            });
            continue;
          }
          {
            final summary = _itemTextSummary(
              item,
              kind: kind,
              options: options,
            );
            final isRestricted =
                kind == 'reports_embed' &&
                options.audience == PdfAudience.public;
            const fontSize = 9.0;
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
      pagesOut.add({'rects': rects, 'fills': fills, 'runs': runs});
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
          'spans': nativeSpans(
            spans,
            baseSize: 14.0,
            scale: 14.0 / editorTextSize,
            bold: true,
          ),
        });
      } else if (kind == 'reports_embed' || kind == 'task' || kind == 'quiz') {
        final isRestricted =
            kind == 'reports_embed' && options.audience == PdfAudience.public;
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
          'spans': nativeSpans(
            spans,
            baseSize: 11.0,
            scale: 11.0 / editorTextSize,
          ),
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

  /// The spans of an editor text value for the native renderer: each span
  /// at its own size times [scale] (or [baseSize]), with bold, italic,
  /// strikethrough and its color as 0xAARRGGBB.
  static List<Map<String, Object?>> nativeSpans(
    List<Object?> spans, {
    required double baseSize,
    required double scale,
    bool bold = false,
  }) => [
    for (final sp in spans)
      if (sp is Map && '${sp['text'] ?? ''}'.isNotEmpty)
        {
          'text': '${sp['text']}',
          'size': (sp['size'] as num?) == null
              ? baseSize
              : (sp['size'] as num).toDouble() * scale,
          'bold': bold || sp['bold'] == true,
          'italic': sp['italic'] == true,
          'strike': sp['strikethrough'] == true,
          if (sp['color'] is String)
            'argb': colorArgb(sp['color'] as String, 1),
        },
  ];

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
    required Map<String, Uint8List> reportImages,
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

    final typedItems = _typedItems(document);
    final plan = planOriginalPages(
      document,
      printableHeight: printableH / scale,
    );

    for (var p = 0; p < plan.length; p++) {
      final yStart = plan[p].top;
      final pageItems = plan[p].items;
      final oversized = plan[p].oversized;

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
              if (oversized != null)
                _buildOversizedPage(
                  oversized,
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
                        if (it['kind'] == 'stroke' || it['kind'] == 'shape')
                          _buildInkLayer(
                            inkFills(typedItems[it['id']]),
                            yOrigin: yStart,
                            scale: scale,
                          )
                        else
                          _buildPositionedOriginalItem(
                            it,
                            yOrigin: yStart,
                            scale: scale,
                            options: options,
                            reportImages: reportImages,
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

  /// One stroke or shape as vector fills over the whole content area, in
  /// item order with the other items, following the drawing rule of
  /// `ink_outline.dart`: each outline is one non-zero filled path.
  pw.Widget _buildInkLayer(
    List<({List<List<InkVec>> pieces, int argb})> fills, {
    required double yOrigin,
    required double scale,
  }) {
    return pw.Positioned.fill(
      child: pw.CustomPaint(
        painter: (canvas, size) {
          for (final f in fills) {
            canvas
              ..saveContext()
              ..setGraphicState(
                PdfGraphicState(fillOpacity: ((f.argb >> 24) & 0xFF) / 255),
              )
              ..setFillColor(PdfColor.fromInt(f.argb | 0xFF000000));
            for (final piece in f.pieces) {
              if (piece.length < 3) continue;
              canvas.moveTo(
                piece.first.x * scale,
                size.y - (piece.first.y - yOrigin) * scale,
              );
              for (final v in piece.skip(1)) {
                canvas.lineTo(v.x * scale, size.y - (v.y - yOrigin) * scale);
              }
              canvas.closePath();
            }
            canvas
              ..fillPath()
              ..restoreContext();
          }
        },
      ),
    );
  }

  pw.Widget _buildPositionedOriginalItem(
    Map<String, dynamic> item, {
    required double yOrigin,
    required double scale,
    required PdfExportOptions options,
    required Map<String, Uint8List> reportImages,
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

    if (kind == 'text') {
      return pw.Positioned(
        left: math.max(0, x),
        top: math.max(0, y),
        child: pw.SizedBox(width: w, child: _editorText(item, scale)),
      );
    }

    return pw.Positioned(
      left: math.max(0, x),
      top: math.max(0, y),
      child: pw.Container(
        width: w,
        height: h,
        padding: const pw.EdgeInsets.all(4),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColors.grey400),
        ),
        child: _renderItemBody(
          item,
          kind: kind,
          options: options,
          width: w,
          height: h,
          reportImages: reportImages,
        ),
      ),
    );
  }

  /// A free text item as the editor draws it (paper_layers.dart): 16 page
  /// units by default, with each span's size, bold, italic, strikethrough
  /// and color, scaled to the printed page.
  pw.Widget _editorText(Map<String, dynamic> item, double scale) {
    final spans = [
      for (final sp in (item['spans'] as List?) ?? const [])
        if (sp is Map) sp,
    ];
    return pw.RichText(
      text: pw.TextSpan(
        style: pw.TextStyle(fontSize: editorTextSize * scale),
        children: [
          for (final sp in spans)
            pw.TextSpan(
              text: '${sp['text'] ?? ''}',
              style: pw.TextStyle(
                fontSize: (sp['size'] as num?) == null
                    ? null
                    : (sp['size'] as num).toDouble() * scale,
                fontWeight: sp['bold'] == true ? pw.FontWeight.bold : null,
                fontStyle: sp['italic'] == true ? pw.FontStyle.italic : null,
                decoration: sp['strikethrough'] == true
                    ? pw.TextDecoration.lineThrough
                    : null,
                color: sp['color'] is String
                    ? PdfColor.fromInt(colorArgb(sp['color'] as String, 1))
                    : null,
              ),
            ),
        ],
      ),
    );
  }

  pw.Widget _renderItemBody(
    Map<String, dynamic> item, {
    required String kind,
    required PdfExportOptions options,
    required double width,
    required double height,
    Map<String, Uint8List> reportImages = const {},
  }) {
    if (kind == 'reports_embed') {
      if (options.audience == PdfAudience.public) {
        return pw.Text(
          'Restricted content (lock notice)',
          style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
        );
      }
      final image = reportImages[_reportImageKey(item)];
      if (image != null) {
        return pw.Image(pw.MemoryImage(image), fit: pw.BoxFit.contain);
      }
      return pw.Text(
        'Report snapshot unavailable (marked placeholder)',
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
    required Map<String, Uint8List> reportImages,
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
            ..._buildTypedBlock(
              blocks,
              i,
              options: options,
              reportImages: reportImages,
            ),
        ],
      ),
    );
    return doc.save();
  }

  List<pw.Widget> _buildTypedBlock(
    List<Map<String, dynamic>> blocks,
    int index, {
    required PdfExportOptions options,
    required Map<String, Uint8List> reportImages,
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
    if (kind == 'reports_embed' || kind == 'task' || kind == 'quiz') {
      return [
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 4),
          child: pw.SizedBox(
            width: 400,
            height: 320,
            child: _renderItemBody(
              b,
              kind: kind,
              options: options,
              width: 400,
              height: 320,
              reportImages: reportImages,
            ),
          ),
        ),
      ];
    }
    return [pw.Paragraph(text: text, style: const pw.TextStyle(fontSize: 11))];
  }
}
