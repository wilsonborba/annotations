/// What a card shows from its file or link (annotations#34, B9, B3 card
/// choices): the kind of block for a file type, the rows of a CSV table,
/// the page shape of a PDF, a file size for people, and the site of a link.
/// Pure Dart: no file access and no network.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// The block kind that shows a file of media [type] on paper: pictures go
/// straight on the paper, CSV becomes a table, PDF a preview, anything else
/// a file card.
String cardKindFor(String type) {
  final t = type.toLowerCase();
  if (const {
    'image/png',
    'image/jpeg',
    'image/gif',
    'image/webp',
    'image/bmp',
  }.contains(t)) {
    return 'image';
  }
  if (t == 'text/csv') return 'csv_table';
  if (t == 'application/pdf') return 'pdf_preview';
  return 'file_card';
}

/// The media type of a file name by its extension, for files that come
/// without one (drag and drop, the file picker on some systems).
String mediaTypeFor(String name) {
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  return switch (ext) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'bmp' => 'image/bmp',
    'csv' => 'text/csv',
    'pdf' => 'application/pdf',
    'txt' => 'text/plain',
    'doc' => 'application/msword',
    'docx' =>
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls' => 'application/vnd.ms-excel',
    'xlsx' =>
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ppt' => 'application/vnd.ms-powerpoint',
    'pptx' =>
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'zip' => 'application/zip',
    'mp3' => 'audio/mpeg',
    'mp4' => 'video/mp4',
    _ => 'application/octet-stream',
  };
}

/// The short type label of a file card: the extension in capitals, or the
/// media subtype.
String fileTypeLabel(String name, String type) {
  final dot = name.lastIndexOf('.');
  if (dot >= 0 && dot < name.length - 1 && name.length - dot <= 6) {
    return name.substring(dot + 1).toUpperCase();
  }
  final slash = type.indexOf('/');
  return (slash < 0 ? type : type.substring(slash + 1)).toUpperCase();
}

/// A size for people: B, KB, MB or GB with one decimal from KB on.
String formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(1)} ${units[unit]}';
}

/// The rows of a CSV file (RFC 4180: commas, quotes, doubled quotes and
/// line breaks inside quotes). Reading stops after [maxRows] rows; a cell
/// keeps at most [maxCell] characters. A card shows a part and scrolls.
List<List<String>> parseCsv(
  String text, {
  int maxRows = 500,
  int maxCell = 200,
}) {
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var quoted = false;
  void endCell() {
    final value = cell.toString();
    row.add(value.length > maxCell ? value.substring(0, maxCell) : value);
    cell.clear();
  }

  void endRow() {
    endCell();
    rows.add(row);
    row = <String>[];
  }

  for (var i = 0; i < text.length && rows.length < maxRows; i++) {
    final ch = text[i];
    if (quoted) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        cell.write(ch);
      }
    } else if (ch == '"') {
      quoted = true;
    } else if (ch == ',') {
      endCell();
    } else if (ch == '\n' || ch == '\r') {
      if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      endRow();
    } else {
      cell.write(ch);
    }
  }
  if (rows.length < maxRows && (cell.isNotEmpty || row.isNotEmpty)) endRow();
  return rows;
}

/// [parseCsv] of UTF-8 bytes; invalid bytes become replacement characters.
List<List<String>> parseCsvBytes(Uint8List bytes, {int maxRows = 500}) =>
    parseCsv(utf8.decode(bytes, allowMalformed: true), maxRows: maxRows);

/// The first page of a PDF: its size in points (from the first /MediaBox,
/// turned by /Rotate 90 or 270) and the number of pages. Null when the
/// bytes do not look like a PDF. The page itself is not drawn here.
({double width, double height, int pages})? pdfInfo(Uint8List bytes) {
  if (bytes.length < 8) return null;
  final text = latin1.decode(bytes, allowInvalid: true);
  if (!text.startsWith('%PDF-')) return null;
  final box = RegExp(
    r'/MediaBox\s*\[\s*([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s*\]',
  ).firstMatch(text);
  var width = 595.0, height = 842.0;
  if (box != null) {
    final v = [for (var i = 1; i <= 4; i++) double.tryParse(box[i]!) ?? 0];
    final w = (v[2] - v[0]).abs(), h = (v[3] - v[1]).abs();
    if (w > 0 && h > 0) {
      width = w;
      height = h;
    }
  }
  final rotate = RegExp(r'/Rotate\s+(\d+)').firstMatch(text);
  if (rotate != null && (int.parse(rotate[1]!) ~/ 90).isOdd) {
    (width, height) = (height, width);
  }
  final pages = RegExp(r'/Type\s*/Page(?!s)').allMatches(text).length;
  return (width: width, height: height, pages: math.max(pages, 1));
}

/// The site of [url] for a card: the host without "www.".
String siteOf(String url) {
  final host = Uri.tryParse(url)?.host ?? '';
  return host.startsWith('www.') ? host.substring(4) : host;
}

/// Whether [url] is a YouTube video link (a YouTube card). The hosts are
/// the ones the editor rules accept for a YouTube card.
bool isYoutubeUrl(String url) => const {
  'youtube.com',
  'www.youtube.com',
  'm.youtube.com',
  'youtu.be',
}.contains(Uri.tryParse(url)?.host.toLowerCase());

/// [text] as a web link when it is one http or https URL and nothing else,
/// or null.
String? webLink(String text) {
  final t = text.trim();
  if (t.isEmpty || t.contains(RegExp(r'\s'))) return null;
  final uri = Uri.tryParse(t);
  if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
    return null;
  }
  if (uri.host.isEmpty || !uri.host.contains('.') || uri.userInfo.isNotEmpty) {
    return null;
  }
  return t;
}
