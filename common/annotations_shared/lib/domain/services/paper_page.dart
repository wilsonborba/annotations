/// The long paper page (B1.1, B4): its background guides and its length.
///
/// A background is a visual guide only. It lives in the page settings of the
/// document (`page.background`), separate from the invisible placement rules:
/// a change of background is one `page` operation that keeps every item, so
/// it never moves content, never changes a collision verdict and never
/// changes a saved position (B4.2). The page length is not stored: the page
/// grows downward with its content.
library;

import 'dart:math' as math;

import '../../core/paper_settings.dart';
import '../models/note_document.dart';
import 'editor_rules.dart';
import 'note_history.dart';

/// The four backgrounds (B4.1). [code] is the stored `kind`.
enum PaperPattern {
  blank('blank'),
  ruled('ruled'),
  grid('grid'),
  dots('dots');

  const PaperPattern(this.code);
  final String code;

  static PaperPattern? parse(String code) {
    for (final p in values) {
      if (p.code == code) return p;
    }
    return null;
  }
}

/// One background with its spacing (page units) and visibility (0 to 1).
/// Blank has neither.
final class PaperGuides {
  const PaperGuides(this.pattern, {this.spacing, this.visibility});

  static const blank = PaperGuides(PaperPattern.blank);

  /// The guides of a stored background, or null for a kind that this app
  /// does not know (a newer app wrote it); such a page draws no guides.
  static PaperGuides? of(PaperBackground background) {
    final pattern = PaperPattern.parse(background.kind);
    if (pattern == null) return null;
    if (pattern == PaperPattern.blank) return blank;
    return PaperGuides(
      pattern,
      spacing: background.spacing,
      visibility: background.visibility,
    );
  }

  /// The background [pattern] with the spacing and visibility of [from]
  /// when it has them, else the defaults of [settings].
  factory PaperGuides.pick(
    PaperPattern pattern, {
    PaperGuides? from,
    PaperSettings settings = const PaperSettings(),
  }) {
    if (pattern == PaperPattern.blank) return blank;
    return PaperGuides(
      pattern,
      spacing:
          from?.spacing ??
          switch (pattern) {
            PaperPattern.ruled => settings.ruledSpacing,
            PaperPattern.grid => settings.gridSpacing,
            _ => settings.dotsSpacing,
          },
      visibility: from?.visibility ?? settings.defaultVisibility,
    );
  }

  final PaperPattern pattern;
  final num? spacing, visibility;

  PaperGuides copyWith({num? spacing, num? visibility}) => PaperGuides(
    pattern,
    spacing: spacing ?? this.spacing,
    visibility: visibility ?? this.visibility,
  );

  /// The stored `page.background` object.
  Map<String, Object?> toJson() => {
    'kind': pattern.code,
    if (pattern != PaperPattern.blank) ...{
      'spacing': spacing,
      'visibility': visibility,
    },
  };

  @override
  bool operator ==(Object other) =>
      other is PaperGuides &&
      other.pattern == pattern &&
      other.spacing == spacing &&
      other.visibility == visibility;

  @override
  int get hashCode => Object.hash(pattern, spacing, visibility);
}

/// The guide lines of a background inside one visible page area, in page
/// coordinates. They start at the page origin, so they stay on the page when
/// the view moves or zooms.
final class GuideLines {
  const GuideLines(this.rows, this.columns);
  static const none = GuideLines([], []);

  /// Horizontal lines (ruled, grid) or dot rows (dots), as page y values.
  final List<double> rows;

  /// Vertical lines (grid) or dot columns (dots), as page x values.
  final List<double> columns;
}

final class PaperPage {
  const PaperPage({this.settings = const PaperSettings()});
  final PaperSettings settings;

  /// The page background of [document], or null when the document has no
  /// paper page (typed or unsupported documents).
  PaperGuides? guidesOf(NoteDocument document) => document is PaperDocument
      ? PaperGuides.of(document.page.background)
      : null;

  /// Changes the background of the open document to [guides]. In Notes it is
  /// one Undo step of kind [CommandKind.page]; Instant has no history. Only
  /// `page.background` changes: the width and every item stay as they are.
  EditDecision setGuides(EditorSession session, PaperGuides guides) {
    EditDecision build(EditorRules rules, NoteDocument document) {
      final page = document.toJson()['page'];
      return rules.check(document, {
        'op': 'page',
        'page': {
          if (page is Map) ...page.cast<String, Object?>(),
          'background': guides.toJson(),
        },
      });
    }

    return switch (session) {
      NotesEditor() => session.apply(HistoryCommand(CommandKind.page), build),
      InstantEditor() => session.apply(build),
    };
  }

  /// The lowest point of the content of [document] in page units (0 for an
  /// empty page). Ink adds half its widest line.
  double contentBottom(NoteDocument document) {
    final layout = DocumentLayout.of(document);
    if (layout == null) return 0;
    final bounds = layout.boundsOf(layout.units);
    if (bounds == null) return 0;
    var line = 0.0;
    for (final item in (document as PaperDocument).items) {
      final width = switch (item) {
        StrokeItem(:final width) => width,
        ShapeItem(:final lineWidth) => lineWidth,
        _ => 0,
      };
      line = math.max(line, width / 2);
    }
    return bounds.bottom.toDouble() + line;
  }

  /// The page length: at least one sheet, and always [PaperSettings.
  /// trailingSpace] below the lowest content. Never stored.
  double pageHeight(NoteDocument document, num pageWidth) => math.max(
    pageWidth * settings.minPageRatio,
    contentBottom(document) + settings.trailingSpace,
  );

  /// The guide lines of [guides] inside the page area from [top] to [bottom]
  /// and from [left] to [right] (page units), on a page [width] units wide.
  GuideLines lines(
    PaperGuides guides, {
    required num width,
    required double left,
    required double top,
    required double right,
    required double bottom,
  }) {
    final spacing = guides.spacing?.toDouble();
    if (guides.pattern == PaperPattern.blank ||
        spacing == null ||
        spacing <= 0) {
      return GuideLines.none;
    }
    List<double> steps(double from, double to, double limit) {
      final first = math.max(1, (math.max(0, from) / spacing).ceil());
      final out = <double>[];
      for (var k = first; k * spacing <= math.min(to, limit); k++) {
        out.add(k * spacing);
      }
      return out;
    }

    final rows = steps(top, bottom, double.infinity);
    if (guides.pattern == PaperPattern.ruled) return GuideLines(rows, const []);
    return GuideLines(rows, steps(left, right, width.toDouble() - 0.001));
  }
}
