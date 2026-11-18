/// Settings of the paper canvas that the alignment left to implementation
/// (B1.1: no numerical size selected; B4.2: no numeric ranges selected;
/// technical decision 13: the implementer sets them here and records them).
///
/// Page lengths are logical page units (one unit is one logical pixel at zoom
/// 1.0). Screen lengths are logical screen pixels and never reach a document.
final class PaperSettings {
  const PaperSettings({
    this.minZoom = 0.25,
    this.maxZoom = 4,
    this.zoomStep = 1.25,
    this.wheelZoomRate = 0.002,
    this.deskMargin = 12,
    this.minPageRatio = 1.4142,
    this.trailingSpace = 800,
    this.ruledSpacing = 32,
    this.gridSpacing = 24,
    this.dotsSpacing = 24,
    this.defaultVisibility = 0.5,
    this.minSpacing = 12,
    this.maxSpacing = 64,
    this.minVisibility = 0.1,
    this.maxGuideAlpha = 0.5,
    this.guideFadeBelow = 6,
    this.framePadding = 3,
    this.mouseHandle = 8,
    this.touchHandle = 14,
    this.flingFriction = 0.015,
  });

  /// The smallest and the largest zoom. Zoom changes only the view.
  final double minZoom, maxZoom;

  /// One Zoom in or Zoom out step multiplies or divides the zoom by this.
  final double zoomStep;

  /// Zoom change per pixel of a Ctrl or Cmd wheel scroll.
  final double wheelZoomRate;

  /// Screen pixels of desk around the page when the view reaches its edge.
  final double deskMargin;

  /// The shortest page is its width times this ratio (one A4 sheet), so an
  /// empty note still looks like a sheet of paper.
  final double minPageRatio;

  /// Empty page below the lowest content, so the user can move farther down
  /// and continue writing (B1.3). The page grows with its content.
  final double trailingSpace;

  /// The spacing that a background gets when the user first picks it.
  final num ruledSpacing, gridSpacing, dotsSpacing;

  /// The visibility (0 to 1) that a background gets when first picked.
  final num defaultVisibility;

  /// The range of the spacing control, in page units.
  final num minSpacing, maxSpacing;

  /// The lowest visibility of the control. 0 is allowed in a document and
  /// hides the lines; the control keeps them visible.
  final num minVisibility;

  /// The line opacity at visibility 1. Lower values keep the paper subtle so
  /// text and ink stay clear (B4.2).
  final double maxGuideAlpha;

  /// Guides closer than this on screen fade out, so a far zoom shows calm
  /// paper instead of a grey surface.
  final double guideFadeBelow;

  /// Screen pixels between an object and its hover or selection border.
  final double framePadding;

  /// The side of a selection handle for a mouse or a pen, and for touch.
  final double mouseHandle, touchHandle;

  /// The friction of a touch scroll that continues after the finger lifts.
  final double flingFriction;
}
