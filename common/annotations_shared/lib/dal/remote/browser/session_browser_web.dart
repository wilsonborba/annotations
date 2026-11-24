import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

/// Browser session helpers (annotations#38). The gateway session cookie
/// `sid` is httpOnly; the app reads only the `csrf` cookie, and only to
/// send it back as a header and to know a session may exist.

String? readCookie(String name) {
  for (final part in web.document.cookie.split(';')) {
    final i = part.indexOf('=');
    if (i < 0) continue;
    if (part.substring(0, i).trim() == name) {
      final value = Uri.decodeComponent(part.substring(i + 1).trim());
      return value.isEmpty ? null : value;
    }
  }
  return null;
}

void deleteCookie(String name) {
  final host = web.window.location.hostname;
  final parts = host.split('.');
  final domains = <String>[
    '',
    'domain=$host;',
    if (parts.length > 2)
      'domain=.${parts.sublist(parts.length - 2).join('.')};',
  ];
  for (final domain in domains) {
    web.document.cookie =
        '$name=; ${domain}path=/; expires=Thu, 01 Jan 1970 00:00:00 GMT';
  }
}

String currentOrigin() => web.window.location.origin;

void replaceAddress(String path) =>
    web.window.history.replaceState(null, '', path);

http.Client createCredentialsClient() =>
    BrowserClient()..withCredentials = true;

Future<Uint8List> aesCbcEncrypt(
  Uint8List key,
  Uint8List iv,
  Uint8List data,
) async {
  final subtle = web.window.crypto.subtle;
  final cryptoKey = await subtle
      .importKey('raw', key.toJS, 'AES-CBC'.toJS, false, ['encrypt'.toJS].toJS)
      .toDart;
  final algorithm = JSObject()
    ..setProperty('name'.toJS, 'AES-CBC'.toJS)
    ..setProperty('iv'.toJS, iv.toJS);
  final out = await subtle.encrypt(algorithm, cryptoKey, data.toJS).toDart;
  return (out as JSArrayBuffer).toDart.asUint8List();
}
