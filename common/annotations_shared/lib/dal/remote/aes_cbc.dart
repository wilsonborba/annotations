import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// AES-128-CBC with PKCS7 padding (pointycastle, pure Dart), for the
/// Fernet app context of the browser and installed logins (#38).
Future<Uint8List> aesCbcEncrypt(
  Uint8List key,
  Uint8List iv,
  Uint8List data,
) async {
  final cipher =
      PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))..init(
        true,
        PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
          ParametersWithIV<KeyParameter>(KeyParameter(key), iv),
          null,
        ),
      );
  return cipher.process(data);
}
