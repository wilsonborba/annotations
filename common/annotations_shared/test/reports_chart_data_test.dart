import 'dart:convert';
import 'dart:typed_data';

import 'package:annotations_shared/domain/services/reports_chart_data.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reuses the CSV parser and preserves typed values and row order', () {
    final table = ReportsChartSourceTable.parse(
      fileId: 'csv-1',
      name: 'sales.csv',
      bytes: Uint8List.fromList(
        utf8.encode('month,sales,area\nJan,12,west\nFeb,14,east\n'),
      ),
    );
    expect(table.name, 'sales.csv');
    expect(table.columns.map((column) => (column.name, column.type)), [
      ('month', 'string'),
      ('sales', 'integer'),
      ('area', 'string'),
    ]);
    expect(table.rows, [
      {'month': 'Jan', 'sales': 12, 'area': 'west'},
      {'month': 'Feb', 'sales': 14, 'area': 'east'},
    ]);
  });

  test('rejects duplicate or empty headers and oversized row sets', () {
    ReportsChartSourceTable parse(String value) =>
        ReportsChartSourceTable.parse(
          fileId: 'csv-1',
          name: 'bad.csv',
          bytes: Uint8List.fromList(utf8.encode(value)),
        );
    expect(() => parse('name,name\na,b\n'), throwsFormatException);
    expect(() => parse('name,\na,b\n'), throwsFormatException);
    final oversized = StringBuffer('value\n');
    for (var i = 0; i < 1001; i++) {
      oversized.writeln(i);
    }
    expect(() => parse(oversized.toString()), throwsFormatException);
  });

  test('validates the parsed payload byte and row limits', () {
    expect(
      () => validateReportsChartPayload(
        mapping: const {'value': 'amount'},
        rows: [
          for (var i = 0; i < 1001; i++) {'amount': i},
        ],
      ),
      throwsFormatException,
    );
    expect(
      () => validateReportsChartPayload(
        mapping: const {'value': 'amount'},
        rows: [
          {'amount': List.filled(1_048_576, 'x').join()},
        ],
      ),
      throwsFormatException,
    );
  });
}
