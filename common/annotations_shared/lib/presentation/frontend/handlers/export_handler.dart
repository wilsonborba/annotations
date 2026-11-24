import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter/foundation.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../../domain/models/local_note.dart';
import '../../../domain/models/note_document.dart';
import '../../../domain/services/local_note_store.dart';
import '../../../domain/services/pdf_export_mapper.dart';

/// Draws every page of a PDF for the print preview, or returns no pages.
typedef PdfPagesRenderer =
    Future<List<ui.Image>> Function(Uint8List bytes, int maxPixels);

/// Where the export flow stands.
enum ExportStage { idle, working, preflight, ready, saved, failed }

/// The export of one local note (annotations#42, B13 points 1, 2, 5, 6, 9):
/// choose the view, paper and orientation; preflight; a preview drawn from
/// the generated PDF itself, so the preview pages are the PDF pages; then
/// save the PDF, or a ZIP with the PDF and its companion files. Export
/// never changes the saved note.
class ExportHandler extends ChangeNotifier {
  ExportHandler({
    required this.note,
    required this.store,
    PdfExportMapper? mapper,
    PdfPagesRenderer? renderPages,
    Future<String?> Function(String name)? saveLocation,
  }) : _mapper = mapper ?? PdfExportMapper(),
       _render = renderPages ?? renderPdfPages,
       _saveLocation = saveLocation ?? _pickSave;

  final LocalNote note;
  final LocalNoteStore store;
  final PdfExportMapper _mapper;
  final PdfPagesRenderer _render;
  final Future<String?> Function(String name) _saveLocation;

  static Future<String?> _pickSave(String name) async =>
      (await fs.getSaveLocation(suggestedName: name))?.path;

  bool get typed => note.schema.family == DocumentFamily.typed;

  /// The views this note has: one local note holds one representation.
  List<PdfExportMode> get modes =>
      typed ? const [PdfExportMode.typed] : const [PdfExportMode.original];

  late PdfExportMode mode = modes.first;
  PdfPaperSize paper = PdfPaperSize.a4;
  PdfOrientation orientation = PdfOrientation.portrait;

  ExportStage stage = ExportStage.idle;
  PdfPreflightResult? preflight;
  PdfExportOutput? output;
  List<ui.Image> pages = const [];

  void choose({PdfPaperSize? paper, PdfOrientation? orientation}) {
    this.paper = paper ?? this.paper;
    this.orientation = orientation ?? this.orientation;
    build();
  }

  String get _slug {
    final base = (note.title ?? 'note').trim().toLowerCase();
    final slug = base.replaceAll(RegExp(r'[^a-z0-9฀-๿]+'), '-');
    return slug.replaceAll(RegExp(r'^-+|-+$'), '').isEmpty
        ? 'note'
        : slug.replaceAll(RegExp(r'^-+|-+$'), '');
  }

  /// Runs the preflight and builds the PDF and its preview.
  /// [placeholders] continues with marked placeholders after a preflight
  /// problem (B13 point 9: never a silent omission).
  Future<void> build({bool placeholders = false}) async {
    stage = ExportStage.working;
    notifyListeners();
    try {
      final ids = referencedFiles(note.document);
      final attachments = <String, Uint8List>{};
      for (final id in ids) {
        final bytes = await store.readAttachment(id);
        if (bytes != null) attachments[id] = bytes;
      }
      final out = await _mapper.export(
        title: note.title ?? 'Untitled note',
        slug: _slug,
        original: typed ? null : note.document,
        typed: typed ? note.document : null,
        options: PdfExportOptions(
          mode: mode,
          paperSize: paper,
          orientation: orientation,
          continueWithPlaceholders: placeholders,
        ),
        availableFileIds: attachments.keys.toSet(),
        attachments: attachments,
      );
      output = out;
      preflight = out.preflight;
      if (out.pdfs.isEmpty) {
        pages = const [];
        stage = ExportStage.preflight;
      } else {
        pages = await _render(out.pdfs.first.bytes, 900);
        stage = ExportStage.ready;
      }
    } catch (_) {
      stage = ExportStage.failed;
    }
    notifyListeners();
  }

  /// The file name of the saved export: a ZIP when there are companion
  /// files, else the PDF.
  String get fileName => (output?.companions.isNotEmpty ?? false)
      ? '$_slug.zip'
      : output?.pdfs.first.filename ?? '$_slug.pdf';

  /// The bytes to save: the PDF, or the ZIP of every PDF and companion.
  Uint8List bytes() {
    final out = output!;
    if (out.companions.isEmpty) return out.pdfs.first.bytes;
    final zip = Archive();
    for (final pdf in out.pdfs) {
      zip.addFile(ArchiveFile(pdf.filename, pdf.bytes.length, pdf.bytes));
    }
    for (final file in out.companions) {
      zip.addFile(ArchiveFile(file.filename, file.bytes.length, file.bytes));
    }
    return Uint8List.fromList(ZipEncoder().encode(zip));
  }

  /// Saves the export where the user chooses. False when cancelled.
  Future<bool> save() async {
    final path = await _saveLocation(fileName);
    if (path == null) return false;
    await File(path).writeAsBytes(bytes(), flush: true);
    stage = ExportStage.saved;
    notifyListeners();
    return true;
  }

  @override
  void dispose() {
    for (final page in pages) {
      page.dispose();
    }
    super.dispose();
  }
}

/// Every page of [bytes] drawn with its longest side at most [maxPixels].
Future<List<ui.Image>> renderPdfPages(Uint8List bytes, int maxPixels) async {
  PdfDocument? document;
  final images = <ui.Image>[];
  try {
    await pdfrxFlutterInitialize();
    document = await PdfDocument.openData(bytes);
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
      if (image == null) continue;
      try {
        images.add(await image.createImage());
      } finally {
        image.dispose();
      }
    }
  } on Object {
    // The preview stays empty; saving still works.
  } finally {
    await document?.dispose();
  }
  return images;
}
