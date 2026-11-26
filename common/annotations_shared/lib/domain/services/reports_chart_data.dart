import 'dart:convert';
import 'dart:typed_data';

import 'card_content.dart' show parseCsvBytes;

/// A CSV or selected worksheet already attached to the local note, normalized
/// for a user-selected Reports template. No source bytes are sent until the
/// user creates a chart.
final class ReportsChartSourceTable {
  const ReportsChartSourceTable({
    required this.fileId,
    required this.name,
    required this.columns,
    required this.rows,
    String? selectionId,
  }) : selectionId = selectionId ?? fileId;

  final String fileId;

  /// Dialog identity. Multi-sheet workbooks can expose multiple tables from
  /// the same managed attachment, so this is distinct from [fileId].
  final String selectionId;
  final String name;
  final List<ReportsChartSourceColumn> columns;
  final List<Map<String, Object?>> rows;

  static ReportsChartSourceTable parse({
    required String fileId,
    required String name,
    required Uint8List bytes,
  }) {
    if (bytes.isEmpty || bytes.length > 1_048_576) {
      throw const FormatException('The selected table is empty or too large.');
    }
    final parsed = parseCsvBytes(bytes, maxRows: 1002);
    if (parsed.length < 2 || parsed.length > 1001) {
      throw const FormatException(
        'The selected table must contain a header and at most 1000 data rows.',
      );
    }
    final headers = parsed.first.map((value) => value.trim()).toList();
    if (headers.isEmpty || headers.any((header) => header.isEmpty)) {
      throw const FormatException('Every table column needs a name.');
    }
    final unique = <String>{};
    for (final header in headers) {
      if (!unique.add(header)) {
        throw const FormatException('Table column names must be unique.');
      }
    }
    final dataRows = parsed
        .skip(1)
        .where((row) => row.any((v) => v.trim().isNotEmpty));
    final rawRows = dataRows.toList(growable: false);
    if (rawRows.isEmpty || rawRows.length > 1000) {
      throw const FormatException(
        'The selected table must contain 1 to 1000 data rows.',
      );
    }
    if (rawRows.any((row) => row.length > headers.length)) {
      throw const FormatException(
        'A table row has more values than its header.',
      );
    }

    final columns = <ReportsChartSourceColumn>[];
    for (var index = 0; index < headers.length; index++) {
      final values = rawRows
          .map((row) => index < row.length ? row[index].trim() : '')
          .where((value) => value.isNotEmpty)
          .toList(growable: false);
      // Reports owner datasets infer each field type from row one. A blank
      // first cell therefore stays a string column even if later cells parse
      // as numbers; exposing it as numeric here would create a mismatched
      // chart mapping.
      final firstCell = rawRows.first.length > index
          ? rawRows.first[index].trim()
          : '';
      final allIntegers =
          firstCell.isNotEmpty &&
          values.isNotEmpty &&
          values.every((value) => int.tryParse(value) != null);
      final allNumbers =
          firstCell.isNotEmpty &&
          values.isNotEmpty &&
          values.every((value) => num.tryParse(value) != null);
      final type = allIntegers ? 'integer' : (allNumbers ? 'float' : 'string');
      columns.add(ReportsChartSourceColumn(name: headers[index], type: type));
    }

    final rows = <Map<String, Object?>>[];
    for (final raw in rawRows) {
      final values = <String, Object?>{};
      for (var index = 0; index < headers.length; index++) {
        final rawValue = index < raw.length ? raw[index] : '';
        final trimmed = rawValue.trim();
        if (trimmed.isEmpty) {
          values[headers[index]] = null;
        } else {
          final type = columns[index].type;
          values[headers[index]] = switch (type) {
            'integer' => int.parse(trimmed),
            'float' => double.parse(trimmed),
            _ => rawValue,
          };
        }
      }
      rows.add(values);
    }
    return ReportsChartSourceTable(
      fileId: fileId,
      name: name,
      selectionId: fileId,
      columns: List.unmodifiable(columns),
      rows: List.unmodifiable(rows),
    );
  }
}

final class ReportsChartSourceColumn {
  const ReportsChartSourceColumn({required this.name, required this.type});

  final String name;
  final String type;
}

/// Applies the NotesAPI/Reports bounded parsed-payload limits before a request
/// can be submitted.
void validateReportsChartPayload({
  required Map<String, String> mapping,
  required List<Map<String, Object?>> rows,
}) {
  if (mapping.isEmpty ||
      mapping.entries.any(
        (entry) => entry.key.trim().isEmpty || entry.value.trim().isEmpty,
      )) {
    throw const FormatException(
      'Choose a source column for each required slot.',
    );
  }
  if (rows.isEmpty || rows.length > 1000) {
    throw const FormatException('The chart needs 1 to 1000 table rows.');
  }
  final byteCount = utf8
      .encode(jsonEncode({'mapping': mapping, 'rows': rows}))
      .length;
  if (byteCount > 1_048_576) {
    throw const FormatException(
      'The selected table exceeds the 1 MiB chart limit.',
    );
  }
}
