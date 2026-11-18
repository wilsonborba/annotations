/// Portable note payloads from the versioned Annotations document contract.
///
/// JSON objects retain every field, including explicit nulls and unknown nested
/// content. Decoding checks supported field types; it does not grant file access,
/// validate editor placement, migrate content or convert representations.
library;

import 'stroke_samples_codec.dart';

part 'note_items.dart';

enum DocumentFamily {
  original('note-original'),
  typed('note-typed'),
  instant('instant-room');

  const DocumentFamily(this.schemaName);
  final String schemaName;
}

/// Content schema identity. This is neither a brush version nor an edit revision.
final class DocumentSchema {
  DocumentSchema(this.name, this.version) {
    if (version < 1) {
      throw const DocumentFormatException('invalid_version', 'schema_version');
    }
  }
  final String name;
  final int version;
  DocumentFamily? get family {
    for (final family in DocumentFamily.values) {
      if (family.schemaName == name) return family;
    }
    return null;
  }
}

/// Operational revision metadata stays outside the document body, as in the API.
/// Moving an item changes [noteRevision], not [document.schema].
final class NoteRevision {
  NoteRevision({
    required this.noteRevision,
    required this.revisionId,
    required this.document,
  }) {
    if (noteRevision < 1) {
      throw const DocumentFormatException('invalid_revision', 'revision');
    }
  }
  final int noteRevision;
  final String revisionId;
  final NoteDocument document;
}

/// A decoding failure contains a code/path only, never private document content.
final class DocumentFormatException implements Exception {
  const DocumentFormatException(this.code, this.path);
  final String code;
  final String path;
  @override
  String toString() => '$code at $path';
}

/// Immutable JSON-backed values keep number types, absent fields and nulls intact.
abstract base class DocumentValue {
  const DocumentValue._(this._object);
  final _Object _object;
  Map<String, Object?> toJson() =>
      _copy(_object.values) as Map<String, Object?>;
}

sealed class NoteDocument extends DocumentValue {
  const NoteDocument._(super.object, this.schema) : super._();
  final DocumentSchema schema;

  factory NoteDocument.fromJson(
    Object? json, {
    required DocumentSchema schema,
  }) {
    final object = _Object(_freeze(json), '');
    // Do not interpret a newer format using today's assumptions. Its complete
    // payload can be read and saved without losing unsupported content.
    if (schema.version != 1 || schema.family == null) {
      return OpaqueDocument._(object, schema);
    }
    return switch (schema.family!) {
      DocumentFamily.original => OriginalDocument._(object, schema),
      DocumentFamily.typed => TypedDocument._(object, schema),
      DocumentFamily.instant => InstantRoomDocument._(object, schema),
    };
  }
}

final class OpaqueDocument extends NoteDocument {
  const OpaqueDocument._(super.object, super.schema) : super._();
}

sealed class PaperDocument extends NoteDocument {
  PaperDocument._(super.object, super.schema) : super._() {
    page = PageSettings._(_object.object('page'));
    items = _object.models(
      'items',
      (o) => DocumentItem._decode(o, typed: false),
    );
  }
  late final PageSettings page;
  late final List<DocumentItem> items;
}

final class OriginalDocument extends PaperDocument {
  OriginalDocument._(super.object, super.schema) : super._();
}

final class InstantRoomDocument extends PaperDocument {
  InstantRoomDocument._(super.object, super.schema) : super._();
}

final class TypedDocument extends NoteDocument {
  TypedDocument._(super.object, super.schema) : super._() {
    blocks = _object.models(
      'blocks',
      (o) => DocumentItem._decode(o, typed: true),
    );
  }
  late final List<DocumentItem> blocks;
}

final class PageSettings extends DocumentValue {
  PageSettings._(super.object) : super._() {
    width = _object.number('width');
    background = PaperBackground._(_object.object('background'));
  }

  /// Logical page units: one unit is one logical pixel at zoom 1.0.
  late final num width;
  late final PaperBackground background;
}

final class PaperBackground extends DocumentValue {
  PaperBackground._(super.object) : super._() {
    kind = _object.string('kind');
    spacing = _object.optionalNumber('spacing');
    visibility = _object.optionalNumber('visibility');
    if (['ruled', 'grid', 'dots'].contains(kind)) {
      _object.number('spacing');
      _object.number('visibility');
    }
  }

  /// Unknown backgrounds remain available as opaque JSON in [toJson].
  late final String kind;

  /// Logical page units; absent for a blank page.
  late final num? spacing;
  late final num? visibility;
}

final class ItemBounds {
  const ItemBounds({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  /// Logical page units, independent of screen pixels, rotation and zoom.
  final num x, y, width, height;
  static ItemBounds _read(_Object o) => ItemBounds(
    x: o.number('x'),
    y: o.number('y'),
    width: o.number('width'),
    height: o.number('height'),
  );
}

final class PagePoint extends DocumentValue {
  PagePoint._(super.object) : super._() {
    x = _object.number('x');
    y = _object.number('y');
  }

  /// Logical page units (geometric shapes, not stroke/node hundredths).
  late final num x, y;
}

final class InkPoint extends DocumentValue {
  InkPoint._(super.object) : super._() {
    x = _object.integer('x');
    y = _object.integer('y');
  }

  /// Integer hundredths of one logical page unit. Never round during decoding.
  late final int x, y;
}

final class CurveNode extends DocumentValue {
  CurveNode._(super.object) : super._() {
    x = _object.integer('x');
    y = _object.integer('y');
    incoming = _object.optionalObject('in', InkPoint._);
    outgoing = _object.optionalObject('out', InkPoint._);
    mode = _object.string('mode');
    corner = _object.boolean('corner');
    sample = _object.optionalInteger('sample');
  }

  /// Integer hundredths of a logical page unit, including both handles.
  late final int x, y;
  late final InkPoint? incoming, outgoing;

  /// independent, smooth, symmetric, or a preserved newer mode.
  late final String mode;
  late final bool corner;
  late final int? sample;
}

final class StrokeSamples extends DocumentValue {
  StrokeSamples._(super.object) : super._() {
    // Compact columns (annotations#19); see [SampleCodec].
    final SampleColumns c;
    try {
      c = SampleCodec.decode(_object.integer('count'), _object.string('data'));
    } on MalformedSamples {
      throw DocumentFormatException('invalid_samples', _object.at('data'));
    }
    x = List.unmodifiable(c.x);
    y = List.unmodifiable(c.y);
    time = List.unmodifiable(c.t);
    pressure = c.pressure == null ? null : List.unmodifiable(c.pressure!);
    tilt = c.tilt == null ? null : List.unmodifiable(c.tilt!);
  }

  /// Integer hundredths of logical page units, in document coordinates.
  late final List<int> x, y;

  /// Integer milliseconds from stroke start; the backend requires zero first.
  late final List<int> time;

  /// Optional device data: pressure in thousandths, tilt in milliradians.
  /// Absence remains absence; no synthesized pressure or tilt is introduced.
  late final List<int>? pressure, tilt;
}

final class TextSpanValue extends DocumentValue {
  TextSpanValue._(super.object) : super._() {
    text = _object.string('text');
    bold = _object.optionalBoolean('bold');
    italic = _object.optionalBoolean('italic');
    strikethrough = _object.optionalBoolean('strikethrough');
    color = _object.optionalString('color');
    size = _object.optionalNumber('size');
  }
  late final String text;
  late final bool? bold, italic, strikethrough;

  /// #RRGGBBAA, without normalization that could change stored JSON.
  late final String? color;
  late final num? size;
}

final class RichTextValue extends DocumentValue {
  RichTextValue._(super.object) : super._() {
    spans = _object.models('spans', TextSpanValue._);
  }
  late final List<TextSpanValue> spans;
}

final class TableRowValue extends DocumentValue {
  TableRowValue._(super.object) : super._() {
    cells = _object.models('cells', RichTextValue._);
  }
  late final List<RichTextValue> cells;
}

// Freeze once at the document boundary. Nested models view that same immutable
// tree; serializers return independent copies so callers cannot mutate content.
Object? _freeze(Object? value) {
  if (value == null || value is String || value is bool || value is int) {
    return value;
  }
  if (value is double && value.isFinite) return value;
  if (value is List) return List<Object?>.unmodifiable(value.map(_freeze));
  if (value is Map && value.keys.every((k) => k is String)) {
    return Map<String, Object?>.unmodifiable(
      value.map((k, v) => MapEntry(k as String, _freeze(v))),
    );
  }
  throw const DocumentFormatException('invalid_json', '');
}

Object? _copy(Object? value) {
  if (value is Map<String, Object?>) {
    return value.map((k, v) => MapEntry(k, _copy(v)));
  }
  if (value is List) return value.map(_copy).toList();
  return value;
}

final class _Object {
  _Object(Object? value, this.path)
    : values = value is Map<String, Object?>
          ? value
          : throw DocumentFormatException('invalid_type', path);
  final Map<String, Object?> values;
  final String path;
  String at(String key) => path.isEmpty ? key : '$path.$key';
  T read<T>(String key) {
    final value = values[key];
    if (value == null) throw DocumentFormatException('missing_field', at(key));
    if (value is! T) throw DocumentFormatException('invalid_type', at(key));
    return value as T;
  }

  T? optional<T>(String key) => values[key] == null ? null : read<T>(key);
  String string(String key) => read<String>(key);
  int integer(String key) => read<int>(key);
  num number(String key) => read<num>(key);
  bool boolean(String key) => read<bool>(key);
  String? optionalString(String key) => optional<String>(key);
  int? optionalInteger(String key) => optional<int>(key);
  num? optionalNumber(String key) => optional<num>(key);
  bool? optionalBoolean(String key) => optional<bool>(key);
  _Object object(String key) =>
      _Object(read<Map<String, Object?>>(key), at(key));
  T? optionalObject<T>(String key, T Function(_Object) decode) =>
      values[key] == null ? null : decode(object(key));
  List<_Object> objects(String key) {
    final list = read<List<Object?>>(key);
    return List.generate(
      list.length,
      (i) => _Object(list[i], '${at(key)}[$i]'),
      growable: false,
    );
  }

  List<T> list<T>(String key) {
    final list = read<List<Object?>>(key);
    return List<T>.unmodifiable(
      List.generate(list.length, (i) {
        if (list[i] is! T) {
          throw DocumentFormatException('invalid_type', '${at(key)}[$i]');
        }
        return list[i] as T;
      }),
    );
  }

  List<T> models<T>(String key, T Function(_Object) decode) =>
      List<T>.unmodifiable(objects(key).map(decode));
  List<int> integers(String key) => list<int>(key);
  List<int>? optionalIntegers(String key) =>
      values[key] == null ? null : integers(key);
}
