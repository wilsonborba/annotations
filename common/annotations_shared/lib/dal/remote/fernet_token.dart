import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// AES-128-CBC with PKCS7 padding: (key, iv, data) to cipher text.
typedef AesCbcEncrypt =
    Future<Uint8List> Function(Uint8List key, Uint8List iv, Uint8List data);

/// A Fernet token (spec: version 0x80, 64-bit time, 128-bit IV, AES-128-CBC
/// cipher text, HMAC-SHA256 over all of it), as auth_apps decrypts the
/// `app_context` of every Asodya app. [aes] does the cipher; in the browser
/// it is Web Crypto, so the app needs no extra crypto package.
Future<String> fernetEncrypt(
  String key,
  String plain, {
  required AesCbcEncrypt aes,
  DateTime? now,
  Uint8List? iv,
}) async {
  final raw = base64Url.decode(base64Url.normalize(key));
  if (raw.length != 32) {
    throw ArgumentError('A Fernet key has 32 bytes');
  }
  final signing = raw.sublist(0, 16), encryption = raw.sublist(16);
  final vector =
      iv ??
      Uint8List.fromList(
        List.generate(16, (_) => Random.secure().nextInt(256)),
      );
  final cipher = await aes(
    Uint8List.fromList(encryption),
    vector,
    Uint8List.fromList(utf8.encode(plain)),
  );
  final seconds = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
  // Two 32-bit halves: compiled to JavaScript, ByteData has no 64-bit set.
  final time = ByteData(8)
    ..setUint32(0, seconds ~/ 0x100000000)
    ..setUint32(4, seconds % 0x100000000);
  final body = <int>[0x80, ...time.buffer.asUint8List(), ...vector, ...cipher];
  final mac = Hmac(sha256, signing).convert(body).bytes;
  return base64Url.encode([...body, ...mac]);
}
