import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';

import '../../../domain/models/local_note.dart';
import '../../../domain/models/note_document.dart';
import '../../../domain/models/reports_embed_data.dart';
import '../../../domain/services/local_note_store.dart';
import '../../../domain/services/pdf_export_mapper.dart';
import '../../../domain/services/quiz_card_service.dart';
import '../../../domain/services/task_card_service.dart';

/// Draws every page of a PDF for the print preview; throws on failure.
typedef PdfPagesRenderer =
    Future<List<ui.Image>> Function(Uint8List bytes, int maxPixels);

typedef ReportsEmbedLoader =
    Future<ReportsEmbedData> Function(Map<String, dynamic> item);
typedef ReportsChartRenderer =
    Future<Uint8List> Function(ReportsEmbedData data, {required bool partial});
typedef TaskSummaryLoader = Future<TaskSummary?> Function(String taskId);
typedef QuizSummaryLoader = Future<QuizSummary?> Function(String quizId);

/// Rendered preview pages grouped by their exported PDF filename.
final class ExportPreviewPdf {
  const ExportPreviewPdf({required this.filename, required this.pages});

  final String filename;
  final List<ui.Image> pages;
}

/// Where the export flow stands.
enum ExportStage { idle, working, preflight, ready, saved, failed }

const _typedSuffix = '__typed';

/// Returns the paired note id used by the existing local typed-copy creation
/// contract without triggering transcription. A custom typed id has no
/// persisted source link, so it cannot be discovered here.
String pairedRepresentationId(String noteId, {required bool noteIsTyped}) {
  if (!noteIsTyped) return '$noteId$_typedSuffix';
  if (!noteId.endsWith(_typedSuffix)) return '';
  return noteId.substring(0, noteId.length - _typedSuffix.length);
}

/// The export of one local note (annotations#42, B13 points 1, 2, 5, 6, 9):
/// choose Original, Typed, or Both when both reviewed representations exist;
/// choose paper and orientation; preflight; a preview drawn from the generated
/// PDF pages; then save the PDF or a ZIP containing multiple PDFs and/or
/// companion files. Export never changes the saved note or starts
/// transcription.
class ExportHandler extends ChangeNotifier {
  ExportHandler({
    required this.note,
    required this.store,
    LocalNote? pairedNote,
    PdfExportMapper? mapper,
    PdfPagesRenderer? renderPages,
    Future<String?> Function(String name)? saveLocation,
    this.audience = PdfAudience.personal,
    this.loadReportsEmbed,
    this.renderReportsChart,
    this.loadTaskSummary,
    this.loadQuizSummary,
    this.untitledTitle = 'Untitled note',
  }) : _mapper = mapper ?? PdfExportMapper(),
       _render = renderPages ?? renderPdfPages,
       _saveLocation = saveLocation ?? _pickSave {
    if (_isPairedRepresentation(pairedNote)) {
      _pairedNote = pairedNote;
      _pairedLoaded = true;
    }
  }

  final LocalNote note;
  final LocalNoteStore store;

  /// The printed title of a note that has none, in the interface language.
  final String untitledTitle;
  final PdfAudience audience;
  final ReportsEmbedLoader? loadReportsEmbed;
  final ReportsChartRenderer? renderReportsChart;
  final TaskSummaryLoader? loadTaskSummary;
  final QuizSummaryLoader? loadQuizSummary;
  final PdfExportMapper _mapper;
  final PdfPagesRenderer _render;
  final Future<String?> Function(String name) _saveLocation;

  static Future<String?> _pickSave(String name) async =>
      (await fs.getSaveLocation(suggestedName: name))?.path;

  LocalNote? _pairedNote;
  bool _pairedLoaded = false;
  Future<void>? _pairedLoad;

  bool _isPairedRepresentation(LocalNote? candidate) {
    if (candidate == null) return false;
    final pairFamily = switch (note.schema.family) {
      DocumentFamily.original => DocumentFamily.typed,
      DocumentFamily.typed => DocumentFamily.original,
      _ => null,
    };
    if (candidate.schema.family != pairFamily ||
        candidate.id != pairedRepresentationId(note.id, noteIsTyped: typed)) {
      return false;
    }
    // A custom typed ID is not discoverable because the local model stores no
    // separate source link. For the default ID, the transcription service's
    // exact suffix is the source association; known identity conflicts still
    // make the pair unsafe.
    if (note.accountId != null &&
        candidate.accountId != null &&
        note.accountId != candidate.accountId) {
      return false;
    }
    if (note.serverNoteId != null &&
        candidate.serverNoteId != null &&
        note.serverNoteId != candidate.serverNoteId) {
      return false;
    }
    return true;
  }

  bool get typed => note.schema.family == DocumentFamily.typed;

  LocalNote? get originalNote => typed ? _pairedNote : note;
  LocalNote? get typedNote => typed ? note : _pairedNote;

  /// Available export modes based on saved representations (never auto-transcribes).
  List<PdfExportMode> get modes {
    if (originalNote != null && typedNote != null) {
      return const [
        PdfExportMode.original,
        PdfExportMode.typed,
        PdfExportMode.both,
      ];
    }
    return typed ? const [PdfExportMode.typed] : const [PdfExportMode.original];
  }

  late PdfExportMode mode = modes.first;
  PdfPaperSize paper = PdfPaperSize.a4;
  PdfOrientation orientation = PdfOrientation.portrait;

  ExportStage stage = ExportStage.idle;
  bool saveError = false;
  PdfPreflightResult? preflight;
  PdfExportOutput? output;
  List<ExportPreviewPdf> previewPdfs = const [];
  List<ui.Image> get pages => [for (final g in previewPdfs) ...g.pages];

  int _buildSeq = 0;
  bool _disposed = false;
  bool _placeholders = false;
  static pw.Font? _bundledLatin;
  static pw.Font? _bundledThai;
  static Future<void>? _fontLoad;

  Future<void> choose({
    PdfExportMode? mode,
    PdfPaperSize? paper,
    PdfOrientation? orientation,
  }) {
    if (mode != null && modes.contains(mode)) {
      this.mode = mode;
    }
    this.paper = paper ?? this.paper;
    this.orientation = orientation ?? this.orientation;
    saveError = false;
    return build();
  }

  /// What a person knows the item of [issue] by: a missing file shows its
  /// file name; other items keep their reference.
  String issueTarget(PdfPreflightIssue issue) {
    if (issue.kind != 'missing_file') return issue.refId;
    String? find(Object? node) {
      if (node is Map) {
        if (node['file_id'] == issue.refId && node['name'] is String) {
          return node['name'] as String;
        }
        for (final v in node.values) {
          if (find(v) case final String name) return name;
        }
      } else if (node is List) {
        for (final v in node) {
          if (find(v) case final String name) return name;
        }
      }
      return null;
    }

    return find(note.document.toJson()) ??
        find(_pairedNote?.document.toJson()) ??
        issue.refId;
  }

  String get _slug {
    final base = (note.title ?? 'note').trim().toLowerCase();
    final slug = base.replaceAll(RegExp(r'[^a-z0-9\u0E00-\u0E7F]+'), '-');
    final trimmed = slug.replaceAll(RegExp(r'^-+|-+$'), '');
    return trimmed.isEmpty ? 'note' : trimmed;
  }

  Future<void> _ensurePairedLoaded() {
    if (_pairedLoaded) return Future<void>.value();
    return _pairedLoad ??= _loadPairedNote();
  }

  Future<void> _loadPairedNote() async {
    try {
      final candidateId = pairedRepresentationId(note.id, noteIsTyped: typed);
      if (candidateId.isEmpty || candidateId == note.id) {
        _pairedLoaded = true;
        return;
      }
      final loaded = await store.load(candidateId);
      if (_isPairedRepresentation(loaded)) {
        _pairedNote = loaded;
      }
      _pairedLoaded = true;
    } finally {
      _pairedLoad = null;
    }
  }

  static Future<void> _ensureBundledFonts() =>
      _fontLoad ??= _loadBundledFonts();

  static Future<void> _loadBundledFonts() async {
    Future<pw.Font?> load(String fileName) async {
      for (final path in [
        'packages/annotations_shared/lib/presentation/frontend/assets/fonts/$fileName',
        'lib/presentation/frontend/assets/fonts/$fileName',
      ]) {
        try {
          final data = await rootBundle.load(path);
          return pw.Font.ttf(data);
        } on Object {
          // Asset bundle may be absent in pure unit tests.
        }
      }
      return null;
    }

    _bundledLatin = await load('UbuntuSans-Variable.ttf');
    _bundledThai = await load('IBMPlexSansThai-Regular.ttf');
  }

  static void _disposeImages(List<ui.Image> images) {
    for (final img in images) {
      img.dispose();
    }
  }

  static void _disposePreviewGroups(List<ExportPreviewPdf> groups) {
    for (final g in groups) {
      _disposeImages(g.pages);
    }
  }

  void _replacePreview(List<ExportPreviewPdf> next) {
    final old = previewPdfs;
    previewPdfs = next;
    _disposePreviewGroups(old);
  }

  static String _reportImageKey(Map<String, dynamic> item) => jsonEncode([
    item['report_id'] ?? '',
    item['project_slug'] ?? '',
    item['report_slug'] ?? '',
    item['dataset_id'] ?? '',
    item['mode'] ?? '',
    item['snapshot_id'] ?? '',
  ]);

  static List<Map<String, dynamic>> _reportItems(
    Iterable<NoteDocument?> documents,
  ) {
    final items = <Map<String, dynamic>>[];
    void scan(Object? value) {
      if (value is Map) {
        if (value['kind'] == 'reports_embed') {
          items.add(Map<String, dynamic>.from(value));
        }
        for (final nested in value.values) {
          scan(nested);
        }
      } else if (value is List) {
        for (final nested in value) {
          scan(nested);
        }
      }
    }

    for (final document in documents) {
      if (document != null) scan(document.toJson());
    }
    return items;
  }

  static Set<String> _taskIds(Iterable<NoteDocument?> documents) {
    final ids = <String>{};
    void scan(Object? value) {
      if (value is Map) {
        if (value['kind'] == 'task_card' && value['task_id'] is String) {
          final id = (value['task_id'] as String).trim();
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

  static Set<String> _quizIds(Iterable<NoteDocument?> documents) {
    final ids = <String>{};
    void scan(Object? value) {
      if (value is Map) {
        if (value['kind'] == 'quiz_card' && value['quiz_id'] is String) {
          final id = (value['quiz_id'] as String).trim();
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

  /// Runs the preflight and builds the PDF(s) and their preview.
  /// [placeholders] continues with marked placeholders after a preflight
  /// problem (B13 point 9: never a silent omission); omitting [placeholders]
  /// preserves the most recent user choice on retry or paper/orientation change.
  Future<void> build({bool? placeholders}) async {
    if (_disposed) return;
    if (placeholders != null) _placeholders = placeholders;
    final seq = ++_buildSeq;
    saveError = false;
    stage = ExportStage.working;
    notifyListeners();

    try {
      await _ensurePairedLoaded();
      if (_disposed || seq != _buildSeq) return;
      if (!modes.contains(mode)) mode = modes.first;

      await _ensureBundledFonts();
      if (_disposed || seq != _buildSeq) return;

      final includeOriginal =
          mode != PdfExportMode.typed && originalNote != null;
      final includeTyped = mode != PdfExportMode.original && typedNote != null;
      final ids = <String>{
        if (includeOriginal) ...referencedFiles(originalNote!.document),
        if (includeTyped) ...referencedFiles(typedNote!.document),
      };
      final attachments = <String, Uint8List>{};
      for (final id in ids) {
        final fileBytes = await store.readAttachment(id);
        if (_disposed || seq != _buildSeq) return;
        if (fileBytes != null) attachments[id] = fileBytes;
      }

      final selectedDocuments = <NoteDocument?>[
        if (includeOriginal) originalNote!.document,
        if (includeTyped) typedNote!.document,
      ];
      final taskSummaries = <String, TaskSummary>{};
      final taskLoader = loadTaskSummary;
      if (audience == PdfAudience.personal && taskLoader != null) {
        for (final taskId in _taskIds(selectedDocuments)) {
          try {
            final summary = await taskLoader(taskId);
            if (_disposed || seq != _buildSeq) return;
            if (summary != null &&
                summary.taskId == taskId &&
                summary.title.trim().isNotEmpty) {
              taskSummaries[taskId] = summary;
            }
          } on Object {
            // Missing/offline owner metadata becomes an explicit preflight
            // item. Retry invokes this loader again; the PDF never guesses.
          }
        }
      }
      final quizSummaries = <String, QuizSummary>{};
      final quizLoader = loadQuizSummary;
      if (audience == PdfAudience.personal && quizLoader != null) {
        for (final quizId in _quizIds(selectedDocuments)) {
          try {
            final summary = await quizLoader(quizId);
            if (_disposed || seq != _buildSeq) return;
            if (summary != null && summary.quizId == quizId) {
              quizSummaries[quizId] = summary;
            }
          } on Object {
            // Owner metadata stays an explicit preflight item on failure.
          }
        }
      }
      final reportImages = <String, Uint8List>{};
      final failedChartIds = <String>{};
      final partialChartIds = <String>{};
      if (audience != PdfAudience.public) {
        var reportImageBytes = 0;
        for (final item in _reportItems(selectedDocuments)) {
          final imageKey = _reportImageKey(item);
          try {
            final load = loadReportsEmbed;
            final render = renderReportsChart;
            if (load == null || render == null) {
              failedChartIds.add(imageKey);
              continue;
            }
            final data = await load(item);
            if (_disposed || seq != _buildSeq) return;
            if (!data.canRender) {
              failedChartIds.add(imageKey);
              continue;
            }
            final image = await render(data, partial: !data.complete);
            if (_disposed || seq != _buildSeq) return;
            if (image.lengthInBytes > 4 * 1024 * 1024 ||
                reportImageBytes + image.lengthInBytes > 16 * 1024 * 1024) {
              failedChartIds.add(imageKey);
              continue;
            }
            reportImages[imageKey] = image;
            reportImageBytes += image.lengthInBytes;
            if (!data.complete) partialChartIds.add(imageKey);
          } on Object {
            failedChartIds.add(imageKey);
          }
        }
      }

      final out = await _mapper.export(
        title: note.title ?? originalNote?.title ?? untitledTitle,
        slug: _slug,
        original: originalNote?.document,
        typed: typedNote?.document,
        options: PdfExportOptions(
          mode: mode,
          paperSize: paper,
          orientation: orientation,
          audience: audience,
          continueWithPlaceholders: _placeholders,
        ),
        availableFileIds: attachments.keys.toSet(),
        failedChartIds: failedChartIds,
        partialChartIds: partialChartIds,
        reportImages: reportImages,
        attachments: attachments,
        taskSummaries: taskSummaries,
        quizSummaries: quizSummaries,
        baseFont: _bundledLatin,
        thaiFont: _bundledThai,
      );
      if (_disposed || seq != _buildSeq) return;

      if (out.pdfs.isEmpty) {
        _replacePreview(const []);
        output = out;
        preflight = out.preflight;
        stage = out.preflight.ok ? ExportStage.failed : ExportStage.preflight;
        notifyListeners();
        return;
      }

      final renderedGroups = <ExportPreviewPdf>[];
      try {
        for (final pdf in out.pdfs) {
          final rendered = await _render(pdf.bytes, 900);
          if (_disposed || seq != _buildSeq) {
            _disposeImages(rendered);
            _disposePreviewGroups(renderedGroups);
            return;
          }
          if (rendered.isEmpty) {
            _disposeImages(rendered);
            throw StateError('No preview pages rendered for ${pdf.filename}');
          }
          renderedGroups.add(
            ExportPreviewPdf(filename: pdf.filename, pages: rendered),
          );
        }
      } on Object {
        _disposePreviewGroups(renderedGroups);
        if (_disposed || seq != _buildSeq) return;
        _replacePreview(const []);
        output = out;
        preflight = out.preflight;
        stage = ExportStage.failed;
        notifyListeners();
        return;
      }

      _replacePreview(renderedGroups);
      output = out;
      preflight = out.preflight;
      stage = ExportStage.ready;
      notifyListeners();
    } on Object {
      if (_disposed || seq != _buildSeq) return;
      _replacePreview(const []);
      stage = ExportStage.failed;
      notifyListeners();
    }
  }

  /// True when the export packages more than one PDF or companion files.
  bool get needsZip =>
      (output?.companions.isNotEmpty ?? false) ||
      ((output?.pdfs.length ?? 0) > 1);

  /// The file name of the saved export: a ZIP when there are multiple PDFs
  /// or companion files, else the single PDF's filename.
  String get fileName {
    final out = output;
    if (needsZip) return '$_slug.zip';
    if (out != null && out.pdfs.isNotEmpty) return out.pdfs.first.filename;
    return '$_slug.pdf';
  }

  /// The bytes to save: the single PDF, or the ZIP of every PDF and companion.
  Uint8List bytes() {
    final out = output!;
    if (out.pdfs.isEmpty) {
      throw StateError('No exported PDFs available.');
    }
    if (!needsZip) return out.pdfs.first.bytes;
    final zip = Archive();
    for (final pdf in out.pdfs) {
      zip.addFile(ArchiveFile(pdf.filename, pdf.bytes.length, pdf.bytes));
    }
    for (final file in out.companions) {
      zip.addFile(ArchiveFile(file.filename, file.bytes.length, file.bytes));
    }
    return Uint8List.fromList(ZipEncoder().encode(zip));
  }

  /// Saves the export where the user chooses. False on cancel or write failure.
  Future<bool> save() async {
    if (_disposed || stage != ExportStage.ready) return false;
    saveError = false;
    try {
      final path = await _saveLocation(fileName);
      if (_disposed || path == null) return false;
      await File(path).writeAsBytes(bytes(), flush: true);
    } on Object {
      if (_disposed) return false;
      saveError = true;
      notifyListeners();
      return false;
    }
    if (_disposed) return false;
    stage = ExportStage.saved;
    notifyListeners();
    return true;
  }

  @override
  void dispose() {
    _disposed = true;
    _buildSeq++;
    _replacePreview(const []);
    super.dispose();
  }
}

/// Every page of [bytes] drawn with its longest side at most [maxPixels].
/// Fails instead of returning empty or omitting pages so the preview matches
/// the PDF one-to-one.
Future<List<ui.Image>> renderPdfPages(Uint8List bytes, int maxPixels) async {
  PdfDocument? document;
  final images = <ui.Image>[];
  try {
    await pdfrxFlutterInitialize();
    document = await PdfDocument.openData(bytes);
    if (document.pages.isEmpty) {
      throw StateError('PDF document has no pages.');
    }
    for (final page in document.pages) {
      final scale =
          maxPixels / (page.width > page.height ? page.width : page.height);
      final width = (page.width * scale).round().clamp(1, maxPixels);
      final height = (page.height * scale).round().clamp(1, maxPixels);
      final image = await page.render(
        width: width,
        height: height,
        fullWidth: width.toDouble(),
        fullHeight: height.toDouble(),
        backgroundColor: 0xFFFFFFFF,
      );
      if (image == null) {
        throw StateError('PDF page render returned null.');
      }
      try {
        images.add(await image.createImage());
      } finally {
        image.dispose();
      }
    }
    return images;
  } on Object {
    for (final img in images) {
      img.dispose();
    }
    rethrow;
  } finally {
    await document?.dispose();
  }
}
