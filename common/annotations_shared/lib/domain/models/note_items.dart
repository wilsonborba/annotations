part of 'note_document.dart';

/// One item/block. Unknown kinds and unsupported variants retain their raw JSON.
sealed class DocumentItem extends DocumentValue {
  const DocumentItem._(super.object) : super._();
  String get kind => _object.string('kind');
  String? get id =>
      _object.values['id'] is String ? _object.values['id'] as String : null;

  factory DocumentItem.fromJson(
    Object? json, {
    required DocumentFamily family,
  }) => _decode(
    _Object(_freeze(json), ''),
    typed: family == DocumentFamily.typed,
  );

  static DocumentItem _decode(_Object o, {required bool typed}) {
    final kind = o.string('kind');
    if (!typed) {
      switch (kind) {
        case 'text':
          return TextItem._(o);
        case 'image':
          return ImageItem._(o);
        case 'group':
          return GroupItem._(o);
        case 'stroke':
          return StrokeItem._(o);
        case 'shape':
          return _shape(o);
      }
    } else {
      switch (kind) {
        case 'heading':
          return HeadingBlock._(o);
        case 'paragraph':
          return ParagraphBlock._(o);
        case 'list':
          return ListBlock._(o);
        case 'table':
          return TableBlock._(o);
        case 'figure':
          return FigureBlock._(o);
        case 'handwriting':
          return HandwritingBlock._(o);
      }
    }
    return switch (kind) {
      'file_card' => FileCard._(o, paper: !typed),
      'link_card' => LinkCard._(o, paper: !typed),
      'website_card' => WebsiteCard._(o, paper: !typed),
      'youtube_card' => YoutubeCard._(o, paper: !typed),
      'csv_table' => CsvTableCard._(o, paper: !typed),
      'pdf_preview' => PdfPreviewCard._(o, paper: !typed),
      'reports_embed' => ReportsEmbed._(o, paper: !typed),
      'task_card' => TaskCard._(o, paper: !typed),
      'quiz_card' => QuizCard._(o, paper: !typed),
      _ => OpaqueItem._(o),
    };
  }

  static DocumentItem _shape(_Object o) => switch (o.string('shape')) {
    'circle' => CircleShape._(o),
    'rectangle' => RectangleShape._(o),
    'triangle' => TriangleShape._(o),
    'path' => PathShape._(o),
    _ => OpaqueItem._(o),
  };
}

final class OpaqueItem extends DocumentItem {
  const OpaqueItem._(super.object) : super._();
}

sealed class KnownItem extends DocumentItem {
  KnownItem._(super.object) : super._() {
    _object.string('id');
  }
  @override
  String get id => _object.string('id');
}

/// Cards are positioned in Original/Instant and ordered without bounds in Typed.
sealed class StructuredItem extends KnownItem {
  StructuredItem._(super.object, {required bool paper}) : super._() {
    bounds = paper ? ItemBounds._read(_object) : null;
  }
  late final ItemBounds? bounds;
}

final class TextItem extends StructuredItem {
  TextItem._(super.object) : super._(paper: true) {
    spans = _object.models('spans', TextSpanValue._);
  }
  late final List<TextSpanValue> spans;
}

sealed class FileItem extends StructuredItem {
  FileItem._(super.object, {required super.paper}) : super._() {
    fileId = _object.string('file_id');
  }

  /// Managed file reference, never a local filename or absolute path.
  late final String fileId;
}

final class ImageItem extends FileItem {
  ImageItem._(super.object) : super._(paper: true);
}

final class FileCard extends FileItem {
  FileCard._(super.object, {required super.paper}) : super._();
}

final class CsvTableCard extends FileItem {
  CsvTableCard._(super.object, {required super.paper}) : super._();
}

final class PdfPreviewCard extends FileItem {
  PdfPreviewCard._(super.object, {required super.paper}) : super._();
}

base class LinkCard extends StructuredItem {
  LinkCard._(super.object, {required super.paper}) : super._() {
    url = _object.string('url');
    title = _object.optionalString('title');
    siteName = _object.optionalString('site_name');
  }
  late final String url;
  late final String? title, siteName;
}

final class WebsiteCard extends LinkCard {
  WebsiteCard._(super.object, {required super.paper}) : super._() {
    description = _object.optionalString('description');
    previewFileId = _object.optionalString('preview_file_id');
  }
  late final String? description, previewFileId;
}

final class YoutubeCard extends LinkCard {
  YoutubeCard._(super.object, {required super.paper}) : super._() {
    previewFileId = _object.optionalString('preview_file_id');
  }
  late final String? previewFileId;
}

final class ReportsEmbed extends StructuredItem {
  ReportsEmbed._(super.object, {required super.paper}) : super._() {
    reportId = _object.string('report_id');
    mode = _object.string('mode');
    source = _object.string('source');
    snapshotId = _object.optionalString('snapshot_id');
    capturedAt = _object.optionalInteger('captured_at');
    if (mode == 'snapshot') {
      _object.string('snapshot_id');
      _object.integer('captured_at');
    }
  }
  late final String reportId, mode, source;
  late final String? snapshotId;

  /// Unix seconds, not milliseconds.
  late final int? capturedAt;
}

final class TaskCard extends StructuredItem {
  TaskCard._(super.object, {required super.paper}) : super._() {
    taskId = _object.string('task_id');
  }
  late final String taskId;
}

final class QuizCard extends StructuredItem {
  QuizCard._(super.object, {required super.paper}) : super._() {
    studyId = _object.optionalString('study_id');
    quizId = _object.optionalString('quiz_id');
    if (studyId == null && quizId == null) {
      throw DocumentFormatException('missing_field', _object.at('quiz_id'));
    }
  }
  late final String? studyId, quizId;
}

final class GroupItem extends KnownItem {
  GroupItem._(super.object) : super._() {
    members = _object.list<String>('members');
  }
  late final List<String> members;
}

final class StrokeItem extends KnownItem {
  StrokeItem._(super.object) : super._() {
    tool = _object.string('tool');
    brushVersion = _object.integer('brush_version');
    width = _object.number('width');
    color = _object.string('color');
    opacity = _object.number('opacity');
    tipAngle = _object.optionalNumber('tip_angle');
    if (tool == 'flat') _object.number('tip_angle');
    samples = StrokeSamples._(_object.object('samples'));
    nodes = _object.models('nodes', CurveNode._);
  }
  late final String tool, color;

  /// Brush definitions evolve independently of schema and saved note revisions.
  late final int brushVersion;

  /// Logical page units; tip angle is radians. Colors use #RRGGBBAA.
  late final num width, opacity;
  late final num? tipAngle;
  late final StrokeSamples samples;
  late final List<CurveNode> nodes;
}

sealed class ShapeItem extends KnownItem {
  ShapeItem._(super.object) : super._() {
    color = _object.string('color');
    fill = _object.optionalString('fill');
    lineWidth = _object.number('line_width');
    opacity = _object.number('opacity');
  }
  late final String color;
  late final String? fill;

  /// Line width uses logical page units.
  late final num lineWidth, opacity;
}

final class CircleShape extends ShapeItem {
  CircleShape._(super.object) : super._() {
    center = PagePoint._(_object.object('center'));
    radius = _object.number('radius');
  }
  late final PagePoint center;
  late final num radius;
}

final class RectangleShape extends ShapeItem {
  RectangleShape._(super.object) : super._() {
    bounds = ItemBounds._read(_object);
  }
  late final ItemBounds bounds;
}

final class TriangleShape extends ShapeItem {
  TriangleShape._(super.object) : super._() {
    points = _object.models('points', PagePoint._);
  }
  late final List<PagePoint> points;
}

final class PathShape extends ShapeItem {
  PathShape._(super.object) : super._() {
    nodes = _object.models('nodes', CurveNode._);
    closed = _object.boolean('closed');
  }
  late final List<CurveNode> nodes;
  late final bool closed;
}

final class HeadingBlock extends KnownItem {
  HeadingBlock._(super.object) : super._() {
    level = _object.integer('level');
    spans = _object.models('spans', TextSpanValue._);
  }
  late final int level;
  late final List<TextSpanValue> spans;
}

final class ParagraphBlock extends KnownItem {
  ParagraphBlock._(super.object) : super._() {
    spans = _object.models('spans', TextSpanValue._);
  }
  late final List<TextSpanValue> spans;
}

final class ListBlock extends KnownItem {
  ListBlock._(super.object) : super._() {
    ordered = _object.boolean('ordered');
    items = _object.models('items', RichTextValue._);
  }
  late final bool ordered;
  late final List<RichTextValue> items;
}

final class TableBlock extends KnownItem {
  TableBlock._(super.object) : super._() {
    header = _object.optionalBoolean('header');
    rows = _object.models('rows', TableRowValue._);
  }
  late final bool? header;
  late final List<TableRowValue> rows;
}

final class FigureBlock extends KnownItem {
  FigureBlock._(super.object) : super._() {
    fileId = _object.string('file_id');
    caption = _object.values['caption'] == null
        ? null
        : _object.models('caption', TextSpanValue._);
  }
  late final String fileId;
  late final List<TextSpanValue>? caption;
}

final class HandwritingBlock extends KnownItem {
  HandwritingBlock._(super.object) : super._() {
    width = _object.number('width');
    height = _object.number('height');
    ink = _object.models(
      'ink',
      (o) => switch (o.string('kind')) {
        'stroke' => StrokeItem._(o),
        'shape' => DocumentItem._shape(o),
        _ => OpaqueItem._(o),
      },
    );
  }

  /// Local snippet extent in logical page units; ink retains hundredth units.
  late final num width, height;
  late final List<DocumentItem> ink;
}
