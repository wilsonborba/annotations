/// Selection and clipboard settings that the alignment left to implementation
/// (B2 G1 confirmed the behavior, not these numbers). Values are in logical
/// page units, like every stored position.
final class SelectionSettings {
  const SelectionSettings({
    this.inkHitRadius = 6,
    this.lassoCoverage = 1.0,
    this.externalTextWidth = 400,
  });

  /// How far from the line of a stroke or shape a click or tap still selects
  /// it, added to half the line width.
  final double inkHitRadius;

  /// The part of the drawn line of a drawing object that must be inside the
  /// lasso to select it: 1.0 means the whole line.
  final double lassoCoverage;

  /// The widest text block that an external text paste creates. A narrower
  /// space to the right edge of the page makes the block narrower.
  final num externalTextWidth;
}
