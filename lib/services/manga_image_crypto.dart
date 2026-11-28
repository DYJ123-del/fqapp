/// App-side AES-256-GCM decryption for remote manga images.
///
/// Wire format: 12-byte nonce || ciphertext || 16-byte authentication tag.
/// The associated data is empty and the key is the chapter's 32-byte
/// `encrypt_key`. Decryption runs in a short-lived isolate because image
/// bodies can be several megabytes.
library;

import 'dart:isolate';
import 'dart:typed_data';

import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/gcm.dart';

final RegExp _keyHexPattern = RegExp(r'^[0-9a-fA-F]{64}$');

/// Decrypts one manga image and returns the complete plaintext.
///
/// Throws [FormatException] for a malformed key/wire or a failed GCM
/// authentication check. It never returns partially authenticated bytes.
Future<Uint8List> decryptMangaImage(Uint8List wire, String keyHex) async {
  if (!_keyHexPattern.hasMatch(keyHex)) {
    throw const FormatException('漫画图片密钥无效');
  }
  final key = _decodeHex(keyHex);
  final snapshot = Uint8List.fromList(wire);
  try {
    return await Isolate.run(() => _decrypt(snapshot, key));
  } finally {
    snapshot.fillRange(0, snapshot.length, 0);
    key.fillRange(0, key.length, 0);
  }
}

Uint8List _decrypt(Uint8List wire, Uint8List key) {
  if (wire.length < 28) {
    throw const FormatException('漫画图片密文过短');
  }
  final nonce = Uint8List.sublistView(wire, 0, 12);
  final ciphertextAndTag = Uint8List.sublistView(wire, 12);
  final cipher = GCMBlockCipher(AESEngine())
    ..init(false, AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));
  try {
    return cipher.process(ciphertextAndTag);
  } on InvalidCipherTextException {
    throw const FormatException('漫画图片认证失败');
  }
}

Uint8List _decodeHex(String value) {
  final output = Uint8List(value.length ~/ 2);
  for (var i = 0; i < output.length; i++) {
    output[i] = int.parse(value.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return output;
}
