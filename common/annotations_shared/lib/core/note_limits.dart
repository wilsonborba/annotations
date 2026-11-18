/// Content limits of a note document. The values match the backend defaults, so
/// the app rejects the same documents as the server. They are content limits,
/// not viewport dimensions: rotation and zoom never change stored coordinates.
final class NoteLimits {
  const NoteLimits({
    this.maxItems = 50000,
    this.maxSamplesPerStroke = 10000,
    this.maxNodesPerStroke = 1000,
    this.maxDocumentBytes = 64 * 1024 * 1024,
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

/// The invisible placement grid of the editor (B2.1). Structured blocks
/// (text, images, cards, tables, Reports and similar) sit on whole cells;
/// ink and shape points never snap. The server checks the same cell size.
abstract final class EditorGrid {
  /// One cell in logical page units.
  static const int cell = 8;

  /// Structured kinds whose height the user sets (B3.1: the CSV table area and
  /// the Reports display area). Their height is on whole cells too; the other
  /// kinds take a measured or proportional height.
  static const areaKinds = ['csv_table', 'reports_embed'];

  /// Whether [v] is a whole number of cells.
  static bool isOn(num v) => v % cell == 0;

  /// The grid line at or before [v]: the cell that contains a click.
  static int floor(num v) => (v / cell).floor() * cell;

  /// The nearest grid line, for drags and resizes.
  static int round(num v) => (v / cell).round() * cell;

  /// The grid line at or after [v].
  static int ceil(num v) => (v / cell).ceil() * cell;
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
