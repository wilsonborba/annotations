// annotations#19 part C: sync request bodies are gzip-encoded.
import 'dart:convert';
import 'dart:io';

import 'package:annotations_shared/dal/remote/gzip_body.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a body round-trips through gzip and is smaller', () {
    final body = utf8.encode(jsonEncode(List.filled(2000, {'x': 1, 'y': 2})));
    final packed = gzipBody(body)!;
    expect(packed.length, lessThan(body.length ~/ 10));
    expect(gzip.decode(packed), body);
  });
}
