import 'dart:convert';
import 'dart:typed_data';

import 'package:annotations_shared/domain/services/reports_chart_data.dart';
import 'package:annotations_shared/domain/services/reports_xlsx_data.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'imports shared and inline values, cached formulas, booleans and sheets',
    () {
      final tables = ReportsXlsxData.parse(
        fileId: 'managed-xlsx',
        name: 'sales.xlsx',
        bytes: _book(
          sheets: {
            'xl/worksheets/sheet1.xml': '''
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
 <sheetData>
  <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="inlineStr"><is><t>Revenue</t></is></c><c r="C1" t="inlineStr"><is><t>Enabled</t></is></c></row>
  <row r="2"><c r="A2" t="inlineStr"><is><t>North</t></is></c><c r="B2"><f>40+2</f><v>42</v></c><c r="C2" t="b"><v>1</v></c></row>
 </sheetData>
</worksheet>''',
            'xl/worksheets/sheet2.xml': '''
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
 <sheetData>
  <row r="1"><c r="A1" t="inlineStr"><is><t>Item</t></is></c><c r="B1" t="inlineStr"><is><t>Count</t></is></c></row>
  <row r="2"><c r="A2" t="inlineStr"><is><t>Pen</t></is></c><c r="B2"><v>3</v></c></row>
 </sheetData>
</worksheet>''',
          },
          sharedStrings:
              '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><si><t>Region</t></si></sst>',
        ),
      );

      expect(tables, hasLength(2));
      expect(tables.map((table) => table.selectionId).toSet(), hasLength(2));
      expect(tables[0].name, 'sales.xlsx · Summary');
      expect(tables[0].columns.map((column) => column.type), [
        'string',
        'integer',
        'boolean',
      ]);
      expect(tables[0].rows.single, {
        'Region': 'North',
        'Revenue': 42,
        'Enabled': true,
      });
      expect(tables[1].rows.single, {'Item': 'Pen', 'Count': 3});

      final mapping = {'x': 'Region', 'y': 'Revenue'};
      expect(
        () =>
            validateReportsChartPayload(mapping: mapping, rows: tables[0].rows),
        returnsNormally,
      );
    },
  );

  test(
    'rejects formulas without cached values, error cells and merged ranges',
    () {
      for (final sheet in [
        _sheet(
          '<c r="A1" t="inlineStr"><is><t>X</t></is></c><c r="B1" t="inlineStr"><is><t>Y</t></is></c>',
          '<c r="A2"><f>1+1</f></c><c r="B2"><v>2</v></c>',
        ),
        _sheet(
          '<c r="A1" t="inlineStr"><is><t>X</t></is></c>',
          '<c r="A2"><f>1+1</f><v></v></c>',
        ),
        _sheet(
          '<c r="A1" t="inlineStr"><is><t>X</t></is></c>',
          '<c r="A2" t="e"><v>#N/A</v></c>',
        ),
        _sheet(
          '<c r="A1" t="inlineStr"><is><t>X</t></is></c>',
          '<c r="A2"><v>2</v></c>',
          merge: '<mergeCells><mergeCell ref="A1:A2"/></mergeCells>',
        ),
      ]) {
        expect(() => _parseOne(sheet), throwsA(isA<FormatException>()));
      }
    },
  );

  test(
    'rejects styled numeric dates instead of treating serials as measures',
    () {
      final bytes = _book(
        sheets: {
          'xl/worksheets/sheet1.xml': _sheet(
            '<c r="A1" t="inlineStr"><is><t>Date</t></is></c>',
            '<c r="A2" s="1"><v>45292</v></c>',
          ),
        },
        styles:
            '''<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><cellXfs count="2"><xf numFmtId="0"/><xf numFmtId="14"/></cellXfs></styleSheet>''',
      );
      expect(
        () =>
            ReportsXlsxData.parse(fileId: 'f', name: 'date.xlsx', bytes: bytes),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test('rejects malformed ZIP and row or column overflow', () {
    expect(
      () => ReportsXlsxData.parse(
        fileId: 'f',
        name: 'bad.xlsx',
        bytes: Uint8List.fromList([1, 2, 3]),
      ),
      throwsA(isA<FormatException>()),
    );
    final tooManyRows = List.generate(
      1002,
      (index) =>
          '<row r="${index + 1}"><c r="A${index + 1}" t="inlineStr"><is><t>${index == 0 ? 'H' : 'V'}</t></is></c></row>',
    ).join();
    expect(
      () => _parseOne(_sheetRaw(tooManyRows)),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => _parseOne(
        _sheet(
          '<c r="BM1" t="inlineStr"><is><t>Too far</t></is></c>',
          '<c r="BM2"><v>1</v></c>',
        ),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects an oversized expanded ZIP entry before retaining it', () {
    final bytes = _book(
      sheets: {
        'xl/worksheets/sheet1.xml': _sheet(
          '<c r="A1" t="inlineStr"><is><t>H</t></is></c>',
          '<c r="A2" t="inlineStr"><is><t>V</t></is></c>',
        ),
      },
      extraParts: {
        'xl/media/unused.bin': String.fromCharCodes(
          List.filled(4 * 1024 * 1024 + 1, 120),
        ),
      },
    );
    expect(bytes.length, lessThan(ReportsXlsxData.maxWorkbookBytes));
    expect(
      () =>
          ReportsXlsxData.parse(fileId: 'f', name: 'large.xlsx', bytes: bytes),
      throwsA(isA<FormatException>()),
    );
  });
}

List<ReportsChartSourceTable> _parseOne(String worksheet) =>
    ReportsXlsxData.parse(
      fileId: 'f',
      name: 'table.xlsx',
      bytes: _book(sheets: {'xl/worksheets/sheet1.xml': worksheet}),
    );

String _sheet(String headerCells, String dataCells, {String merge = ''}) =>
    _sheetRaw('''
<sheetData><row r="1">$headerCells</row><row r="2">$dataCells</row></sheetData>
$merge''');

String _sheetRaw(String inner) => '''
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">$inner</worksheet>''';

Uint8List _book({
  required Map<String, String> sheets,
  String? sharedStrings,
  String? styles,
  Map<String, String> extraParts = const {},
}) {
  final archive = Archive();
  void add(String name, String value) =>
      archive.addFile(ArchiveFile.bytes(name, utf8.encode(value)));
  add('xl/workbook.xml', '''
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
 <sheets>${[for (var i = 0; i < sheets.length; i++) '<sheet name="${i == 0 ? 'Summary' : 'Details'}" sheetId="${i + 1}" r:id="rId${i + 1}"/>'].join()}</sheets>
</workbook>''');
  add('xl/_rels/workbook.xml.rels', '''
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
${[for (var i = 0; i < sheets.length; i++) '<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i + 1}.xml"/>'].join()}
</Relationships>''');
  for (final entry in sheets.entries) {
    add(entry.key, entry.value);
  }
  if (sharedStrings != null) add('xl/sharedStrings.xml', sharedStrings);
  if (styles != null) add('xl/styles.xml', styles);
  for (final entry in extraParts.entries) {
    add(entry.key, entry.value);
  }
  return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
}
