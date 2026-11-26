import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'reports_chart_data.dart';

/// Bounded, read-only import of worksheet values from an OOXML workbook.
/// Formulas are never evaluated; only their cached result is considered.
final class ReportsXlsxData {
  static const maxWorkbookBytes = 5 * 1024 * 1024;
  static const maxEntries = 128;
  static const maxEntryBytes = 4 * 1024 * 1024;
  static const maxTotalExpandedBytes = 12 * 1024 * 1024;
  static const maxRows = 1001; // header plus 1000 data rows
  static const maxColumns = 64;

  static List<ReportsChartSourceTable> parse({
    required String fileId,
    required String name,
    required Uint8List bytes,
  }) {
    if (bytes.isEmpty || bytes.length > maxWorkbookBytes) {
      throw const FormatException(
        'The selected workbook is empty or too large.',
      );
    }
    final entries = _validateZipDirectory(bytes);
    final archive = ZipDecoder().decodeBytes(bytes);
    final parts = <String, Uint8List>{};
    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      final metadata = entries[entry.name];
      if (metadata == null) {
        throw const FormatException('The workbook package is malformed.');
      }
      if (!_neededPart(entry.name)) continue;
      final raw = entry.rawContent;
      if (raw == null) continue;
      final output = _LimitedOutputStream(maxEntryBytes);
      try {
        raw.decompress(output);
      } on Object {
        throw const FormatException(
          'A workbook part could not be decompressed.',
        );
      }
      final content = output.getBytes();
      if (output.length != metadata.uncompressedSize ||
          getCrc32(content) != metadata.crc32) {
        throw const FormatException(
          'A workbook part failed its integrity check.',
        );
      }
      parts[entry.name] = content;
    }

    final workbook = _document(parts['xl/workbook.xml']);
    final relationships = _document(parts['xl/_rels/workbook.xml.rels']);
    final relTargets = <String, String>{};
    for (final rel in relationships.findAllElements(
      'Relationship',
      namespace: '*',
    )) {
      final id = rel.getAttribute('Id');
      final target = rel.getAttribute('Target');
      if (id == null || target == null) continue;
      if (rel.getAttribute('TargetMode') == 'External') {
        throw const FormatException(
          'External workbook references are unsupported.',
        );
      }
      if (!(rel.getAttribute('Type') ?? '').endsWith('/worksheet')) continue;
      if (relTargets.containsKey(id)) {
        throw const FormatException(
          'The workbook has duplicate relationships.',
        );
      }
      relTargets[id] = _worksheetPath(target);
    }

    final sharedStrings = _readSharedStrings(parts['xl/sharedStrings.xml']);
    final dateStyles = _dateStyles(parts['xl/styles.xml']);
    final tables = <ReportsChartSourceTable>[];
    final visibleSheetNames = <String>{};
    for (final sheet in workbook.findAllElements('sheet', namespace: '*')) {
      final state = sheet.getAttribute('state');
      if (state != null && state != 'visible') continue;
      final sheetName = sheet.getAttribute('name')?.trim();
      final relId = sheet.attributes
          .where((attribute) => attribute.name.local == 'id')
          .map((attribute) => attribute.value)
          .firstOrNull;
      if (sheetName == null || sheetName.isEmpty || relId == null) {
        throw const FormatException('A workbook sheet reference is invalid.');
      }
      if (!visibleSheetNames.add(sheetName.toLowerCase())) {
        throw const FormatException('The workbook has duplicate sheet names.');
      }
      final path = relTargets[relId];
      if (path == null) {
        throw const FormatException('A workbook sheet is missing.');
      }
      final matrix = _readSheet(
        _document(parts[path]),
        sharedStrings: sharedStrings,
        dateStyles: dateStyles,
      );
      if (matrix.isEmpty) continue;
      final table = _toTable(
        fileId: fileId,
        name: name,
        sheetName: sheetName,
        matrix: matrix,
      );
      if (table != null) tables.add(table);
    }
    if (tables.isEmpty) {
      throw const FormatException('The workbook has no visible data table.');
    }
    return List.unmodifiable(tables);
  }

  static bool _neededPart(String name) =>
      name == 'xl/workbook.xml' ||
      name == 'xl/_rels/workbook.xml.rels' ||
      name == 'xl/sharedStrings.xml' ||
      name == 'xl/styles.xml' ||
      (name.startsWith('xl/worksheets/') && name.endsWith('.xml'));

  static XmlDocument _document(Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty) {
      throw const FormatException(
        'The workbook is missing a required XML part.',
      );
    }
    final text = utf8.decode(bytes, allowMalformed: false);
    if (text.contains('<!DOCTYPE') || text.contains('<!ENTITY')) {
      throw const FormatException('Workbook XML declarations are unsupported.');
    }
    try {
      return XmlDocument.parse(text);
    } on Object {
      throw const FormatException('The workbook contains invalid XML.');
    }
  }

  static String _worksheetPath(String target) {
    final normalized = target.startsWith('/')
        ? target.substring(1)
        : 'xl/$target';
    final parts = <String>[];
    for (final segment in normalized.split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..' || segment.contains('\\')) {
        throw const FormatException('A workbook sheet path is invalid.');
      }
      parts.add(segment);
    }
    final path = parts.join('/');
    if (!path.startsWith('xl/worksheets/') || !path.endsWith('.xml')) {
      throw const FormatException('A workbook sheet path is unsupported.');
    }
    return path;
  }

  static List<String> _readSharedStrings(Uint8List? bytes) {
    if (bytes == null) return const [];
    final doc = _document(bytes);
    return doc
        .findAllElements('si', namespace: '*')
        .map(_richText)
        .toList(growable: false);
  }

  static String _richText(XmlElement parent) {
    final text = StringBuffer();
    for (final child in parent.childElements) {
      if (child.name.local == 't') {
        text.write(child.innerText);
      } else if (child.name.local == 'r') {
        for (final runText in child.findElements('t', namespace: '*')) {
          text.write(runText.innerText);
        }
      }
    }
    return text.toString();
  }

  static ({Set<int> dateStyleIds, int styleCount}) _dateStyles(
    Uint8List? bytes,
  ) {
    if (bytes == null) return (dateStyleIds: const {}, styleCount: 1);
    final doc = _document(bytes);
    final dateFormats = <int>{
      14,
      15,
      16,
      17,
      18,
      19,
      20,
      21,
      22,
      27,
      28,
      29,
      30,
      31,
      32,
      33,
      34,
      35,
      36,
      45,
      46,
      47,
      50,
      51,
      52,
      53,
      54,
      55,
      56,
      57,
      58,
    };
    for (final format in doc.findAllElements('numFmt', namespace: '*')) {
      final id = int.tryParse(format.getAttribute('numFmtId') ?? '');
      final code = format.getAttribute('formatCode');
      if (id == null || code == null) continue;
      final unescaped = code
          .replaceAll(RegExp(r'"[^"]*"'), '')
          .replaceAll(RegExp(r'\\.'), '')
          .replaceAll(RegExp(r'\[[^\]]*\]'), '')
          .toLowerCase();
      if (RegExp(r'[ymdhs]').hasMatch(unescaped)) {
        dateFormats.add(id);
      }
    }
    final styles = doc.findAllElements('cellXfs', namespace: '*').firstOrNull;
    if (styles == null) {
      throw const FormatException('The workbook style table is malformed.');
    }
    final result = <int>{};
    var index = 0;
    for (final style in styles.findElements('xf', namespace: '*')) {
      final formatId = int.tryParse(style.getAttribute('numFmtId') ?? '0') ?? 0;
      if (dateFormats.contains(formatId)) result.add(index);
      index++;
    }
    return (dateStyleIds: result, styleCount: index);
  }

  static List<List<Object?>> _readSheet(
    XmlDocument doc, {
    required List<String> sharedStrings,
    required ({Set<int> dateStyleIds, int styleCount}) dateStyles,
  }) {
    if (doc.findAllElements('mergeCell', namespace: '*').isNotEmpty) {
      throw const FormatException(
        'Merged worksheet cells need to be unmerged before chart import.',
      );
    }
    final rows = <int, Map<int, Object?>>{};
    final seenRows = <int>{};
    var implicitRow = 0;
    for (final row in doc.findAllElements('row', namespace: '*')) {
      final rowIndex =
          int.tryParse(row.getAttribute('r') ?? '') ?? ++implicitRow;
      implicitRow = rowIndex;
      if (rowIndex < 1 || rowIndex > maxRows) {
        throw const FormatException(
          'A worksheet exceeds the 1000-row chart limit.',
        );
      }
      if (!seenRows.add(rowIndex)) {
        throw const FormatException('A worksheet contains a duplicate row.');
      }
      final values = <int, Object?>{};
      var implicitColumn = 0;
      for (final cell in row.findElements('c', namespace: '*')) {
        final address = cell.getAttribute('r');
        final column = address == null
            ? ++implicitColumn
            : _columnNumber(address);
        if (address != null &&
            int.parse(RegExp(r'[1-9][0-9]*$').firstMatch(address)!.group(0)!) !=
                rowIndex) {
          throw const FormatException(
            'A worksheet cell is outside its declared row.',
          );
        }
        if (column < 1 || column > maxColumns) {
          throw const FormatException(
            'A worksheet exceeds the 64-column chart limit.',
          );
        }
        if (values.containsKey(column)) {
          throw const FormatException('A worksheet contains a duplicate cell.');
        }
        implicitColumn = column;
        final type = cell.getAttribute('t');
        final style = int.tryParse(cell.getAttribute('s') ?? '0');
        if (style == null || style < 0) {
          throw const FormatException('A worksheet cell style is invalid.');
        }
        if (style >= dateStyles.styleCount) {
          throw const FormatException(
            'A worksheet cell references an unknown style.',
          );
        }
        final formula = cell.findElements('f', namespace: '*').firstOrNull;
        final valueNode = cell.findElements('v', namespace: '*').firstOrNull;
        if (formula != null &&
            (valueNode == null ||
                (valueNode.innerText.isEmpty && type != 'str'))) {
          throw const FormatException('A formula is missing its saved result.');
        }
        final inlineText = cell
            .findElements('is', namespace: '*')
            .map(_richText)
            .join();
        final raw = valueNode?.innerText ?? '';
        Object? value;
        if (type == 'inlineStr') {
          value = inlineText;
        } else if (type == 'e') {
          throw const FormatException('Error cells cannot be chart data.');
        } else if (type == 'str') {
          value = raw.isEmpty ? null : raw;
        } else if (raw.isEmpty) {
          value = null;
        } else if (type == 's') {
          final index = int.tryParse(raw);
          if (index == null || index < 0 || index >= sharedStrings.length) {
            throw const FormatException('A shared-string cell is invalid.');
          }
          value = sharedStrings[index];
        } else if (type == 'b') {
          if (raw != '0' && raw != '1') {
            throw const FormatException('A boolean cell is invalid.');
          }
          value = raw == '1';
        } else if (type == 'd') {
          value = raw;
        } else if (type == null || type == 'n') {
          if (dateStyles.dateStyleIds.contains(style)) {
            throw const FormatException(
              'Date-formatted numbers must be converted to ISO dates before chart import.',
            );
          }
          final number = num.tryParse(raw);
          if (number == null || !number.isFinite) {
            throw const FormatException(
              'A worksheet contains an invalid number.',
            );
          }
          value = number is int ? number : number.toDouble();
        } else {
          throw const FormatException('A worksheet cell type is unsupported.');
        }
        values[column] = value;
      }
      if (values.values.any(
        (value) => value != null && value.toString().isNotEmpty,
      )) {
        rows[rowIndex] = values;
      }
    }
    if (rows.isEmpty) return const [];
    final maxColumn = rows.values
        .expand((row) => row.keys)
        .fold<int>(0, (max, column) => column > max ? column : max);
    final maxRow = rows.keys.reduce((a, b) => a > b ? a : b);
    return List.generate(maxRow, (rowIndex) {
      final row = rows[rowIndex + 1] ?? const <int, Object?>{};
      return List.generate(maxColumn, (columnIndex) => row[columnIndex + 1]);
    }, growable: false);
  }

  static int _columnNumber(String address) {
    final match = RegExp(
      r'^([A-Z]+)[1-9][0-9]*$',
    ).firstMatch(address.toUpperCase());
    if (match == null) {
      throw const FormatException('A worksheet cell address is invalid.');
    }
    var result = 0;
    for (final code in match.group(1)!.codeUnits) {
      result = result * 26 + code - 64;
    }
    return result;
  }

  static ReportsChartSourceTable? _toTable({
    required String fileId,
    required String name,
    required String sheetName,
    required List<List<Object?>> matrix,
  }) {
    final first = matrix.first;
    final headers = first
        .map((value) => value?.toString().trim() ?? '')
        .toList();
    while (headers.isNotEmpty && headers.last.isEmpty) {
      headers.removeLast();
    }
    if (headers.isEmpty || headers.any((header) => header.isEmpty)) {
      throw const FormatException('Every worksheet column needs a header.');
    }
    if (headers.length > maxColumns ||
        headers.toSet().length != headers.length) {
      throw const FormatException(
        'Worksheet column names must be unique and within the column limit.',
      );
    }
    final sourceRows = matrix
        .skip(1)
        .map((row) {
          return List<Object?>.generate(
            headers.length,
            (index) => index < row.length ? row[index] : null,
          );
        })
        .where(
          (row) => row.any(
            (value) => value != null && value.toString().trim().isNotEmpty,
          ),
        )
        .toList();
    if (sourceRows.isEmpty) return null;
    if (sourceRows.length > 1000) {
      throw const FormatException('A worksheet needs 1 to 1000 data rows.');
    }

    if (matrix
        .skip(1)
        .any(
          (row) => row
              .skip(headers.length)
              .any(
                (value) => value != null && value.toString().trim().isNotEmpty,
              ),
        )) {
      throw const FormatException(
        'A worksheet has data outside its header columns.',
      );
    }

    final columns = <ReportsChartSourceColumn>[];
    final rows = <Map<String, Object?>>[];
    for (var column = 0; column < headers.length; column++) {
      final firstValue = sourceRows.first[column];
      final values = sourceRows.map((row) => row[column]).toList();
      final numeric = values.whereType<num>().toList();
      final isInteger =
          firstValue is int && values.every((v) => v == null || v is int);
      final isNumber =
          firstValue is num && values.every((v) => v == null || v is num);
      final isBoolean =
          firstValue is bool && values.every((v) => v == null || v is bool);
      final type = firstValue == null
          ? 'string'
          : isInteger
          ? 'integer'
          : isNumber
          ? (numeric.every((value) => value is int) ? 'integer' : 'float')
          : isBoolean
          ? 'boolean'
          : 'string';
      columns.add(ReportsChartSourceColumn(name: headers[column], type: type));
    }
    for (final sourceRow in sourceRows) {
      final row = <String, Object?>{};
      for (var column = 0; column < headers.length; column++) {
        final value = sourceRow[column];
        final type = columns[column].type;
        row[headers[column]] = value == null
            ? null
            : switch (type) {
                'integer' => (value as num).toInt(),
                'float' => (value as num).toDouble(),
                'boolean' => value as bool,
                _ => value.toString(),
              };
      }
      rows.add(Map.unmodifiable(row));
    }
    final table = ReportsChartSourceTable(
      fileId: fileId,
      selectionId: '$fileId::$sheetName',
      name: '$name · $sheetName',
      columns: List.unmodifiable(columns),
      rows: List.unmodifiable(rows),
    );
    validateReportsChartPayload(mapping: const {'x': 'x'}, rows: table.rows);
    return table;
  }

  static final _eocd = [0x50, 0x4b, 0x05, 0x06];
  static final _central = [0x50, 0x4b, 0x01, 0x02];
  static final _local = [0x50, 0x4b, 0x03, 0x04];

  static Map<String, _ZipMetadata> _validateZipDirectory(Uint8List bytes) {
    int u16(int offset) => bytes[offset] | (bytes[offset + 1] << 8);
    int u32(int offset) => u16(offset) | (u16(offset + 2) << 16);
    bool sig(int offset, List<int> value) =>
        offset >= 0 &&
        offset + 4 <= bytes.length &&
        bytes[offset] == value[0] &&
        bytes[offset + 1] == value[1] &&
        bytes[offset + 2] == value[2] &&
        bytes[offset + 3] == value[3];

    final minEocd = bytes.length - 22 - 0xffff;
    var eocd = -1;
    for (
      var offset = bytes.length - 22;
      offset >= minEocd && offset >= 0;
      offset--
    ) {
      if (sig(offset, _eocd)) {
        final commentLength = u16(offset + 20);
        if (offset + 22 + commentLength == bytes.length) {
          eocd = offset;
          break;
        }
      }
    }
    if (eocd < 0) {
      throw const FormatException(
        'The selected file is not a supported ZIP workbook.',
      );
    }
    final disk = u16(eocd + 4);
    final centralDisk = u16(eocd + 6);
    final diskCount = u16(eocd + 8);
    final count = u16(eocd + 10);
    final centralSize = u32(eocd + 12);
    final centralOffset = u32(eocd + 16);
    if (disk != 0 ||
        centralDisk != 0 ||
        diskCount != count ||
        count == 0 ||
        count > maxEntries ||
        count == 0xffff ||
        centralOffset == 0xffffffff ||
        centralSize == 0xffffffff ||
        centralOffset + centralSize != eocd) {
      throw const FormatException(
        'The workbook ZIP directory is unsupported or too large.',
      );
    }
    final result = <String, _ZipMetadata>{};
    final entryNames = <String>{};
    final localRanges = <(int start, int end)>[];
    var cursor = centralOffset;
    var totalExpanded = 0;
    for (var index = 0; index < count; index++) {
      if (!sig(cursor, _central) || cursor + 46 > eocd) {
        throw const FormatException('The workbook ZIP directory is malformed.');
      }
      final flags = u16(cursor + 8);
      final compression = u16(cursor + 10);
      final crc = u32(cursor + 16);
      final compressed = u32(cursor + 20);
      final uncompressed = u32(cursor + 24);
      final nameLength = u16(cursor + 28);
      final extraLength = u16(cursor + 30);
      final commentLength = u16(cursor + 32);
      final diskNumber = u16(cursor + 34);
      final externalAttributes = u32(cursor + 38);
      final localOffset = u32(cursor + 42);
      final end = cursor + 46 + nameLength + extraLength + commentLength;
      if (end > eocd ||
          diskNumber != 0 ||
          nameLength == 0 ||
          compressed == 0xffffffff ||
          uncompressed == 0xffffffff ||
          localOffset == 0xffffffff ||
          (flags & (1 | 0x40 | 0x2000)) != 0 ||
          (flags & ~(0x0006 | 0x0008 | 0x0800)) != 0 ||
          (compression != 0 && compression != 8)) {
        throw const FormatException(
          'The workbook contains an unsupported ZIP entry.',
        );
      }
      final name = utf8.decode(
        bytes.sublist(cursor + 46, cursor + 46 + nameLength),
        allowMalformed: false,
      );
      final segments = name.split('/');
      final isDirectory = name.endsWith('/');
      if (name.startsWith('/') ||
          name.contains('\\') ||
          segments.any((segment) => segment == '..') ||
          (!isDirectory && segments.any((segment) => segment.isEmpty)) ||
          !entryNames.add(name)) {
        throw const FormatException(
          'The workbook contains an unsafe or duplicate path.',
        );
      }
      final unixMode = externalAttributes >> 16;
      if ((unixMode & 0xf000) == 0xa000) {
        throw const FormatException(
          'Symbolic links are unsupported in workbooks.',
        );
      }
      if (uncompressed > maxEntryBytes || compressed > maxWorkbookBytes) {
        throw const FormatException(
          'A workbook ZIP entry exceeds the size limit.',
        );
      }
      totalExpanded += uncompressed;
      if (totalExpanded > maxTotalExpandedBytes) {
        throw const FormatException(
          'The workbook expands beyond the package size limit.',
        );
      }
      if (!isDirectory) {
        if (!sig(localOffset, _local) || localOffset + 30 > centralOffset) {
          throw const FormatException(
            'A workbook ZIP entry has an invalid local header.',
          );
        }
        final localNameLength = u16(localOffset + 26);
        final localExtraLength = u16(localOffset + 28);
        final localFlags = u16(localOffset + 6);
        final localCompression = u16(localOffset + 8);
        final localCrc = u32(localOffset + 14);
        final localCompressed = u32(localOffset + 18);
        final localUncompressed = u32(localOffset + 22);
        final dataStart = localOffset + 30 + localNameLength + localExtraLength;
        if (localFlags != flags ||
            localCompression != compression ||
            dataStart + compressed > centralOffset ||
            ((flags & 0x0008) == 0 &&
                (localCrc != crc ||
                    localCompressed != compressed ||
                    localUncompressed != uncompressed)) ||
            utf8.decode(
                  bytes.sublist(
                    localOffset + 30,
                    localOffset + 30 + localNameLength,
                  ),
                  allowMalformed: false,
                ) !=
                name) {
          throw const FormatException(
            'A workbook ZIP entry has inconsistent headers.',
          );
        }
        localRanges.add((localOffset, dataStart + compressed));
        result[name] = _ZipMetadata(uncompressedSize: uncompressed, crc32: crc);
      }
      cursor = end;
    }
    localRanges.sort((a, b) => a.$1.compareTo(b.$1));
    for (var index = 1; index < localRanges.length; index++) {
      if (localRanges[index].$1 < localRanges[index - 1].$2) {
        throw const FormatException('Workbook ZIP entries overlap.');
      }
    }
    if (cursor != centralOffset + centralSize ||
        !result.containsKey('xl/workbook.xml') ||
        !result.containsKey('xl/_rels/workbook.xml.rels')) {
      throw const FormatException('The workbook ZIP directory is incomplete.');
    }
    return result;
  }
}

final class _ZipMetadata {
  const _ZipMetadata({required this.uncompressedSize, required this.crc32});
  final int uncompressedSize;
  final int crc32;
}

final class _LimitedOutputStream extends OutputStream {
  _LimitedOutputStream(this.limit) : super(byteOrder: ByteOrder.littleEndian);
  final int limit;
  final _bytes = BytesBuilder(copy: false);
  var _length = 0;

  @override
  int get length => _length;
  @override
  void clear() {
    _bytes.clear();
    _length = 0;
  }

  @override
  void flush() {}
  @override
  void writeByte(int value) => writeBytes([value]);
  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    if (count < 0 || count > bytes.length || _length + count > limit) {
      throw const FormatException(
        'A workbook part exceeds the decompression limit.',
      );
    }
    _bytes.add(bytes.take(count).toList(growable: false));
    _length += count;
  }

  @override
  void writeStream(InputStream stream) {
    while (!stream.isEOS) {
      final byte = stream.readByte();
      if (byte < 0) break;
      writeByte(byte);
    }
  }

  @override
  Uint8List subset(int start, [int? end]) =>
      Uint8List.fromList(getBytes().sublist(start, end));
  @override
  Uint8List getBytes() => _bytes.toBytes();
}
