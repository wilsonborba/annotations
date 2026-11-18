/// Settings of the drawing tools that the alignment left to implementation
/// (B6.2: "exact size ranges, color values, pressure curve ... remain B10/B11
/// technical work"). The implementer sets them here and records them.
///
/// Widths are logical page units (one unit is one logical pixel at zoom
/// 1.0). Colors are stored #RRGGBBAA values; ink colors never change with the
/// light or dark mode (B4.4).
final class DrawSettings {
  const DrawSettings({
    this.colors = palette,
    this.minWidth = 1,
    this.maxWidth = 40,
    this.maxHighlighterWidth = 60,
    this.minOpacity = 0.1,
    this.roundWidth = 3,
    this.flatWidth = 8,
    this.flatTipAngle = 0.7854,
    this.brushWidth = 6,
    this.highlighterWidth = 20,
    this.highlighterOpacity = 0.4,
    this.penColor = '#000000FF',
    this.highlighterColor = '#FFD600FF',
    this.shapeLineWidth = 3,
    this.minShapeSize = 4,
    this.eraserRadius = 8,
    this.minEraserRadius = 2,
    this.maxEraserRadius = 40,
  });

  /// The eraser circle radius in page units: the first value and the range
  /// of its size control (annotations#30).
  final num eraserRadius, minEraserRadius, maxEraserRadius;

  /// The fixed colors of every drawing tool (B6.2): the string key of the
  /// name and the stored value. The custom picker adds any other color.
  final List<(String, String)> colors;

  /// The one palette of the app: the pens and the text Color tool use the
  /// same values (annotations#27).
  static const palette = [
    ('colorRed', '#FF1744FF'),
    ('colorGreen', '#00C853FF'),
    ('colorBlue', '#3D5AFEFF'),
    ('colorYellow', '#FFD600FF'),
    ('colorBlack', '#000000FF'),
    ('colorGray', '#757575FF'),
    ('colorWhite', '#FFFFFFFF'),
  ];

  /// The range of the width control. The highlighter goes wider.
  final num minWidth, maxWidth, maxHighlighterWidth;

  /// The lowest opacity of the control. A stored opacity is above 0.
  final num minOpacity;

  /// The first settings of each tool, before the user changes them.
  final num roundWidth, flatWidth, brushWidth, highlighterWidth;

  /// The first nib angle of the flat pen in radians (45 degrees).
  final num flatTipAngle;

  /// The first opacity of the highlighter: a broad transparent mark (B6.1).
  final num highlighterOpacity;

  final String penColor, highlighterColor;

  /// The first line width of the shapes.
  final num shapeLineWidth;

  /// A shape drag smaller than this on both sides (page units) adds nothing,
  /// so a click with the shape tool leaves no speck.
  final num minShapeSize;
}
