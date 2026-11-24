import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:reports_view/reports_view.dart';

import '../../../domain/models/reports_embed_data.dart';

const _printPalette = ReportPalette(
  canvas: Color(0xFFFFFFFF),
  surface: Color(0xFFF4F4F5),
  surfaceAlt: Color(0xFFE9E9EC),
  border: Color(0xFFE4E4E7),
  textPrimary: Color(0xFF1E1E1E),
  textMuted: Color(0xFF52525B),
  accent: Color(0xFF7C3AED),
  onAccent: Color(0xFFFFFFFF),
  positive: Color(0xFF16A34A),
  warning: Color(0xFFCA8A04),
  negative: Color(0xFFDC2626),
  info: Color(0xFF0891B2),
  caution: Color(0xFFEA580C),
  series: [
    Color(0xFFEB6834),
    Color(0xFF0F9FA8),
    Color(0xFF008300),
    Color(0xFFE87BA4),
    Color(0xFFEDA100),
    Color(0xFFE34948),
    Color(0xFF6250D6),
    Color(0xFF1BAF7A),
  ],
  other: Color(0xFFA8A8A8),
  highlight: Color(0xFF16A34A),
);

/// Renders the Reports chart from its already-authorized bounded page.
/// The result is a local PNG used only as a static PDF image.
Future<Uint8List> captureReportsPdfChart(
  BuildContext context,
  ReportsEmbedData data, {
  required String partialLabel,
  String language = 'en',
}) async {
  final page = data.page;
  if (!data.canRender || page == null) {
    throw StateError('Reports data is not available for export.');
  }
  final overlay = Overlay.of(context, rootOverlay: true);
  final routeEntries = ModalRoute.of(context)?.overlayEntries;
  final insertionAnchor = routeEntries == null || routeEntries.isEmpty
      ? null
      : routeEntries.first;
  final key = GlobalKey();
  final partial = !data.complete;
  final entry = OverlayEntry(
    builder: (context) => Positioned(
      left: 0,
      top: 0,
      child: TickerMode(
        enabled: false,
        child: Localizations.override(
          context: context,
          locale: Locale(language.split('-').first),
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: Theme(
              data: _printPalette.toTheme(Brightness.light),
              child: Material(
                color: _printPalette.canvas,
                child: RepaintBoundary(
                  key: key,
                  child: SizedBox(
                    width: 720,
                    height: 520,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (partial)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(
                                '$partialLabel (${page.rows.length} of ${page.totalRows} rows)',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          Expanded(
                            child: ChartFrame(
                              page: page,
                              mode: ChartFrameMode.embed,
                              state: data.state == ReportsEmbedState.offline
                                  ? ChartFrameState.offline
                                  : page.rows.isEmpty
                                  ? ChartFrameState.empty
                                  : ChartFrameState.ready,
                              title:
                                  data.reportView?.title ??
                                  page.descriptor.title,
                              subtitle: data.reportView?.description,
                              snapshotDate: data.capturedAt?.toIso8601String(),
                              fixedHeight: 460,
                              enableTableToggle: false,
                              child: VisualChooser.build(
                                page,
                                Slot(page.descriptor.datasetId),
                                full: true,
                                height: 420,
                                frame: 480,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  if (insertionAnchor == null) {
    overlay.insert(entry);
  } else {
    // Keep the offscreen render surface beneath the export dialog and its
    // modal barrier. It cannot flash chart content on the active screen.
    overlay.insert(entry, below: insertionAnchor);
  }
  try {
    await WidgetsBinding.instance.endOfFrame;
    final boundary = key.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || !boundary.hasSize) {
      throw StateError('Reports chart did not produce a render surface.');
    }
    final image = await boundary.toImage(pixelRatio: 1.25);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null || bytes.lengthInBytes > 4 * 1024 * 1024) {
        throw StateError(
          'Reports chart PNG is empty or exceeds its size limit.',
        );
      }
      return bytes.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  } finally {
    entry.remove();
    entry.dispose();
  }
}
