// annotations#34 send-back: the PDF card shows the first page of the file.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:annotations_shared/presentation/frontend/components/card_layout.dart';
import 'package:annotations_shared/presentation/frontend/components/tokens.dart';
import 'package:annotations_shared/presentation/frontend/handlers/attachment_cache.dart';
import 'package:annotations_shared/presentation/frontend/handlers/pdf_page_renderer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'attachment_fixtures.dart';

Future<List<int>> rgba(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return data!.buffer.asUint8List();
}

List<int> pixel(List<int> bytes, ui.Image image, int x, int y) {
  final i = (y * image.width + x) * 4;
  return bytes.sublist(i, i + 4);
}

void main() {
  late Directory cache;
  setUpAll(() => cache = usePdfiumInTests());
  tearDownAll(() => cache.deleteSync(recursive: true));

  testWidgets('PDFium draws the first page with its content', (tester) async {
    final page = await tester.runAsync(
      () => renderFirstPdfPage(drawablePdfBytes, 200),
    );
    expect(page, isNotNull);
    addTearDown(page!.dispose);
    // A4 shape, longest side at the limit.
    expect(page.height, 200);
    expect(page.width, (200 * 595 / 842).round());
    final bytes = (await tester.runAsync(() => rgba(page)))!;
    // The blue band at the top of the page.
    expect(pixel(bytes, page, page.width ~/ 2, 5), [0, 0, 255, 255]);
    // White paper in the middle and at the bottom.
    expect(pixel(bytes, page, page.width ~/ 2, 190), [255, 255, 255, 255]);
    // The words "Chapter 3": dark pixels on the text line.
    final y = (200 * (842 - 610) / 842).round();
    var dark = 0;
    for (var x = 0; x < page.width; x++) {
      if (pixel(bytes, page, x, y)[0] < 128) dark++;
    }
    expect(dark, greaterThan(5));
  });

  testWidgets('a file that is not a drawable PDF gives no page', (
    tester,
  ) async {
    // The header-only fixture has no catalog, so PDFium cannot open it.
    final page = await tester.runAsync(() => renderFirstPdfPage(pdfBytes, 200));
    expect(page, isNull);
  });

  testWidgets('the card draws the rendered page in its box', (tester) async {
    final store = FileStore()
      ..put(
        drawablePdfBytes,
        name: 'chapter-3.pdf',
        type: 'application/pdf',
        id: 'pdf',
      );
    final files = AttachmentCache(store);
    addTearDown(files.dispose);
    await tester.runAsync(() async {
      files.image('pdf');
      for (var i = 0; i < 100 && files.image('pdf') == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    final page = files.image('pdf');
    expect(page, isNotNull, reason: 'the first page is drawn for the card');
    expect(page!.height, pdfPagePixels);
    expect(files.pdf('pdf')!.pages, 1);

    final layout = CardLayout(
      {'kind': 'pdf_preview', 'file_id': 'pdf'},
      160,
      CardStyle(text: const TextStyle(fontSize: 14), colors: AppColors.dark),
      files,
    );
    addTearDown(layout.dispose);
    final recorder = ui.PictureRecorder();
    final r = Rect.fromLTWH(0, 0, 160, 160 * 842 / 595);
    layout.paint(Canvas(recorder), r);
    final card = (await tester.runAsync(
      () => recorder.endRecording().toImage(160, r.height.ceil()),
    ))!;
    addTearDown(card.dispose);
    final bytes = (await tester.runAsync(() => rgba(card)))!;
    // The page's blue band at the top and white paper below, even in dark
    // mode: the card shows the page, not a placeholder.
    expect(pixel(bytes, card, 80, 6), [0, 0, 255, 255]);
    expect(pixel(bytes, card, 80, 200), [255, 255, 255, 255]);
  });

  testWidgets('without a drawn page the card uses the theme surface', (
    tester,
  ) async {
    final store = FileStore()
      ..put(pdfBytes, name: 'chapter-3.pdf', type: 'application/pdf', id: 'p');
    final files = AttachmentCache(store, renderPdfPage: (_, _) async => null);
    addTearDown(files.dispose);
    files.image('p');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    expect(files.image('p'), isNull);
    expect(files.pdf('p')!.pages, 2);
    final layout = CardLayout(
      {'kind': 'pdf_preview', 'file_id': 'p'},
      160,
      CardStyle(text: const TextStyle(fontSize: 14), colors: AppColors.dark),
      files,
    );
    addTearDown(layout.dispose);
    final recorder = ui.PictureRecorder();
    layout.paint(Canvas(recorder), const Rect.fromLTWH(0, 0, 160, 226));
    final card = (await tester.runAsync(
      () => recorder.endRecording().toImage(160, 226),
    ))!;
    addTearDown(card.dispose);
    final bytes = (await tester.runAsync(() => rgba(card)))!;
    final s = AppColors.dark.surface;
    // No bright white block in dark mode.
    expect(pixel(bytes, card, 10, 200), [
      (s.r * 255).round(),
      (s.g * 255).round(),
      (s.b * 255).round(),
      255,
    ]);
  });
}
