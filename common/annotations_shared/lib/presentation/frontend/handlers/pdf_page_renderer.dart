/// Draws the first page of a PDF for its card (annotations#34) with pdfrx
/// (MIT, PDFium BSD-3). It works on every platform the app builds for: the
/// PDFium library comes with the build, on the web as WebAssembly.
library;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:pdfrx/pdfrx.dart';

/// Draws the first page of the PDF [bytes] with its longest side at most
/// [maxPixels], or returns null when the file cannot be drawn.
typedef PdfPageRenderer =
    Future<ui.Image?> Function(Uint8List bytes, int maxPixels);

/// The longest side of a drawn first page. A PDF card starts 240 wide and
/// the page is drawn at about twice that, so it stays sharp when zoomed.
const pdfPagePixels = 640;

/// How long a first page may take. When PDFium cannot start (for example a
/// missing library), its worker never answers; the card then keeps the page
/// shape instead of waiting forever.
const pdfPageTimeout = Duration(seconds: 15);

Future<ui.Image?> renderFirstPdfPage(Uint8List bytes, int maxPixels) =>
    _render(bytes, maxPixels).timeout(pdfPageTimeout, onTimeout: () => null);

Future<ui.Image?> _render(Uint8List bytes, int maxPixels) async {
  PdfDocument? document;
  try {
    await pdfrxFlutterInitialize();
    document = await PdfDocument.openData(bytes);
    if (document.pages.isEmpty) return null;
    final page = document.pages.first;
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
    if (image == null) return null;
    try {
      return await image.createImage();
    } finally {
      image.dispose();
    }
  } on Object {
    // A protected or damaged file keeps the page shape card.
    return null;
  } finally {
    await document?.dispose();
  }
}
