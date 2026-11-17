/// Content limits of a note document. The values match the backend defaults, so
/// the app rejects the same documents as the server. They are content limits,
/// not viewport dimensions: rotation and zoom never change stored coordinates.
final class NoteLimits {
  const NoteLimits({
    this.maxItems = 10000,
    this.maxSamplesPerStroke = 10000,
    this.maxNodesPerStroke = 1000,
    this.maxDocumentBytes = 7500000,
  });

  /// Items in one document, nested ink of typed handwriting blocks included.
  final int maxItems;

  /// Raw input samples in one stroke.
  final int maxSamplesPerStroke;

  /// Editable nodes in one stroke or shape path.
  final int maxNodesPerStroke;

  /// Size of the serialized document body in bytes.
  final int maxDocumentBytes;
}

/// Editor settings that the alignment left to implementation (B3: minimum sizes
/// were not selected). The server does not check them; they only stop an
/// editor gesture from producing an item that is too small to select again.
final class EditorSettings {
  const EditorSettings({this.minResizeExtent = 8});

  /// The smallest width and height, in logical page units, that a resize or a
  /// group scale may produce. A drawing uses the larger side of its rectangle.
  final num minResizeExtent;
}

/// Undo and Redo settings of the Notes editor (B2 G2: 100 steps, confirmed by
/// the owner). Instant has no history, so nothing here applies to it.
final class HistorySettings {
  const HistorySettings({
    this.maxSteps = 100,
    this.textMergeWindow = const Duration(seconds: 1),
  });

  /// Steps kept for Undo. A new step beyond this drops the oldest one.
  final int maxSteps;

  /// The longest pause between two typed inputs that still joins them into one
  /// text step. One second is the delay that common rich text editors use.
  final Duration textMergeWindow;
}
