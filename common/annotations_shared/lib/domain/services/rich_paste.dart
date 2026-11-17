/// Sanitizing of rich content that another app put on the clipboard (B2 G1,
/// B11 clipboard section). The HTML is parsed as inert data: no script runs,
/// no style sheet applies and no image, link or other remote resource is ever
/// fetched. Only the supported span formatting survives (bold, italic,
/// strikethrough and color); everything else becomes plain text or is dropped.
library;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../../dal/local/text_engine.dart';

/// Elements whose content is never text for the note: scripts, styles,
/// embedded media and form controls. Images are dropped: a remote picture is
/// never fetched.
const _dropped = {
  'script',
  'style',
  'head',
  'title',
  'template',
  'noscript',
  'iframe',
  'frame',
  'frameset',
  'object',
  'embed',
  'applet',
  'svg',
  'math',
  'canvas',
  'video',
  'audio',
  'img',
  'picture',
  'source',
  'track',
  'map',
  'button',
  'input',
  'select',
  'textarea',
  'meta',
  'link',
  'base',
};

/// Elements that start and end a line.
const _blocks = {
  'address',
  'article',
  'aside',
  'blockquote',
  'dd',
  'div',
  'dl',
  'dt',
  'figcaption',
  'figure',
  'footer',
  'form',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'header',
  'hr',
  'li',
  'main',
  'nav',
  'ol',
  'p',
  'pre',
  'section',
  'table',
  'tr',
  'ul',
};

/// The supported formatting of one character.
final class _Format {
  const _Format({
    this.bold = false,
    this.italic = false,
    this.strike = false,
    this.color,
  });
  final bool bold, italic, strike;
  final String? color;

  _Format copyWith({bool? bold, bool? italic, bool? strike, String? color}) =>
      _Format(
        bold: bold ?? this.bold,
        italic: italic ?? this.italic,
        strike: strike ?? this.strike,
        color: color ?? this.color,
      );

  Map<String, Object?> span(String text) => {
    'text': text,
    if (bold) 'bold': true,
    if (italic) 'italic': true,
    if (strike) 'strikethrough': true,
    if (color != null) 'color': color,
  };

  @override
  bool operator ==(Object o) =>
      o is _Format &&
      o.bold == bold &&
      o.italic == italic &&
      o.strike == strike &&
      o.color == color;

  @override
  int get hashCode => Object.hash(bold, italic, strike, color);
}

/// Text spans in the stored format from clipboard HTML. Line structure is
/// kept as line breaks; the result can be empty.
TextSpans sanitizeHtml(String source) {
  final out = _Builder();
  final document = html_parser.parse(_withoutHeader(source));
  void walk(dom.Node node, _Format format, bool pre) {
    if (node is dom.Text) {
      out.add(node.data, format, pre: pre);
      return;
    }
    if (node is! dom.Element) {
      // Comments and other nodes carry no text.
      return;
    }
    final tag = node.localName ?? '';
    if (_dropped.contains(tag)) return;
    if (tag == 'br') {
      out.add('\n', format, pre: true);
      return;
    }
    final block = _blocks.contains(tag);
    if (block) out.lineBreak();
    var f = switch (tag) {
      'b' || 'strong' => format.copyWith(bold: true),
      'i' || 'em' => format.copyWith(italic: true),
      's' || 'strike' || 'del' => format.copyWith(strike: true),
      _ => format,
    };
    f = _styled(f, node.attributes['style']);
    final inPre = pre || tag == 'pre';
    for (final child in node.nodes) {
      walk(child, f, inPre);
    }
    if (block || tag == 'td' || tag == 'th') {
      if (tag == 'td' || tag == 'th') {
        out.add('\t', format, pre: true);
      } else {
        out.lineBreak();
      }
    }
  }

  final body = document.body;
  if (body != null) walk(body, const _Format(), false);
  return out.spans();
}

/// Text spans in the stored format from clipboard plain text. The text stays
/// as it is, without control characters other than line break and tab.
TextSpans sanitizePlainText(String text) {
  final out = _Builder()..add(text, const _Format(), pre: true);
  return out.spans(tidy: false);
}

/// The HTML of a clipboard text that starts with the Windows `CF_HTML`
/// description (`Version:0.9`, `StartHTML:` and the other offsets), which is
/// not part of the copied content.
String _withoutHeader(String source) {
  if (!source.startsWith('Version:')) return source;
  final start = source.indexOf('<');
  return start < 0 ? '' : source.substring(start);
}

/// The formatting of an inline `style` attribute. Only the four supported
/// properties are read; urls, expressions and other properties are ignored.
_Format _styled(_Format f, String? style) {
  if (style == null) return f;
  var out = f;
  for (final declaration in style.split(';')) {
    final colon = declaration.indexOf(':');
    if (colon < 0) continue;
    final name = declaration.substring(0, colon).trim().toLowerCase();
    final value = declaration.substring(colon + 1).trim().toLowerCase();
    switch (name) {
      case 'font-weight':
        final n = int.tryParse(value);
        out = out.copyWith(
          bold: value == 'bold' || value == 'bolder' || (n != null && n >= 600),
        );
      case 'font-style':
        out = out.copyWith(italic: value == 'italic' || value == 'oblique');
      case 'text-decoration' || 'text-decoration-line':
        if (value.contains('line-through')) out = out.copyWith(strike: true);
      case 'color':
        final color = _color(value);
        if (color != null) out = out.copyWith(color: color);
    }
  }
  return out;
}

final _hex = RegExp(r'^#([0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})$');
final _rgb = RegExp(
  r'^rgba?\(\s*(\d{1,3})\s*[, ]\s*(\d{1,3})\s*[, ]\s*(\d{1,3})\s*(?:[,/]\s*([\d.]+%?)\s*)?\)$',
);

/// A CSS hex or rgb color as #RRGGBBAA, or null for anything else.
String? _color(String value) {
  String two(int v) => v.clamp(0, 255).toRadixString(16).padLeft(2, '0');
  final hex = _hex.firstMatch(value);
  if (hex != null) {
    var digits = hex[1]!;
    if (digits.length <= 4) digits = digits.split('').map((d) => '$d$d').join();
    if (digits.length == 6) digits = '${digits}ff';
    return '#${digits.toUpperCase()}';
  }
  final rgb = _rgb.firstMatch(value);
  if (rgb != null) {
    var alpha = 255;
    if (rgb[4] case final a?) {
      final n = double.tryParse(a.replaceAll('%', ''));
      if (n == null) return null;
      alpha = (a.endsWith('%') ? n / 100 * 255 : n * 255).round();
    }
    return '#${two(int.parse(rgb[1]!))}${two(int.parse(rgb[2]!))}'
            '${two(int.parse(rgb[3]!))}${two(alpha)}'
        .toUpperCase();
  }
  return null;
}

/// Collects characters with their formatting, collapses HTML white space and
/// joins equal neighbors into spans.
final class _Builder {
  final _chars = StringBuffer();
  final _formats = <_Format>[];

  bool get _endsWithBreak {
    final s = _chars.toString();
    return s.isEmpty || s.endsWith('\n');
  }

  void lineBreak() {
    if (!_endsWithBreak) add('\n', const _Format(), pre: true);
  }

  void add(String text, _Format format, {required bool pre}) {
    var t = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (!pre) t = t.replaceAll(RegExp(r'\s+'), ' ');
    for (final rune in t.runes) {
      // Control characters other than line break and tab are not text.
      final control = rune <= 0x1F || (rune >= 0x7F && rune <= 0x9F);
      if (control && rune != 0x0A && rune != 0x09) continue;
      if (rune == 0x20 && !pre) {
        final s = _chars.toString();
        if (s.isEmpty || s.endsWith(' ') || s.endsWith('\n')) continue;
      }
      final char = String.fromCharCode(rune);
      _chars.write(char);
      for (var i = 0; i < char.length; i++) {
        _formats.add(format);
      }
    }
  }

  /// The joined spans. With [tidy] (HTML) spaces and tabs before a line
  /// break go, at most one empty line stays and the ends are trimmed; the
  /// formatting follows the kept characters.
  TextSpans spans({bool tidy = true}) {
    final text = _chars.toString();
    final keep = List.filled(text.length, true);
    var breaks = 0;
    for (var i = 0; i < text.length && tidy; i++) {
      if (text[i] == '\n') {
        breaks++;
        if (breaks > 2) keep[i] = false;
        for (var j = i - 1; j >= 0 && ' \t'.contains(text[j]); j--) {
          keep[j] = false;
        }
      } else if (text[i] != ' ' && text[i] != '\t') {
        breaks = 0;
      }
    }
    var start = 0, end = text.length;
    while (tidy && start < end && ' \n\t'.contains(text[start])) {
      start++;
    }
    while (tidy && end > start && ' \n\t'.contains(text[end - 1])) {
      end--;
    }
    final out = <Map<String, Object?>>[];
    final run = StringBuffer();
    _Format? current;
    for (var i = start; i < end; i++) {
      if (!keep[i]) continue;
      if (current != null && _formats[i] != current) {
        out.add(current.span(run.toString()));
        run.clear();
      }
      current = _formats[i];
      run.write(text[i]);
    }
    if (current != null && run.isNotEmpty) {
      out.add(current.span(run.toString()));
    }
    return out;
  }
}
