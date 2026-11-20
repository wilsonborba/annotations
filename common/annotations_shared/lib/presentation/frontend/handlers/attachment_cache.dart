/// The stored files that cards show (annotations#34): file details, decoded
/// pictures, CSV rows, and the page shape and first page of a PDF, read from
/// the local store when a card first asks. A finished read notifies, and the content
/// layer draws again. Nothing here leaves the device.
library;

import 'dart:async';
import 'dart:ui' as ui;
import 'dart:ui' show Offset, Size;

import 'package:flutter/foundation.dart';

import '../../../domain/models/local_note.dart';
import '../../../domain/services/card_content.dart';
import '../../../domain/services/local_note_store.dart';
import 'pdf_page_renderer.dart';

class AttachmentCache extends ChangeNotifier {
  AttachmentCache(this.store, {PdfPageRenderer? renderPdfPage})
    : renderPdfPage = renderPdfPage ?? defaultPdfPageRenderer;

  /// The renderer a new cache uses when none is given. Widget tests that
  /// only place PDF cards set a renderer without PDFium here.
  @visibleForTesting
  static PdfPageRenderer defaultPdfPageRenderer = renderFirstPdfPage;

  final LocalNoteStore? store;

  /// Draws the first page of a PDF into a picture (pdfrx by default).
  final PdfPageRenderer renderPdfPage;

  final _info = <String, LocalAttachment?>{};
  final _images = <String, ui.Image?>{};
  final _csv = <String, List<List<String>>?>{};
  final _pdf = <String, ({double width, double height, int pages})?>{};
  final _loading = <String>{};
  bool _disposed = false;

  /// Grows with each finished read or table scroll: drawings made with an
  /// older version are made again.
  int get version => _version;
  int _version = 0;

  final _scroll = <String, Offset>{};

  /// The scroll offset of the CSV table [itemId] (page units).
  Offset tableScroll(String itemId) => _scroll[itemId] ?? Offset.zero;

  /// Scrolls the CSV table [itemId] of [fileId] in a box of [size] by
  /// [delta]. Returns false when it is already at that end.
  bool scrollTable(String itemId, String fileId, Size size, Offset delta) {
    final rows = csv(fileId);
    if (rows == null) return false;
    const cell = Size(120, 28);
    final columns = rows.fold<int>(0, (n, r) => r.length > n ? r.length : n);
    final max = Offset(
      (columns * cell.width - size.width).clamp(0, double.infinity),
      (rows.length * cell.height - size.height).clamp(0, double.infinity),
    );
    final now = tableScroll(itemId);
    final next = Offset(
      (now.dx + delta.dx).clamp(0, max.dx),
      (now.dy + delta.dy).clamp(0, max.dy),
    );
    if (next == now) return false;
    _scroll[itemId] = next;
    _version++;
    notifyListeners();
    return true;
  }

  /// File name, type and size of [fileId], or null until read.
  LocalAttachment? info(String fileId) {
    if (!_info.containsKey(fileId)) _load(fileId);
    return _info[fileId];
  }

  /// The decoded picture of [fileId], or null until read (or not a picture).
  /// For a PDF this is its first page.
  ui.Image? image(String fileId) {
    if (!_images.containsKey(fileId)) _load(fileId);
    return _images[fileId];
  }

  /// The rows of the CSV file [fileId], or null until read.
  List<List<String>>? csv(String fileId) {
    if (!_csv.containsKey(fileId)) _load(fileId);
    return _csv[fileId];
  }

  /// The first page size and page count of the PDF [fileId], or null.
  ({double width, double height, int pages})? pdf(String fileId) {
    if (!_pdf.containsKey(fileId)) _load(fileId);
    return _pdf[fileId];
  }

  /// Keeps what an import already knows, so a new card measures at once.
  void remember(LocalAttachment attachment) {
    _info[attachment.id] = attachment;
  }

  void _load(String fileId) {
    final store = this.store;
    if (store == null || !_loading.add(fileId)) return;
    unawaited(() async {
      try {
        final info = await store.attachment(fileId);
        _info[fileId] = info;
        final bytes = info == null ? null : await store.readAttachment(fileId);
        if (bytes != null && info != null) {
          final kind = cardKindFor(info.type);
          if (kind == 'csv_table') {
            _csv[fileId] = parseCsvBytes(bytes);
          } else if (kind == 'pdf_preview') {
            _pdf[fileId] = pdfInfo(bytes);
            final page = await renderPdfPage(bytes, pdfPagePixels);
            if (_disposed) {
              page?.dispose();
              return;
            }
            if (page != null) _images[fileId] = page;
          } else if (info.type.startsWith('image/')) {
            final codec = await ui.instantiateImageCodec(bytes);
            final frame = await codec.getNextFrame();
            codec.dispose();
            if (_disposed) {
              frame.image.dispose();
              return;
            }
            _images[fileId] = frame.image;
          }
        }
      } on Object {
        // A file that cannot be read shows as a plain card.
      }
      _images.putIfAbsent(fileId, () => null);
      _csv.putIfAbsent(fileId, () => null);
      _pdf.putIfAbsent(fileId, () => null);
      _info.putIfAbsent(fileId, () => null);
      _version++;
      if (!_disposed) notifyListeners();
    }());
  }

  @override
  void dispose() {
    _disposed = true;
    for (final image in _images.values) {
      image?.dispose();
    }
    super.dispose();
  }
}
