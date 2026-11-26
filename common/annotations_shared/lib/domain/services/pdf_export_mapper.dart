import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/ink.dart';
import '../models/note_document.dart';
import 'editor_rules.dart';
import 'ink_outline.dart';
import 'krilla_pdf_backend.dart';
import 'task_card_service.dart';
import 'quiz_card_service.dart';

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

String _quizReferenceId(Map<String, dynamic> item) {
  final quizId = '${item['quiz_id'] ?? ''}'.trim();
  if (quizId.isNotEmpty) return quizId;
  return '${item['study_id'] ?? ''}'.trim();
}

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
  final String kind;
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
  static const double _printTitleFontSize = 16;
  static const double _printTitleLineHeight = 22;
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
    Map<String, TaskSummary> taskSummaries = const {},
    Map<String, QuizSummary> quizSummaries = const {},
    Map<String, List<List<String>>> csvTables = const {},
    Map<String, Uint8List> pdfPreviews = const {},
    Set<String> invalidImageFileIds = const {},
    bool fontsAvailable = true,
  }) {
    final issues = <PdfPreflightIssue>[];
    final issueKeys = <String>{};
    var hasPrivateChartWarning = false;

    void unavailable(String refId, String message) {
      if (issueKeys.add('unsupported_content:$refId')) {
        issues.add(
          PdfPreflightIssue(
            kind: 'unsupported_content',
            refId: refId,
            message: message,
          ),
        );
      }
    }

    void missingFile(String fileId) {
      if (issueKeys.add('missing_file:$fileId')) {
        issues.add(
          PdfPreflightIssue(
            kind: 'missing_file',
            refId: fileId,
            message: 'Missing local or synced file $fileId.',
          ),
        );
      }
    }

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
        final fileIds = <String>{
          if (node['file_id'] is String) node['file_id'] as String,
          if ((kind == 'website_card' || kind == 'youtube_card') &&
              node['preview_file_id'] is String)
            node['preview_file_id'] as String,
        };
        for (final fileId in fileIds) {
          if (fileId.isEmpty) continue;
          if (!availableFileIds.contains(fileId)) {
            missingFile(fileId);
          } else if (invalidImageFileIds.contains(fileId)) {
            unavailable(fileId, 'Image file $fileId cannot be printed.');
          }
        }

        // Nested schema objects (for example `page.background.kind == blank`)
        // also carry a `kind`, but only identified document items are export
        // content. Do not report editor metadata as an unsupported item.
        if (node.containsKey('id') &&
            kind.isNotEmpty &&
            !_knownKinds.contains(kind)) {
          final id = '${node['id'] ?? kind}';
          unavailable(id, 'Unsupported document item kind: $kind.');
        }
        if (node.containsKey('id') &&
            kind == 'shape' &&
            !_knownShapes.contains('${node['shape'] ?? ''}')) {
          unavailable('${node['id'] ?? 'shape'}', 'Unsupported shape.');
        }
        if (kind == 'csv_table' || kind == 'pdf_preview') {
          final fileId = node['file_id'];
          if (fileId is! String || fileId.isEmpty) {
            unavailable('${node['id'] ?? kind}', 'File reference is invalid.');
          } else if (availableFileIds.contains(fileId) &&
              (kind == 'csv_table'
                  ? !csvTables.containsKey(fileId)
                  : !pdfPreviews.containsKey(fileId))) {
            unavailable(
              fileId,
              kind == 'csv_table'
                  ? 'CSV content is unavailable.'
                  : 'PDF page preview is unavailable.',
            );
          }
        }
        if (kind == 'task_card' && options.audience == PdfAudience.personal) {
          final taskId = '${node['task_id'] ?? ''}';
          if (taskId.isEmpty) {
            unavailable('${node['id'] ?? kind}', 'Task reference is invalid.');
          } else if (!taskSummaries.containsKey(taskId)) {
            unavailable(taskId, 'Task details are unavailable.');
          }
        }
        if (kind == 'quiz_card' && options.audience == PdfAudience.personal) {
          final quizId = _quizReferenceId(Map<String, dynamic>.from(node));
          if (quizId.isEmpty) {
            unavailable('${node['id'] ?? kind}', 'Quiz reference is invalid.');
          } else if (!quizSummaries.containsKey(quizId)) {
            unavailable(quizId, 'Quiz details are unavailable.');
          }
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
      for (final item
          in (original is PaperDocument
              ? original.items
              : const <DocumentItem>[])) {
        _preflightInk(item, unavailable, typed: false);
      }
    }
    if (options.mode != PdfExportMode.original && typed != null) {
      scan(typed.toJson());
      for (final item
          in (typed is TypedDocument ? typed.blocks : const <DocumentItem>[])) {
        _preflightInk(item, unavailable, typed: true);
      }
    }

    return PdfPreflightResult(
      issues: issues,
      hasPrivateChartWarning: hasPrivateChartWarning,
    );
  }

  static const _knownKinds = <String>{
    'text',
    'image',
    'group',
    'stroke',
    'shape',
    'heading',
    'paragraph',
    'list',
    'table',
    'figure',
    'handwriting',
    'file', // Older file references remain printable as static references.
    'task', // Legacy references remain printable from their stored summary.
    'quiz', // Legacy references remain printable from their stored summary.
    'h1',
    'h2',
    'h3',
    'file_card',
    'link_card',
    'website_card',
    'youtube_card',
    'csv_table',
    'pdf_preview',
    'reports_embed',
    'task_card',
    'quiz_card',
  };

  static const _knownShapes = <String>{
    'circle',
    'rectangle',
    'triangle',
    'path',
  };

  static const _sharedCardKinds = <String>{
    'file_card',
    'link_card',
    'website_card',
    'youtube_card',
    'csv_table',
    'pdf_preview',
    'reports_embed',
    'task_card',
    'quiz_card',
    'task', // Legacy serialized references.
    'quiz', // Legacy serialized references.
  };

  static const _paperKinds = <String>{
    'text',
    'image',
    'group',
    'stroke',
    'shape',
    ..._sharedCardKinds,
    'file',
  };

  static const _typedKinds = <String>{
    'heading',
    'paragraph',
    'list',
    'table',
    'figure',
    'handwriting',
    ..._sharedCardKinds,
    'file',
    'h1',
    'h2',
    'h3',
  };

  static bool _isSummaryKind(String kind) => const {
    'reports_embed',
    'task',
    'quiz',
    'task_card',
    'quiz_card',
  }.contains(kind);

  static bool _isReferenceCardKind(String kind) => const {
    'file',
    'file_card',
    'link_card',
    'website_card',
    'youtube_card',
    'csv_table',
    'pdf_preview',
  }.contains(kind);

  static void _preflightInk(
    DocumentItem item,
    void Function(String, String) unavailable, {
    required bool typed,
  }) {
    if (item is OpaqueItem) {
      final supportedFamilyKind = (typed ? _typedKinds : _paperKinds).contains(
        item.kind,
      );
      if (!supportedFamilyKind || (typed && item.kind == 'image')) {
        unavailable(item.id ?? item.kind, 'Unsupported document content.');
      }
    } else if (item is StrokeItem && strokeOutline(item) == null) {
      unavailable(item.id, 'This handwriting brush is unsupported.');
    } else if (item is ShapeItem && shapeOutline(item) == null) {
      unavailable(item.id, 'This shape cannot be printed.');
    } else if (item is HandwritingBlock) {
      if (item.ink.isEmpty) {
        unavailable(item.id, 'This handwriting block has no printable ink.');
      }
      for (final ink in item.ink) {
        _preflightInk(ink, unavailable, typed: true);
      }
    }
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
    if (document is TypedDocument)
      for (final it in document.blocks)
        if (it.id case final String id) id: it,
  };

  static Set<String> _inlineImageFileIds(Iterable<NoteDocument?> documents) {
    final ids = <String>{};
    void scan(Object? value) {
      if (value is Map) {
        final kind = '${value['kind'] ?? value['type'] ?? ''}';
        final key = kind == 'image' || kind == 'figure'
            ? 'file_id'
            : kind == 'website_card' || kind == 'youtube_card'
            ? 'preview_file_id'
            : null;
        if (key != null && value[key] is String) {
          final id = (value[key] as String).trim();
          if (id.isNotEmpty) ids.add(id);
        }
        for (final child in value.values) {
          scan(child);
        }
      } else if (value is List) {
        for (final child in value) {
          scan(child);
        }
      }
    }

    for (final document in documents) {
      if (document != null) scan(document.toJson());
    }
    return ids;
  }

  static bool _hasReferenceKind(
    Iterable<NoteDocument?> documents,
    Set<String> kinds,
  ) {
    var found = false;
    void scan(Object? value) {
      if (found) return;
      if (value is Map) {
        if (kinds.contains('${value['kind'] ?? value['type'] ?? ''}')) {
          found = true;
          return;
        }
        for (final child in value.values) {
          scan(child);
        }
      } else if (value is List) {
        for (final child in value) {
          scan(child);
        }
      }
    }

    for (final document in documents) {
      if (document != null) scan(document.toJson());
    }
    return found;
  }

  static Map<String, String> _fileReferenceKinds(
    Iterable<NoteDocument?> documents,
  ) {
    final references = <String, String>{};
    void scan(Object? value) {
      if (value is Map) {
        final kind = '${value['kind'] ?? value['type'] ?? ''}';
        final fileId = value['file_id'];
        if ((kind == 'csv_table' || kind == 'pdf_preview') &&
            fileId is String &&
            fileId.isNotEmpty) {
          references.putIfAbsent(fileId, () => kind);
        }
        for (final child in value.values) {
          scan(child);
        }
      } else if (value is List) {
        for (final child in value) {
          scan(child);
        }
      }
    }

    for (final document in documents) {
      if (document != null) scan(document.toJson());
    }
    return references;
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

  /// Reserves a conservative first-page title block for both renderers.
  /// Krilla wraps with shaped glyph widths and ICU line breaks; this bound
  /// intentionally uses fewer than the usual printable characters per line
  /// so a long or Thai title cannot collide with fixed-position page content.
  static double _titleReservePt(String title) {
    if (title.isEmpty) return 0;
    const conservativeRunesPerLine = 32;
    var lines = 0;
    for (final line in title.split('\n')) {
      lines += math.max(
        1,
        (line.runes.length + conservativeRunesPerLine - 1) ~/
            conservativeRunesPerLine,
      );
    }
    return math.max(28.0, 6.0 + lines * _printTitleLineHeight).toDouble();
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
    Map<String, TaskSummary> taskSummaries = const {},
    Map<String, QuizSummary> quizSummaries = const {},
    Map<String, List<List<String>>> csvTables = const {},
    Map<String, Uint8List> pdfPreviews = const {},
    pw.Font? baseFont,
    pw.Font? boldFont,
    pw.Font? thaiFont,
    Uint8List? regularFontBytes,
    Uint8List? boldFontBytes,
  }) async {
    final exportQuizSummaries = options.audience == PdfAudience.public
        ? const <String, QuizSummary>{}
        : quizSummaries;
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
    final selectedOriginal = options.mode == PdfExportMode.typed
        ? null
        : original;
    final selectedTyped = options.mode == PdfExportMode.original ? null : typed;
    final imageIds = _inlineImageFileIds([selectedOriginal, selectedTyped]);
    final invalidImageFileIds = <String>{};
    for (final id in imageIds) {
      final bytes = attachments[id];
      if (bytes == null) continue;
      try {
        if (img.decodeImage(bytes) == null) invalidImageFileIds.add(id);
      } on Object {
        invalidImageFileIds.add(id);
      }
    }
    final hasAvailableInlineImages = imageIds.any(
      (id) => attachments.containsKey(id) && !invalidImageFileIds.contains(id),
    );
    final hasTypedHandwriting =
        selectedTyped is TypedDocument &&
        selectedTyped.blocks.any((block) => block is HandwritingBlock);
    final hasCsvOrPdfReferences = _hasReferenceKind(
      [selectedOriginal, selectedTyped],
      const {'csv_table', 'pdf_preview'},
    );
    final renderableAttachments = Map<String, Uint8List>.from(attachments)
      ..removeWhere((id, _) => invalidImageFileIds.contains(id));
    // Krilla's flow blocks have no raster-image or handwriting payload. Use
    // the existing image-capable PDF path when those items are present.
    final useKrilla =
        krillaReady &&
        resolvedRegular != null &&
        exportReportImages.isEmpty &&
        !hasAvailableInlineImages &&
        !hasCsvOrPdfReferences &&
        !hasTypedHandwriting;
    final pre = preflight(
      original: original,
      typed: typed,
      options: options,
      availableFileIds: availableFileIds,
      failedChartIds: failedChartIds,
      partialChartIds: partialChartIds,
      taskSummaries: taskSummaries,
      quizSummaries: exportQuizSummaries,
      csvTables: csvTables,
      pdfPreviews: pdfPreviews,
      invalidImageFileIds: invalidImageFileIds,
      fontsAvailable: useKrilla || (baseFont != null && thaiFont != null),
    );

    if (!pre.ok && !options.continueWithPlaceholders) {
      return PdfExportOutput(preflight: pre, pdfs: const []);
    }

    final pdfs = <PdfNamedFile>[];
    final companions = <PdfCompanionFile>[];
    for (final entry in _fileReferenceKinds([
      selectedOriginal,
      selectedTyped,
    ]).entries) {
      final bytes = attachments[entry.key];
      final renderable = entry.value == 'csv_table'
          ? csvTables.containsKey(entry.key)
          : pdfPreviews.containsKey(entry.key);
      if (bytes == null || !renderable) continue;
      final safeId = entry.key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final extension = entry.value == 'csv_table' ? 'csv' : 'pdf';
      final stem = 'source-$safeId';
      var filename = '$stem.$extension';
      var suffix = 2;
      while (companions.any((companion) => companion.filename == filename)) {
        filename = '$stem-$suffix.$extension';
        suffix++;
      }
      companions.add(PdfCompanionFile(filename: filename, bytes: bytes));
    }

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
              taskSummaries: taskSummaries,
              quizSummaries: exportQuizSummaries,
              regularFontBytes: resolvedRegular,
              boldFontBytes: resolvedBold,
            )
          : await _buildOriginalPdf(
              title: title,
              document: original,
              options: options,
              attachments: attachments,
              renderableAttachments: renderableAttachments,
              reportImages: exportReportImages,
              taskSummaries: taskSummaries,
              quizSummaries: exportQuizSummaries,
              csvTables: csvTables,
              pdfPreviews: pdfPreviews,
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
              taskSummaries: taskSummaries,
              quizSummaries: exportQuizSummaries,
              regularFontBytes: resolvedRegular,
              boldFontBytes: resolvedBold,
            )
          : await _buildTypedPdf(
              title: title,
              document: typed,
              options: options,
              reportImages: exportReportImages,
              attachments: renderableAttachments,
              taskSummaries: taskSummaries,
              quizSummaries: exportQuizSummaries,
              companions: companions,
              csvTables: csvTables,
              pdfPreviews: pdfPreviews,
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
    required Map<String, TaskSummary> taskSummaries,
    Map<String, QuizSummary> quizSummaries = const {},
  }) {
    if ((kind == 'task_card' || kind == 'quiz_card') &&
        options.audience == PdfAudience.public) {
      return 'Restricted content (lock notice)';
    }
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
    if (kind == 'task_card') {
      final taskId = '${item['task_id'] ?? ''}';
      final task = taskSummaries[taskId];
      if (task == null) {
        return 'Task details unavailable (reference $taskId; marked placeholder)';
      }
      final status = task.completed ? 'completed' : 'open';
      return [
        'Task: ${task.title} [$status]',
        if (task.dueDate?.trim().isNotEmpty == true)
          'Due: ${task.dueDate!.trim()}',
        if (task.description?.trim().isNotEmpty == true)
          'Description: ${task.description!.trim()}',
      ].join('\n');
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
    if (kind == 'quiz_card') {
      final quizId = _quizReferenceId(item);
      final quiz = quizSummaries[quizId];
      if (quiz == null) {
        return 'Quiz details unavailable (reference $quizId; marked placeholder)';
      }
      final title = quiz.title?.trim();
      final subject = quiz.subject?.trim();
      final questionCount = quiz.questionCount;
      return [
        'Quiz: ${title == null || title.isEmpty ? 'Title unavailable' : title}',
        'Subject: ${subject == null || subject.isEmpty ? 'Unavailable' : subject}',
        questionCount == null
            ? 'Question count unavailable'
            : '$questionCount questions',
      ].join('\n');
    }
    if (kind == 'link_card' ||
        kind == 'website_card' ||
        kind == 'youtube_card') {
      final title = '${item['title'] ?? ''}'.trim();
      final site = '${item['site_name'] ?? ''}'.trim();
      final description = '${item['description'] ?? ''}'.trim();
      final url = '${item['url'] ?? ''}'.trim();
      return [
        if (title.isNotEmpty) title,
        if (site.isNotEmpty && site != title) site,
        if (description.isNotEmpty) description,
        if (url.isNotEmpty) url,
      ].join('\n');
    }
    if (kind == 'file_card' ||
        kind == 'csv_table' ||
        kind == 'pdf_preview' ||
        kind == 'file') {
      final name = '${item['name'] ?? ''}'.trim();
      final fileId = '${item['file_id'] ?? ''}'.trim();
      final label = kind == 'csv_table'
          ? 'CSV file'
          : kind == 'pdf_preview'
          ? 'PDF file'
          : 'File';
      return '$label: ${name.isNotEmpty ? name : fileId}';
    }
    if (kind == 'image' || kind == 'figure') {
      final fileId = '${item['file_id'] ?? ''}';
      return 'Image unavailable (reference $fileId; marked placeholder)';
    }
    if (kind == 'text') {
      final spans = (item['spans'] as List?) ?? const [];
      return spans.map((s) => s is Map ? '${s['text'] ?? ''}' : '$s').join();
    }
    return 'Unsupported content (kind $kind; marked placeholder)';
  }

  Future<Uint8List> _buildOriginalPdfKrilla({
    required String title,
    required NoteDocument document,
    required PdfExportOptions options,
    required Map<String, Uint8List> attachments,
    required List<PdfCompanionFile> companions,
    required Map<String, TaskSummary> taskSummaries,
    Map<String, QuizSummary> quizSummaries = const {},
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
    final titleReservePt = _titleReservePt(title);

    final typedItems = _typedItems(document);
    final plan = planOriginalPages(
      document,
      printableHeight:
          math.max(1.0, printableH - titleReservePt).toDouble() / scale,
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
          'font_size': _printTitleFontSize,
          'line_height': _printTitleLineHeight,
          'bold': true,
        });
        contentTop += titleReservePt;
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
            final itemFills = inkFills(typedItems[item['id']]);
            for (final f in itemFills) {
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
            if (itemFills.isEmpty) {
              final fallbackX = _inkItemCoordinate(item, 'x');
              final fallbackY = _inkItemCoordinate(item, 'y');
              rects.add({
                'x': marginPt + fallbackX * scale,
                'y': contentTop + (fallbackY - yStart) * scale,
                'width': 150.0,
                'height': 28.0,
                'stroke_width': 0.8,
                'gray': 170,
              });
              runs.add({
                'text': 'Ink unavailable (marked placeholder)',
                'x': marginPt + fallbackX * scale + 4.0,
                'y': contentTop + (fallbackY - yStart) * scale + 13.0,
                'max_width': 140.0,
                'font_size': 8.0,
                'line_height': 11.0,
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
            var summary = _itemTextSummary(
              item,
              kind: kind,
              options: options,
              taskSummaries: taskSummaries,
              quizSummaries: quizSummaries,
            );
            if ((kind == 'website_card' || kind == 'youtube_card') &&
                item['preview_file_id'] is String) {
              summary = 'Preview unavailable (marked placeholder)\n$summary';
            }
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
    required Map<String, TaskSummary> taskSummaries,
    Map<String, QuizSummary> quizSummaries = const {},
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
      if (kind == 'list') {
        final items = (b['items'] as List?) ?? const [];
        for (var index = 0; index < items.length; index++) {
          final item = items[index];
          if (item is! Map) continue;
          final itemSpans = (item['spans'] as List?) ?? const [];
          final marker = b['ordered'] == true ? '${index + 1}. ' : '• ';
          final outputSpans = nativeSpans(
            [
              {'text': marker, 'bold': true},
              ...itemSpans,
            ],
            baseSize: 11,
            scale: 11.0 / editorTextSize,
          );
          blocksOut.add({
            'kind': 'list_item',
            'text': '$marker${itemSpans.map(_spanText).join()}',
            'font_size': 11.0,
            'line_height': 16.5,
            'space_after': 2.0,
            'spans': outputSpans,
          });
        }
        continue;
      }
      if (kind == 'table') {
        final rows = (b['rows'] as List?) ?? const [];
        for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
          final row = rows[rowIndex];
          if (row is! Map) continue;
          final cells = (row['cells'] as List?) ?? const [];
          final isHeader = b['header'] == true && rowIndex == 0;
          final rowSpans = <Object?>[];
          for (var cellIndex = 0; cellIndex < cells.length; cellIndex++) {
            if (cellIndex > 0) rowSpans.add({'text': ' | '});
            final cell = cells[cellIndex];
            if (cell is Map) {
              rowSpans.addAll((cell['spans'] as List?) ?? const []);
            }
          }
          blocksOut.add({
            'kind': 'table_row',
            'text': rowSpans.map(_spanText).join(),
            'font_size': 11.0,
            'line_height': 16.5,
            'space_after': 3.0,
            'spans': nativeSpans(
              rowSpans,
              baseSize: 11,
              scale: 11.0 / editorTextSize,
              bold: isHeader,
            ),
          });
        }
        continue;
      }
      if (kind == 'figure') {
        final caption = (b['caption'] as List?) ?? const [];
        blocksOut.add({
          'kind': 'figure_image_placeholder',
          'text': 'Figure image unavailable (marked placeholder)',
          'font_size': 9.5,
          'line_height': 14.0,
          'space_after': 3.0,
        });
        if (caption.isNotEmpty) {
          final captionSpans = <Object?>[
            {'text': 'Figure: ', 'bold': true},
            ...caption,
          ];
          blocksOut.add({
            'kind': 'figure_caption',
            'text': captionSpans.map(_spanText).join(),
            'font_size': 11.0,
            'line_height': 16.5,
            'space_after': 6.0,
            'spans': nativeSpans(
              captionSpans,
              baseSize: 11,
              scale: 11.0 / editorTextSize,
            ),
          });
        }
        continue;
      }
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
      } else if (_isSummaryKind(kind) || _isReferenceCardKind(kind)) {
        final isRestricted =
            (kind == 'reports_embed' ||
                kind == 'task_card' ||
                kind == 'quiz_card') &&
            options.audience == PdfAudience.public;
        var summary = _itemTextSummary(
          b,
          kind: kind,
          options: options,
          taskSummaries: taskSummaries,
          quizSummaries: quizSummaries,
        );
        if ((kind == 'website_card' || kind == 'youtube_card') &&
            b['preview_file_id'] is String) {
          summary = 'Preview unavailable (marked placeholder)\n$summary';
        }
        blocksOut.add({
          'kind': kind,
          'text': summary,
          'font_size': 9.5,
          'line_height': 14.0,
          'muted': isRestricted,
          'space_after': 6.0,
        });
      } else if (kind == 'image') {
        blocksOut.add({
          'kind': 'image_placeholder',
          'text': 'Image unavailable (marked placeholder)',
          'font_size': 9.5,
          'line_height': 14.0,
          'space_after': 6.0,
        });
      } else if (!_typedKinds.contains(kind)) {
        blocksOut.add({
          'kind': 'unsupported_content',
          'text': 'Unsupported content (kind $kind; marked placeholder)',
          'font_size': 9.5,
          'line_height': 14.0,
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

  static String _spanText(Object? span) =>
      span is Map ? '${span['text'] ?? ''}' : '${span ?? ''}';

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
    required Map<String, Uint8List> renderableAttachments,
    required Map<String, Uint8List> reportImages,
    required List<PdfCompanionFile> companions,
    required Map<String, TaskSummary> taskSummaries,
    Map<String, QuizSummary> quizSummaries = const {},
    Map<String, List<List<String>>> csvTables = const {},
    Map<String, Uint8List> pdfPreviews = const {},
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
    final titleReservePt = _titleReservePt(title);

    final typedItems = _typedItems(document);
    final plan = planOriginalPages(
      document,
      printableHeight:
          math.max(1.0, printableH - titleReservePt).toDouble() / scale,
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
                          _originalInkWidget(
                            it,
                            typedItems[it['id']],
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
                            attachments: renderableAttachments,
                            taskSummaries: taskSummaries,
                            quizSummaries: quizSummaries,
                            csvTables: csvTables,
                            pdfPreviews: pdfPreviews,
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
    String? companionName,
    pw.Widget? contentPreview,
  }) {
    final id = '${item['id'] ?? 'item'}';
    final fileId = item['file_id'] as String?;
    companionName ??= 'companion-$id.json';
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
        mainAxisAlignment: pw.MainAxisAlignment.start,
        children: [
          pw.Text(
            'Preview, see full content',
            style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold),
          ),
          if (contentPreview != null) ...[
            pw.SizedBox(height: 8),
            pw.Expanded(child: contentPreview),
            pw.SizedBox(height: 8),
          ],
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

  pw.Widget _originalInkWidget(
    Map<String, dynamic> json,
    DocumentItem? item, {
    required double yOrigin,
    required double scale,
  }) {
    final fills = inkFills(item);
    if (fills.isNotEmpty) {
      return _buildInkLayer(fills, yOrigin: yOrigin, scale: scale);
    }
    final x = _inkItemCoordinate(json, 'x') * scale;
    final y = (_inkItemCoordinate(json, 'y') - yOrigin) * scale;
    return pw.Positioned(
      left: math.max(0, x),
      top: math.max(0, y),
      child: pw.Container(
        width: 150,
        height: 28,
        padding: const pw.EdgeInsets.all(3),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColors.grey600),
        ),
        child: pw.Text(
          'Ink unavailable (marked placeholder)',
          style: pw.TextStyle(fontSize: 8),
        ),
      ),
    );
  }

  static double _inkItemCoordinate(Map<String, dynamic> item, String axis) {
    final direct = item[axis];
    if (direct is num) return direct.toDouble();
    final nodes = item['nodes'];
    if (nodes is List) {
      for (final node in nodes) {
        if (node is Map && node[axis] is num) {
          return (node[axis] as num).toDouble() / 100;
        }
      }
    }
    return 0;
  }

  pw.Widget _buildPositionedOriginalItem(
    Map<String, dynamic> item, {
    required double yOrigin,
    required double scale,
    required PdfExportOptions options,
    required Map<String, Uint8List> reportImages,
    required Map<String, Uint8List> attachments,
    required Map<String, TaskSummary> taskSummaries,
    Map<String, QuizSummary> quizSummaries = const {},
    Map<String, List<List<String>>> csvTables = const {},
    Map<String, Uint8List> pdfPreviews = const {},
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
          attachments: attachments,
          taskSummaries: taskSummaries,
          quizSummaries: quizSummaries,
          csvTables: csvTables,
          pdfPreviews: pdfPreviews,
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
    Map<String, Uint8List> attachments = const {},
    Map<String, TaskSummary> taskSummaries = const {},
    Map<String, QuizSummary> quizSummaries = const {},
    Map<String, List<List<String>>> csvTables = const {},
    Map<String, Uint8List> pdfPreviews = const {},
  }) {
    if (kind == 'csv_table') {
      final rows = csvTables['${item['file_id'] ?? ''}'];
      if (rows == null) {
        return pw.Text(
          'CSV content unavailable (marked placeholder)',
          style: const pw.TextStyle(fontSize: 8),
        );
      }
      if (rows.isEmpty) {
        return pw.Container(
          width: width,
          height: height,
          alignment: pw.Alignment.centerLeft,
          padding: const pw.EdgeInsets.all(4),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: PdfColors.grey400, width: 0.5),
          ),
          child: pw.Text(
            'CSV contains no rows',
            style: pw.TextStyle(fontSize: 8),
          ),
        );
      }
      final maxColumns = rows.fold<int>(
        0,
        (count, row) => math.max(count, row.length),
      );
      final columnCount = math.min(maxColumns, 5);
      final rowCapacity = ((height - 28) / 14).floor().clamp(0, 8).toInt();
      final visibleRows = rows.take(rowCapacity).toList(growable: false);
      final omitted =
          rows.length > visibleRows.length || maxColumns > columnCount;
      return pw.Container(
        width: width,
        height: height,
        padding: const pw.EdgeInsets.all(4),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColors.grey400, width: 0.5),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            if (visibleRows.isNotEmpty)
              pw.Table(
                border: pw.TableBorder.all(
                  color: PdfColors.grey300,
                  width: 0.35,
                ),
                columnWidths: {
                  for (var column = 0; column < columnCount; column++)
                    column: const pw.FlexColumnWidth(),
                },
                children: [
                  for (
                    var rowIndex = 0;
                    rowIndex < visibleRows.length;
                    rowIndex++
                  )
                    pw.TableRow(
                      decoration: rowIndex == 0
                          ? const pw.BoxDecoration(color: PdfColors.grey200)
                          : null,
                      children: [
                        for (var column = 0; column < columnCount; column++)
                          pw.Padding(
                            padding: const pw.EdgeInsets.all(2),
                            child: pw.Text(
                              column < visibleRows[rowIndex].length
                                  ? _pdfCellPreview(
                                      visibleRows[rowIndex][column],
                                    )
                                  : '',
                              maxLines: 1,
                              style: pw.TextStyle(
                                fontSize: 6.5,
                                fontWeight: rowIndex == 0
                                    ? pw.FontWeight.bold
                                    : pw.FontWeight.normal,
                              ),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            if (omitted)
              pw.Padding(
                padding: const pw.EdgeInsets.only(top: 2),
                child: pw.Text(
                  'CSV preview is partial (shows ${visibleRows.length} of ${rows.length} rows); ZIP includes the original file.',
                  style: pw.TextStyle(fontSize: 6.5),
                ),
              ),
          ],
        ),
      );
    }

    if (kind == 'pdf_preview') {
      final preview = pdfPreviews['${item['file_id'] ?? ''}'];
      if (preview == null) {
        return pw.Text(
          'PDF page preview unavailable (marked placeholder)',
          style: const pw.TextStyle(fontSize: 8),
        );
      }
      return pw.Container(
        width: width,
        height: height,
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColors.grey500, width: 0.5),
        ),
        child: pw.Image(pw.MemoryImage(preview), fit: pw.BoxFit.contain),
      );
    }

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

    if (kind == 'image' || kind == 'figure') {
      final bytes = attachments['${item['file_id'] ?? ''}'];
      if (bytes != null) {
        return pw.Image(pw.MemoryImage(bytes), fit: pw.BoxFit.contain);
      }
      return pw.Text(
        'Image unavailable (marked placeholder)',
        style: const pw.TextStyle(fontSize: 9),
      );
    }

    if (kind == 'website_card' || kind == 'youtube_card') {
      final preview = attachments['${item['preview_file_id'] ?? ''}'];
      final summary = _itemTextSummary(
        item,
        kind: kind,
        options: options,
        taskSummaries: taskSummaries,
        quizSummaries: quizSummaries,
      );
      return pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          if (preview != null)
            pw.Expanded(
              child: pw.Image(pw.MemoryImage(preview), fit: pw.BoxFit.contain),
            )
          else if (item['preview_file_id'] is String)
            pw.Text('Preview unavailable (marked placeholder)'),
          pw.Text(summary, style: const pw.TextStyle(fontSize: 8)),
        ],
      );
    }

    if (_isSummaryKind(kind) || _isReferenceCardKind(kind)) {
      return pw.Text(
        _itemTextSummary(
          item,
          kind: kind,
          options: options,
          taskSummaries: taskSummaries,
          quizSummaries: quizSummaries,
        ),
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
      'Unsupported content (kind $kind; marked placeholder)',
      style: const pw.TextStyle(fontSize: 9),
    );
  }

  static String _pdfCellPreview(String value) =>
      value.length <= 32 ? value : '${value.substring(0, 31)}…';

  Future<Uint8List> _buildTypedPdf({
    required String title,
    required NoteDocument document,
    required PdfExportOptions options,
    required Map<String, Uint8List> reportImages,
    required Map<String, Uint8List> attachments,
    required Map<String, TaskSummary> taskSummaries,
    Map<String, QuizSummary> quizSummaries = const {},
    required List<PdfCompanionFile> companions,
    Map<String, List<List<String>>> csvTables = const {},
    Map<String, Uint8List> pdfPreviews = const {},
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
    final blocks = ((document.toJson()['blocks'] as List?) ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final typedItems = _typedItems(document);
    var segmentStart = 0;
    var firstOutput = true;

    void addFlowSegment(int end) {
      if (end <= segmentStart) return;
      final from = segmentStart;
      doc.addPage(
        pw.MultiPage(
          pageFormat: format,
          margin: const pw.EdgeInsets.all(marginPt),
          build: (_) => [
            if (firstOutput)
              pw.Header(
                level: 0,
                child: pw.Text(
                  title,
                  style: pw.TextStyle(
                    fontSize: 18,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
            for (var i = from; i < end; i++)
              ..._buildTypedBlock(
                blocks,
                i,
                options: options,
                reportImages: reportImages,
                attachments: attachments,
                taskSummaries: taskSummaries,
                quizSummaries: quizSummaries,
                csvTables: csvTables,
                pdfPreviews: pdfPreviews,
                typedItems: typedItems,
              ),
          ],
        ),
      );
      firstOutput = false;
      segmentStart = end;
    }

    for (var index = 0; index < blocks.length; index++) {
      final block = blocks[index];
      if (!_typedHandwritingNeedsCompanion(block, printableH)) continue;
      addFlowSegment(index);
      final id = '${block['id'] ?? 'typed-handwriting-$index'}';
      final titleHeight = firstOutput && title.isNotEmpty
          ? _titleReservePt(title).clamp(28.0, printableH / 2).toDouble()
          : 0.0;
      final previewHeight = math.max(1.0, printableH - titleHeight);
      final preview = _buildOversizedPage(
        block,
        options: options,
        attachments: attachments,
        companions: companions,
        printableW: printableW,
        printableH: previewHeight,
        companionName: 'companion-typed-$id.json',
        contentPreview: _typedHandwritingWidget(
          block,
          typedItems,
          maxWidth: printableW - 48,
          maxHeight: previewHeight - 92,
        ),
      );
      doc.addPage(
        pw.Page(
          pageFormat: format,
          margin: const pw.EdgeInsets.all(marginPt),
          build: (_) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              if (titleHeight > 0)
                pw.SizedBox(
                  height: titleHeight,
                  child: pw.Header(
                    level: 0,
                    child: pw.Text(
                      title,
                      style: pw.TextStyle(
                        fontSize: 18,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              pw.SizedBox(height: previewHeight, child: preview),
            ],
          ),
        ),
      );
      firstOutput = false;
      segmentStart = index + 1;
    }
    addFlowSegment(blocks.length);
    if (firstOutput && title.isNotEmpty) {
      doc.addPage(
        pw.Page(
          pageFormat: format,
          margin: const pw.EdgeInsets.all(marginPt),
          build: (_) => pw.Header(
            level: 0,
            child: pw.Text(
              title,
              style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold),
            ),
          ),
        ),
      );
    }
    return doc.save();
  }

  static bool _typedHandwritingNeedsCompanion(
    Map<String, dynamic> block,
    double printableHeight,
  ) {
    if ('${block['kind'] ?? block['type'] ?? ''}' != 'handwriting') {
      return false;
    }
    final sourceWidth = (block['width'] as num?)?.toDouble() ?? 0;
    final sourceHeight = (block['height'] as num?)?.toDouble() ?? 0;
    if (!sourceWidth.isFinite ||
        !sourceHeight.isFinite ||
        sourceWidth <= 0 ||
        sourceHeight <= 0) {
      return false;
    }
    const renderWidth = 400.0;
    final renderedHeight = sourceHeight * renderWidth / sourceWidth;
    return renderedHeight > printableHeight - 48.0;
  }

  List<pw.Widget> _buildTypedBlock(
    List<Map<String, dynamic>> blocks,
    int index, {
    required PdfExportOptions options,
    required Map<String, Uint8List> reportImages,
    required Map<String, Uint8List> attachments,
    required Map<String, TaskSummary> taskSummaries,
    Map<String, QuizSummary> quizSummaries = const {},
    Map<String, List<List<String>>> csvTables = const {},
    Map<String, Uint8List> pdfPreviews = const {},
    required Map<String, DocumentItem> typedItems,
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
    if (kind == 'reports_embed' ||
        kind == 'website_card' ||
        kind == 'youtube_card' ||
        kind == 'csv_table' ||
        kind == 'pdf_preview') {
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
              attachments: attachments,
              taskSummaries: taskSummaries,
              quizSummaries: quizSummaries,
              csvTables: csvTables,
              pdfPreviews: pdfPreviews,
            ),
          ),
        ),
      ];
    }
    if (_isSummaryKind(kind) || _isReferenceCardKind(kind)) {
      return [
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 3),
          child: _renderItemBody(
            b,
            kind: kind,
            options: options,
            width: 400,
            height: 40,
            reportImages: reportImages,
            attachments: attachments,
            taskSummaries: taskSummaries,
            quizSummaries: quizSummaries,
            csvTables: csvTables,
            pdfPreviews: pdfPreviews,
          ),
        ),
      ];
    }
    if (kind == 'list') {
      final items = (b['items'] as List?) ?? const [];
      return [
        for (var itemIndex = 0; itemIndex < items.length; itemIndex++)
          if (items[itemIndex] is Map)
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 2),
              child: pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.SizedBox(
                    width: 24,
                    child: pw.Text(
                      b['ordered'] == true ? '${itemIndex + 1}.' : '•',
                      style: const pw.TextStyle(fontSize: 11),
                    ),
                  ),
                  pw.Expanded(
                    child: _typedRichText(
                      ((items[itemIndex] as Map)['spans'] as List?) ?? const [],
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
      ];
    }
    if (kind == 'table') {
      final rows = (b['rows'] as List?) ?? const [];
      return [
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 4),
          child: pw.Table(
            border: pw.TableBorder.all(color: PdfColors.grey500, width: 0.5),
            defaultVerticalAlignment: pw.TableCellVerticalAlignment.middle,
            children: [
              for (var rowIndex = 0; rowIndex < rows.length; rowIndex++)
                if (rows[rowIndex] is Map)
                  pw.TableRow(
                    decoration: b['header'] == true && rowIndex == 0
                        ? const pw.BoxDecoration(color: PdfColors.grey200)
                        : null,
                    children: [
                      for (final cell
                          in ((rows[rowIndex] as Map)['cells'] as List? ??
                              const []))
                        pw.Padding(
                          padding: const pw.EdgeInsets.all(4),
                          child: _typedRichText(
                            cell is Map
                                ? (cell['spans'] as List? ?? const [])
                                : const [],
                            fontSize: 11,
                            bold: b['header'] == true && rowIndex == 0,
                          ),
                        ),
                    ],
                  ),
            ],
          ),
        ),
      ];
    }
    if (kind == 'figure') {
      final caption = (b['caption'] as List?) ?? const [];
      final image = attachments['${b['file_id'] ?? ''}'];
      final captionWidget = caption.isEmpty
          ? null
          : pw.RichText(
              text: pw.TextSpan(
                style: const pw.TextStyle(fontSize: 11),
                children: [
                  pw.TextSpan(
                    text: 'Figure: ',
                    style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                  ),
                  ..._typedTextSpans(caption, fontSize: 11),
                ],
              ),
            );
      if (caption.isEmpty && image == null) {
        return [
          pw.Text(
            'Figure image unavailable (marked placeholder)',
            style: pw.TextStyle(fontSize: 9),
          ),
        ];
      }
      return [
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 4),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              if (image != null)
                pw.SizedBox(
                  width: 400,
                  height: 300,
                  child: pw.Image(
                    pw.MemoryImage(image),
                    fit: pw.BoxFit.contain,
                  ),
                )
              else
                pw.Text(
                  'Figure image unavailable (marked placeholder)',
                  style: pw.TextStyle(fontSize: 9),
                ),
              ?captionWidget,
            ],
          ),
        ),
      ];
    }
    if (kind == 'image') {
      final image = attachments['${b['file_id'] ?? ''}'];
      return [
        if (image != null)
          pw.SizedBox(
            width: 400,
            height: 300,
            child: pw.Image(pw.MemoryImage(image), fit: pw.BoxFit.contain),
          )
        else
          pw.Text(
            'Image unavailable (marked placeholder)',
            style: pw.TextStyle(fontSize: 9),
          ),
      ];
    }
    if (kind == 'handwriting') {
      return [_typedHandwritingWidget(b, typedItems)];
    }
    if (kind == 'task_card' || kind == 'quiz_card') {
      return [
        pw.Text(
          _itemTextSummary(
            b,
            kind: kind,
            options: options,
            taskSummaries: taskSummaries,
            quizSummaries: quizSummaries,
          ),
          style: const pw.TextStyle(fontSize: 9),
        ),
      ];
    }
    if (!_typedKinds.contains(kind)) {
      return [
        pw.Text(
          'Unsupported content (kind $kind; marked placeholder)',
          style: const pw.TextStyle(fontSize: 9),
        ),
      ];
    }
    return [pw.Paragraph(text: text, style: const pw.TextStyle(fontSize: 11))];
  }

  pw.Widget _typedHandwritingWidget(
    Map<String, dynamic> json,
    Map<String, DocumentItem> typedItems, {
    double maxWidth = 400,
    double maxHeight = double.infinity,
  }) {
    final item = typedItems['${json['id'] ?? ''}'];
    if (item is! HandwritingBlock) {
      return pw.Text(
        'Handwriting unavailable (marked placeholder)',
        style: pw.TextStyle(fontSize: 9),
      );
    }
    final width = math.min(400.0, maxWidth);
    final scale = width / math.max(1.0, item.width.toDouble());
    final sourceHeight = math.max(1.0, item.height.toDouble());
    final height = math.max(1.0, math.min(sourceHeight * scale, maxHeight));
    final previewScale = math.min(scale, height / sourceHeight);
    final fills = <({List<List<InkVec>> pieces, int argb})>[
      for (final ink in item.ink) ...inkFills(ink),
    ];
    final hasUnsupportedInk =
        fills.isEmpty || item.ink.any((ink) => inkFills(ink).isEmpty);
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        if (fills.isNotEmpty)
          pw.SizedBox(
            width: width,
            height: height,
            child: pw.CustomPaint(
              painter: (canvas, size) {
                for (final fill in fills) {
                  canvas
                    ..saveContext()
                    ..setGraphicState(
                      PdfGraphicState(
                        fillOpacity: ((fill.argb >> 24) & 0xFF) / 255,
                      ),
                    )
                    ..setFillColor(PdfColor.fromInt(fill.argb | 0xFF000000));
                  for (final piece in fill.pieces) {
                    if (piece.length < 3) continue;
                    canvas.moveTo(
                      piece.first.x * previewScale,
                      size.y - piece.first.y * previewScale,
                    );
                    for (final point in piece.skip(1)) {
                      canvas.lineTo(
                        point.x * previewScale,
                        size.y - point.y * previewScale,
                      );
                    }
                    canvas.closePath();
                  }
                  canvas
                    ..fillPath()
                    ..restoreContext();
                }
              },
            ),
          ),
        if (hasUnsupportedInk)
          pw.Text(
            'Some handwriting is unavailable (marked placeholder)',
            style: pw.TextStyle(fontSize: 9),
          ),
      ],
    );
  }

  pw.Widget _typedRichText(
    List spans, {
    required double fontSize,
    bool bold = false,
  }) => pw.RichText(
    text: pw.TextSpan(
      style: pw.TextStyle(fontSize: fontSize),
      children: _typedTextSpans(spans, fontSize: fontSize, bold: bold),
    ),
  );

  List<pw.InlineSpan> _typedTextSpans(
    List spans, {
    required double fontSize,
    bool bold = false,
  }) => [
    for (final span in spans)
      if (span is Map && '${span['text'] ?? ''}'.isNotEmpty)
        pw.TextSpan(
          text: '${span['text']}',
          style: pw.TextStyle(
            fontSize: (span['size'] as num?)?.toDouble() ?? fontSize,
            fontWeight: bold || span['bold'] == true
                ? pw.FontWeight.bold
                : null,
            fontStyle: span['italic'] == true ? pw.FontStyle.italic : null,
            decoration: span['strikethrough'] == true
                ? pw.TextDecoration.lineThrough
                : null,
            color: span['color'] is String
                ? PdfColor.fromInt(colorArgb(span['color'] as String, 1))
                : null,
          ),
        ),
  ];
}
