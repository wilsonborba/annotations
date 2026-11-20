import 'dart:typed_data';

import 'krilla_pdf_stub.dart'
    if (dart.library.ffi) 'krilla_pdf_ffi.dart'
    if (dart.library.js_interop) 'krilla_pdf_web.dart'
    as impl;

/// Platform-agnostic bridge to the Rust `krilla` + `icu_segmenter` PDF renderer.
/// Uses `dart:ffi` on native (Linux, Android, desktop/mobile) and `wasm32` on web.
abstract final class KrillaPdfBackend {
  /// Returns true when the krilla backend is available on the current platform.
  static Future<bool> isAvailable() => impl.krillaIsAvailable();

  /// Renders a `PdfDocumentInput` JSON payload into PDF bytes using krilla.
  /// Returns null when the backend is unavailable.
  static Future<Uint8List?> renderPdf({
    required Uint8List modelJsonBytes,
    required Uint8List regularFontBytes,
    Uint8List? boldFontBytes,
  }) => impl.krillaRenderPdf(
    modelJsonBytes: modelJsonBytes,
    regularFontBytes: regularFontBytes,
    boldFontBytes: boldFontBytes,
  );
}
