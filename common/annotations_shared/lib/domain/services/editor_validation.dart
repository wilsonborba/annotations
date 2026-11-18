part of 'editor_rules.dart';

// The note document schema check of the backend (version 1 of every family),
// with the same codes and paths. Placement rules run only after it passes.

const _originalKinds = [
  'text',
  'image',
  'file_card',
  'link_card',
  'website_card',
  'youtube_card',
  'csv_table',
  'pdf_preview',
  'reports_embed',
  'task_card',
  'quiz_card',
  'group',
  'stroke',
  'shape',
];
const _instantKinds = [
  'text',
  'image',
  'file_card',
  'link_card',
  'website_card',
  'youtube_card',
  'csv_table',
  'pdf_preview',
  'reports_embed',
  'group',
  'stroke',
  'shape',
];
const _typedKinds = [
  'heading',
  'paragraph',
  'list',
  'table',
  'figure',
  'handwriting',
  'file_card',
  'link_card',
  'website_card',
  'youtube_card',
  'csv_table',
  'pdf_preview',
  'reports_embed',
  'task_card',
  'quiz_card',
];
const _geometry = ['id', 'kind', 'x', 'y', 'width', 'height'];
const _pressureMax = 1000;
const _tiltMax = 1571;
final _hexColor = RegExp(r'^#[0-9A-Fa-f]{8}$');
final _markup = RegExp(
  r'</?[a-z!?][^<>]*>|<!--|javascript:',
  caseSensitive: false,
  unicode: true,
);

Never _fail(String code, String path) =>
    throw DocumentFormatException(code, path);

/// Checks a document body like the backend schema validator. Throws
/// [DocumentFormatException] with the backend code and path.
void _checkDocument(DocumentSchema schema, Object? body, NoteLimits limits) {
  final family = schema.family;
  if (family == null || schema.version != 1) {
    _fail('unsupported_schema_version', '');
  }
  if (utf8.encode(jsonEncode(body)).length > limits.maxDocumentBytes) {
    _fail('document_too_large', '');
  }
  final ctx = _Ctx(family, limits);
  final root = _Obj(body, '');
  if (family == DocumentFamily.typed) {
    root.allow(['blocks']);
    final blocks = root.arr('blocks');
    ctx.count(blocks.length, 'blocks');
    for (var i = 0; i < blocks.length; i++) {
      ctx.typedBlock(blocks[i], 'blocks[$i]');
    }
    return;
  }
  root.allow(['page', 'items']);
  final width = _checkPage(_Obj(root.req('page'), 'page'));
  final items = root.arr('items');
  ctx.count(items.length, 'items');
  final area = _Area(width, null);
  for (var i = 0; i < items.length; i++) {
    ctx.paperItem(items[i], 'items[$i]', area);
  }
  ctx.checkGroups();
}

num _checkPage(_Obj page) {
  page.allow(['width', 'background']);
  final width = page.number('width');
  if (width <= 0) _fail('invalid_size', page.at('width'));
  final bg = _Obj(page.req('background'), page.at('background'));
  final kind = bg.variant('kind', ['blank', 'ruled', 'grid', 'dots']);
  if (kind == 'blank') {
    bg.allow(['kind']);
  } else {
    bg.allow(['kind', 'spacing', 'visibility']);
    if (bg.number('spacing') <= 0) _fail('invalid_size', bg.at('spacing'));
    bg.range('visibility', 0, 1);
  }
  return width;
}

/// The drawing area of free ink: the page (open downward) or a handwriting box.
final class _Area {
  const _Area(this.width, this.height);
  final num width;
  final num? height;
  void hundredths(int x, int y, String path) => point(x / 100, y / 100, path);
  void point(num x, num y, String path) {
    if (x < 0 || x > width || y < 0 || (height != null && y > height!)) {
      _fail('out_of_bounds', path);
    }
  }
}

final class _Ctx {
  _Ctx(this.family, this.limits);
  final DocumentFamily family;
  final NoteLimits limits;
  final ids = <String, String>{};

  /// Group id, group path, and members with their paths.
  final groups = <(String, String, List<(String, String)>)>[];
  var items = 0;

  void count(int n, String path) {
    items += n;
    if (items > limits.maxItems) _fail('too_many_items', path);
  }

  void id(_Obj item) {
    final id = item.str('id');
    if (!_token(id, 64)) _fail('invalid_id', item.at('id'));
    if (ids.containsKey(id)) _fail('duplicate_id', item.at('id'));
    ids[id] = item.path;
  }

  void file(_Obj item, String key) {
    if (!_token(item.str(key), 64)) _fail('invalid_reference', item.at(key));
  }

  void paperItem(Object? value, String path, _Area area) {
    final item = _Obj(value, path);
    final kind = item.str('kind');
    if (!_originalKinds.contains(kind)) _fail('unknown_kind', item.at('kind'));
    if (family == DocumentFamily.instant && !_instantKinds.contains(kind)) {
      _fail('kind_not_allowed', item.at('kind'));
    }
    id(item);
    switch (kind) {
      case 'stroke':
        return stroke(item, area);
      case 'shape':
        return shape(item, area);
      case 'group':
        item.allow(['id', 'kind', 'members']);
        final members = item.arr('members');
        if (members.length < 2) _fail('invalid_count', item.at('members'));
        final list = <(String, String)>[];
        for (var i = 0; i < members.length; i++) {
          final p = '${item.at('members')}[$i]';
          final m = members[i];
          if (m is! String) _fail('invalid_type', p);
          if (!_token(m, 64)) _fail('invalid_id', p);
          list.add((m, p));
        }
        groups.add((item.str('id'), item.path, list));
        return;
    }
    // Structured block: geometry inside the page width, y at or below the top.
    final x = item.number('x');
    final y = item.number('y');
    final w = item.number('width');
    final h = item.number('height');
    if (w <= 0) _fail('invalid_size', item.at('width'));
    if (h <= 0) _fail('invalid_size', item.at('height'));
    if (x < 0 || x + w > area.width) _fail('out_of_bounds', item.at('x'));
    if (y < 0) _fail('out_of_bounds', item.at('y'));
    if (kind == 'text') {
      item.allow([..._geometry, 'spans']);
      return _spans(item, 'spans');
    }
    if (kind == 'image') {
      item.allow([..._geometry, 'file_id']);
      return file(item, 'file_id');
    }
    card(item, kind, _geometry);
  }

  void card(_Obj item, String kind, List<String> base) {
    switch (kind) {
      case 'file_card' || 'csv_table' || 'pdf_preview':
        item.allow([...base, 'file_id']);
        file(item, 'file_id');
      case 'link_card':
        item.allow([...base, 'url', 'title', 'site_name']);
        _url(item, 'url', youtube: false);
        _optText(item, 'title');
        _optText(item, 'site_name');
      case 'website_card':
        item.allow([
          ...base,
          'url',
          'title',
          'site_name',
          'description',
          'preview_file_id',
        ]);
        _url(item, 'url', youtube: false);
        for (final k in ['title', 'site_name', 'description']) {
          _optText(item, k);
        }
        if (item.opt('preview_file_id') != null) file(item, 'preview_file_id');
      case 'youtube_card':
        item.allow([...base, 'url', 'title', 'preview_file_id']);
        _url(item, 'url', youtube: true);
        _optText(item, 'title');
        if (item.opt('preview_file_id') != null) file(item, 'preview_file_id');
      case 'reports_embed':
        final source = item.variant('source', ['link', 'upload']);
        if (family == DocumentFamily.instant && source != 'link') {
          _fail('kind_not_allowed', item.at('source'));
        }
        _reference(item, 'report_id');
        if (item.variant('mode', ['live', 'snapshot']) == 'snapshot') {
          item.allow([
            ...base,
            'report_id',
            'mode',
            'source',
            'snapshot_id',
            'captured_at',
          ]);
          _reference(item, 'snapshot_id');
          if (item.integer('captured_at') <= 0) {
            _fail('out_of_range', item.at('captured_at'));
          }
        } else {
          item.allow([...base, 'report_id', 'mode', 'source']);
        }
      case 'task_card':
        item.allow([...base, 'task_id']);
        _reference(item, 'task_id');
      case 'quiz_card':
        item.allow([...base, 'study_id', 'quiz_id']);
        if (item.opt('study_id') == null && item.opt('quiz_id') == null) {
          _fail('missing_field', item.at('quiz_id'));
        }
        for (final k in ['study_id', 'quiz_id']) {
          if (item.opt(k) != null) _reference(item, k);
        }
      default:
        _fail('unknown_kind', item.at('kind'));
    }
  }

  void ink(_Obj item, _Area area) {
    item.variant('kind', ['stroke', 'shape']);
    item.str('kind') == 'stroke' ? stroke(item, area) : shape(item, area);
  }

  void stroke(_Obj item, _Area area) {
    final tool = item.variant('tool', [
      'round',
      'flat',
      'brush',
      'highlighter',
    ]);
    const keys = [
      'id',
      'kind',
      'tool',
      'brush_version',
      'width',
      'color',
      'opacity',
      'samples',
      'nodes',
    ];
    if (tool == 'flat') {
      item.allow([...keys, 'tip_angle']);
      item.range('tip_angle', -math.pi, math.pi);
    } else {
      item.allow(keys);
    }
    if (item.integer('brush_version') < 1) {
      _fail('out_of_range', item.at('brush_version'));
    }
    if (item.number('width') <= 0) _fail('invalid_size', item.at('width'));
    _color(item, 'color');
    _opacity(item);
    // Compact columns (annotations#19), checked like the backend.
    final samples = _Obj(item.req('samples'), item.at('samples'));
    samples.allow(['count', 'data']);
    final count = samples.integer('count');
    if (count < 1) _fail('empty_array', samples.at('count'));
    if (count > limits.maxSamplesPerStroke) {
      _fail('too_many_samples', item.at('samples'));
    }
    final data = samples.at('data');
    final SampleColumns c;
    try {
      c = SampleCodec.decode(count, samples.str('data'));
    } on MalformedSamples {
      _fail('invalid_samples', data);
    }
    for (var i = 0; i < c.length; i++) {
      area.hundredths(c.x[i], c.y[i], data);
    }
    final ts = c.t;
    for (var i = 0; i < ts.length; i++) {
      if ((i == 0 && ts[i] != 0) || (i > 0 && ts[i] < ts[i - 1])) {
        _fail('invalid_sample_order', data);
      }
    }
    for (final (values, max) in [
      (c.pressure, _pressureMax),
      (c.tilt, _tiltMax),
    ]) {
      if (values != null && values.any((v) => v < 0 || v > max)) {
        _fail('out_of_range', data);
      }
    }
    nodes(item, 'nodes', area, c.length);
  }

  /// Editable nodes and handles use integer 1/100 page units.
  void nodes(_Obj item, String key, _Area area, int? samples) {
    final list = item.arr(key);
    if (list.isEmpty) _fail('empty_array', item.at(key));
    if (list.length > limits.maxNodesPerStroke) {
      _fail('too_many_nodes', item.at(key));
    }
    for (var i = 0; i < list.length; i++) {
      final n = _Obj(list[i], '${item.at(key)}[$i]');
      n.allow([
        'x',
        'y',
        'in',
        'out',
        'mode',
        'corner',
        if (samples != null) 'sample',
      ]);
      area.hundredths(n.integer('x'), n.integer('y'), n.at('x'));
      n.variant('mode', ['independent', 'smooth', 'symmetric']);
      n.boolean('corner');
      for (final h in ['in', 'out']) {
        final v = n.opt(h);
        if (v == null) continue;
        final handle = _Obj(v, n.at(h));
        handle.allow(['x', 'y']);
        handle.integer('x');
        handle.integer('y');
      }
      if (samples != null && n.opt('sample') != null) {
        final s = n.integer('sample');
        if (s < 0 || s >= samples) _fail('out_of_range', n.at('sample'));
      }
    }
  }

  void shape(_Obj item, _Area area) {
    final shape = item.variant('shape', [
      'circle',
      'rectangle',
      'triangle',
      'path',
    ]);
    const style = [
      'id',
      'kind',
      'shape',
      'color',
      'line_width',
      'opacity',
      'fill',
    ];
    if (item.number('line_width') <= 0) {
      _fail('invalid_size', item.at('line_width'));
    }
    _color(item, 'color');
    if (item.opt('fill') != null) _color(item, 'fill');
    _opacity(item);
    switch (shape) {
      case 'circle':
        item.allow([...style, 'center', 'radius']);
        final c = _Obj(item.req('center'), item.at('center'));
        c.allow(['x', 'y']);
        final r = item.number('radius');
        if (r <= 0) _fail('invalid_size', item.at('radius'));
        final (x, y) = (c.number('x'), c.number('y'));
        area.point(x - r, y - r, item.at('center'));
        area.point(x + r, y + r, item.at('center'));
      case 'rectangle':
        item.allow([...style, 'x', 'y', 'width', 'height']);
        final (x, y) = (item.number('x'), item.number('y'));
        final (w, h) = (item.number('width'), item.number('height'));
        if (w <= 0) _fail('invalid_size', item.at('width'));
        if (h <= 0) _fail('invalid_size', item.at('height'));
        area.point(x, y, item.at('x'));
        area.point(x + w, y + h, item.at('x'));
      case 'triangle':
        item.allow([...style, 'points']);
        final points = item.arr('points');
        if (points.length != 3) _fail('invalid_count', item.at('points'));
        for (var i = 0; i < points.length; i++) {
          final p = _Obj(points[i], '${item.at('points')}[$i]');
          p.allow(['x', 'y']);
          area.point(p.number('x'), p.number('y'), p.at('x'));
        }
      default:
        item.allow([...style, 'nodes', 'closed']);
        item.boolean('closed');
        nodes(item, 'nodes', area, null);
    }
  }

  /// Every member exists, no item is in two groups and groups have no cycle.
  void checkGroups() {
    final owner = <String, String>{};
    for (final (id, _, members) in groups) {
      for (final (m, p) in members) {
        if (!ids.containsKey(m)) _fail('missing_reference', p);
        if (m == id) _fail('group_cycle', p);
        if (owner.containsKey(m)) _fail('multiple_groups', p);
        owner[m] = id;
      }
    }
    for (final (id, path, _) in groups) {
      var current = id;
      var steps = 0;
      for (
        var parent = owner[current];
        parent != null;
        parent = owner[current]
      ) {
        if (parent == id) _fail('group_cycle', path);
        current = parent;
        steps++;
        if (steps > groups.length) _fail('group_cycle', path);
      }
    }
  }

  void typedBlock(Object? value, String path) {
    final block = _Obj(value, path);
    final kind = block.str('kind');
    if (!_typedKinds.contains(kind)) _fail('unknown_kind', block.at('kind'));
    id(block);
    const base = ['id', 'kind'];
    switch (kind) {
      case 'heading':
        block.allow([...base, 'level', 'spans']);
        final level = block.integer('level');
        if (level < 1 || level > 6) _fail('out_of_range', block.at('level'));
        _spans(block, 'spans');
      case 'paragraph':
        block.allow([...base, 'spans']);
        _spans(block, 'spans');
      case 'list':
        block.allow([...base, 'ordered', 'items']);
        block.boolean('ordered');
        final items = block.arr('items');
        if (items.isEmpty) _fail('empty_array', block.at('items'));
        for (var i = 0; i < items.length; i++) {
          final it = _Obj(items[i], '${block.at('items')}[$i]');
          it.allow(['spans']);
          _spans(it, 'spans');
        }
      case 'table':
        block.allow([...base, 'header', 'rows']);
        if (block.opt('header') != null) block.boolean('header');
        final rows = block.arr('rows');
        if (rows.isEmpty) _fail('empty_array', block.at('rows'));
        int? width;
        for (var i = 0; i < rows.length; i++) {
          final row = _Obj(rows[i], '${block.at('rows')}[$i]');
          row.allow(['cells']);
          final cells = row.arr('cells');
          if (cells.isEmpty) _fail('empty_array', row.at('cells'));
          if ((width ??= cells.length) != cells.length) {
            _fail('invalid_count', row.at('cells'));
          }
          for (var j = 0; j < cells.length; j++) {
            final c = _Obj(cells[j], '${row.at('cells')}[$j]');
            c.allow(['spans']);
            _spans(c, 'spans');
          }
        }
      case 'figure':
        block.allow([...base, 'file_id', 'caption']);
        file(block, 'file_id');
        if (block.opt('caption') != null) _spans(block, 'caption');
      case 'handwriting':
        block.allow([...base, 'width', 'height', 'ink']);
        final (w, h) = (block.number('width'), block.number('height'));
        if (w <= 0) _fail('invalid_size', block.at('width'));
        if (h <= 0) _fail('invalid_size', block.at('height'));
        final ink = block.arr('ink');
        if (ink.isEmpty) _fail('empty_array', block.at('ink'));
        count(ink.length, block.at('ink'));
        final area = _Area(w, h);
        for (var i = 0; i < ink.length; i++) {
          final it = _Obj(ink[i], '${block.at('ink')}[$i]');
          id(it);
          this.ink(it, area);
        }
      default:
        card(block, kind, base);
    }
  }
}

bool _token(String s, int max) {
  final bytes = utf8.encode(s);
  return bytes.isNotEmpty &&
      bytes.length <= max &&
      bytes.every(
        (b) =>
            (b >= 0x30 && b <= 0x39) ||
            (b >= 0x41 && b <= 0x5A) ||
            (b >= 0x61 && b <= 0x7A) ||
            b == 0x2D ||
            b == 0x5F,
      );
}

void _reference(_Obj item, String key) {
  if (!_token(item.str(key), 128)) _fail('invalid_reference', item.at(key));
}

void _color(_Obj item, String key) {
  if (!_hexColor.hasMatch(item.str(key))) _fail('invalid_color', item.at(key));
}

void _opacity(_Obj item) {
  final o = item.number('opacity');
  if (o <= 0 || o > 1) _fail('out_of_range', item.at('opacity'));
}

void _plainText(String s, String path) {
  if (_markup.hasMatch(s)) _fail('markup_not_allowed', path);
  for (final r in s.runes) {
    final control = r <= 0x1F || (r >= 0x7F && r <= 0x9F);
    if (control && r != 0x0A && r != 0x09) _fail('invalid_text', path);
  }
}

void _optText(_Obj item, String key) {
  if (item.opt(key) != null) _plainText(item.str(key), item.at(key));
}

/// HTTP(S) links with a host and without credentials. The server parses links
/// again with its own URL parser.
void _url(_Obj item, String key, {required bool youtube}) {
  final url = Uri.tryParse(item.str(key));
  if (url == null ||
      !(url.scheme == 'http' || url.scheme == 'https') ||
      url.host.isEmpty ||
      url.userInfo.isNotEmpty) {
    _fail('invalid_url', item.at(key));
  }
  const hosts = ['youtube.com', 'www.youtube.com', 'm.youtube.com', 'youtu.be'];
  if (youtube && !hosts.contains(url.host)) _fail('invalid_url', item.at(key));
}

/// Rich text: plain text runs with bold, italic, strikethrough, color and size.
void _spans(_Obj item, String key) {
  final spans = item.arr(key);
  for (var i = 0; i < spans.length; i++) {
    final s = _Obj(spans[i], '${item.at(key)}[$i]');
    s.allow(['text', 'bold', 'italic', 'strikethrough', 'color', 'size']);
    _plainText(s.str('text'), s.at('text'));
    for (final flag in ['bold', 'italic', 'strikethrough']) {
      if (s.opt(flag) != null) s.boolean(flag);
    }
    if (s.opt('color') != null) _color(s, 'color');
    if (s.opt('size') != null && s.number('size') <= 0) {
      _fail('invalid_size', s.at('size'));
    }
  }
}

/// A JSON object with its path, for strict field access. Null counts as absent.
final class _Obj {
  _Obj(Object? value, this.path)
    : map = value is Map<String, Object?> ? value : _fail('invalid_type', path);
  final Map<String, Object?> map;
  final String path;

  String at(String key) => path.isEmpty ? key : '$path.$key';
  void allow(List<String> keys) {
    final unknown = map.keys.where((k) => !keys.contains(k)).toList()..sort();
    if (unknown.isNotEmpty) _fail('unknown_field', at(unknown.first));
  }

  Object? opt(String key) => map[key];
  Object req(String key) => map[key] ?? _fail('missing_field', at(key));
  T _typed<T>(String key) {
    final value = req(key);
    return value is T ? value as T : _fail('invalid_type', at(key));
  }

  String str(String key) => _typed<String>(key);
  bool boolean(String key) => _typed<bool>(key);
  List<Object?> arr(String key) => _typed<List<Object?>>(key);
  int integer(String key) => _typed<int>(key);
  num number(String key) {
    final n = _typed<num>(key);
    if (!n.isFinite) _fail('non_finite_number', at(key));
    return n;
  }

  /// Integers only. A fraction or another type is `invalid_type` at its index.
  List<int> ints(String key) {
    final list = arr(key);
    final out = <int>[];
    for (var i = 0; i < list.length; i++) {
      final value = list[i];
      if (value is! int) _fail('invalid_type', '${at(key)}[$i]');
      out.add(value);
    }
    return out;
  }

  num range(String key, num min, num max) {
    final n = number(key);
    if (n < min || n > max) _fail('out_of_range', at(key));
    return n;
  }

  String variant(String key, List<String> allowed) {
    final v = str(key);
    if (!allowed.contains(v)) _fail('invalid_variant', at(key));
    return v;
  }
}
