import 'dart:io';

/// The gzip bytes of [body], sent with `Content-Encoding: gzip`.
List<int>? gzipBody(List<int> body) => gzip.encode(body);
