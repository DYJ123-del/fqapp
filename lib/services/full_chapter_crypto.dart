/// App-side CM handshake and AES-256-CBC decryption for the remote full
/// chapter pilot.
///
/// The service only relays the per-chapter peer key and ciphertext. This
/// module owns the temporary client private key, derives the shared secret,
/// decrypts locally, and applies the same body cleanup as the local core.
library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';

const _cmPrimeHex =
    'ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74'
    '020bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f14'
    '374fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406'
    'b7edee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a1'
    '63bf0598da48361c55d39a69163fa8fd24cf5f83655d23dca3ad961c62f356'
    '208552bb9ed529077096966d670c354e4abc9804f1746c08ca237327ffffffff'
    'ffffffff';

final BigInt _cmPrime = BigInt.parse(_cmPrimeHex, radix: 16);
final BigInt _cmPrimeOrder = (_cmPrime - BigInt.one) >> 1;
final BigInt _cmGenerator = BigInt.two;

const _privateMaterialLength = 32;
const _maxPrivateAttempts = 8;
const _blockSize = 16;
const _aesKeyLength = 32;
const _maxPeerKeyLength = 192;

final RegExp _canonicalBase64 = RegExp(
  r'^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$',
);

final RegExp _fullBr = RegExp(r'<\s*br\s*/?>', caseSensitive: false);
final RegExp _fullOpenP = RegExp(r'<\s*p[^>]*>', caseSensitive: false);
final RegExp _fullCloseP = RegExp(r'<\s*/p\s*>', caseSensitive: false);
final RegExp _fullAnyTag = RegExp(r'<[^>]*>');
final RegExp _fullMultiNewline = RegExp(r'\n{2,}');
final RegExp _ampX = RegExp(r'&amp;x');

final List<RegExp> _contentStripPatterns = [
  RegExp(
    r'<p class="pictureDesc" group-id="\p{Nd}+" idx="\p{Nd}+">',
    unicode: true,
  ),
  RegExp(r'</body>|</html>|</div>'),
  RegExp(r'<p class="picture" group-id="\p{Nd}+">', unicode: true),
  RegExp(r'<div data-fanqie-type="image" source="user">'),
  RegExp(r'<head>.*</h1>', dotAll: true),
  RegExp(r'<!DOCTYPE.*<html>', dotAll: true),
  RegExp(r'<\?xml.*\?>', dotAll: true),
  RegExp(r'<p idx="\p{Nd}+">', unicode: true),
  RegExp(r'<header>.*</header>', dotAll: true),
  RegExp(r'<article>|</article>'),
  RegExp(r'<footer>|</footer>'),
  RegExp(r'<tt_keyword.*keyword_ad>', dotAll: true),
  RegExp(r'<p>'),
];

/// One temporary CM handshake for one full-chapter request.
///
/// [clientPublicKeyBase64] is safe to send to the service. The private key
/// bytes never leave this object; [destroy] overwrites them when the request
/// is finished.
class FullChapterHandshake {
  FullChapterHandshake._(this._privateKeyBytes, this.clientPublicKeyBase64);

  /// Generates a temporary 32-byte private seed and its CM public key.
  ///
  /// [random] is an optional deterministic seam for tests. Production callers
  /// must omit it so [Random.secure] is used.
  factory FullChapterHandshake.generate({Random? random}) {
    final rng = random ?? Random.secure();
    final material = Uint8List(_privateMaterialLength);
    try {
      for (var attempt = 0; attempt < _maxPrivateAttempts; attempt++) {
        for (var i = 0; i < material.length; i++) {
          material[i] = rng.nextInt(256);
        }
        final privateKey = _bytesToBigInt(material) % (_cmPrime - BigInt.one);
        if (privateKey == BigInt.zero) continue;

        final publicKey = _cmGenerator.modPow(privateKey, _cmPrime);
        return FullChapterHandshake._(
          _bigIntToBytes(privateKey),
          base64.encode(_bigIntToBytes(publicKey)),
        );
      }
    } finally {
      _wipe(material);
    }
    throw StateError('CM private key generation produced zero');
  }

  /// Standard padded base64 of the minimal unsigned big-endian public key.
  final String clientPublicKeyBase64;

  final Uint8List _privateKeyBytes;
  bool _destroyed = false;

  bool get isDestroyed => _destroyed;

  /// Decrypts and processes one chapter synchronously.
  ///
  /// Throws [FormatException] for malformed keys, ciphertext, padding, or an
  /// empty result. It never returns a partial chapter and never falls back.
  String decryptChapter({
    required String serverKeyBase64,
    required String contentBase64,
    String contentSuffix = '',
  }) {
    _ensureUsable();
    return _decryptChapter(
      privateKeyBytes: _privateKeyBytes,
      serverKeyBase64: serverKeyBase64,
      contentBase64: contentBase64,
      contentSuffix: contentSuffix,
    );
  }

  /// Runs [decryptChapter] in a short-lived isolate.
  ///
  /// The copied private bytes are overwritten in this isolate when the work
  /// finishes. Call [destroy] after the request to overwrite the retained key.
  Future<String> decryptChapterInBackground({
    required String serverKeyBase64,
    required String contentBase64,
    String contentSuffix = '',
  }) async {
    _ensureUsable();
    final privateKeySnapshot = Uint8List.fromList(_privateKeyBytes);
    try {
      return await Isolate.run(() {
        try {
          return _decryptChapter(
            privateKeyBytes: privateKeySnapshot,
            serverKeyBase64: serverKeyBase64,
            contentBase64: contentBase64,
            contentSuffix: contentSuffix,
          );
        } finally {
          _wipe(privateKeySnapshot);
        }
      });
    } finally {
      _wipe(privateKeySnapshot);
    }
  }

  /// Overwrites the retained private key bytes. Safe to call more than once.
  void destroy() {
    if (_destroyed) return;
    _wipe(_privateKeyBytes);
    _destroyed = true;
  }

  void _ensureUsable() {
    if (_destroyed) {
      throw StateError('FullChapterHandshake has already been destroyed');
    }
  }
}

String _decryptChapter({
  required Uint8List privateKeyBytes,
  required String serverKeyBase64,
  required String contentBase64,
  required String contentSuffix,
}) {
  final privateKey = _bytesToBigInt(privateKeyBytes);
  final peerKeyBytes = _decodeCanonicalBase64(serverKeyBase64, 'server key');
  try {
    final serverKey = _validatePeerKey(peerKeyBytes);
    final sharedSecret = serverKey.modPow(privateKey, _cmPrime);
    final sharedBytes = _bigIntToBytes(sharedSecret);
    try {
      if (sharedBytes.length < _aesKeyLength) {
        throw const FormatException(
          'CM shared secret is shorter than 32 bytes',
        );
      }
      final aesKey = Uint8List.fromList(sharedBytes.sublist(0, _aesKeyLength));
      try {
        return _decryptAndProcess(
          aesKey: aesKey,
          contentBase64: contentBase64,
          contentSuffix: contentSuffix,
        );
      } finally {
        _wipe(aesKey);
      }
    } finally {
      _wipe(sharedBytes);
    }
  } finally {
    _wipe(peerKeyBytes);
  }
}

BigInt _validatePeerKey(Uint8List encoded) {
  if (encoded.isEmpty || encoded.length > _maxPeerKeyLength) {
    throw const FormatException('CM peer key length is invalid');
  }
  if (encoded.first == 0) {
    throw const FormatException('CM peer key is not minimally encoded');
  }

  final peerKey = _bytesToBigInt(encoded);
  final maximum = _cmPrime - BigInt.two;
  if (peerKey < BigInt.two || peerKey > maximum) {
    throw const FormatException('CM peer key is outside the group');
  }
  if (peerKey.modPow(_cmPrimeOrder, _cmPrime) != BigInt.one) {
    throw const FormatException(
      'CM peer key is not in the prime-order subgroup',
    );
  }
  return peerKey;
}

String _decryptAndProcess({
  required Uint8List aesKey,
  required String contentBase64,
  required String contentSuffix,
}) {
  final blob = _decodeCanonicalBase64(contentBase64, 'content');
  try {
    if (blob.length <= _blockSize) {
      throw const FormatException('content ciphertext is empty');
    }
    final ciphertextLength = blob.length - _blockSize;
    if (ciphertextLength % _blockSize != 0) {
      throw const FormatException('content ciphertext is not block-aligned');
    }

    final iv = Uint8List.fromList(blob.sublist(0, _blockSize));
    try {
      final ciphertext = Uint8List.sublistView(blob, _blockSize);
      final padded = _aesCbcDecrypt(ciphertext, aesKey, iv);
      try {
        final plaintext = _removePkcs7Padding(padded);
        if (plaintext.isEmpty) {
          throw const FormatException('decrypted content is empty');
        }
        final text = utf8.decode(plaintext, allowMalformed: true);
        final processed = _processFullContent(text);
        final result = '$processed$contentSuffix';
        if (result.isEmpty) {
          throw const FormatException('decrypted content is empty');
        }
        return result;
      } finally {
        _wipe(padded);
      }
    } finally {
      _wipe(iv);
    }
  } finally {
    _wipe(blob);
  }
}

Uint8List _aesCbcDecrypt(Uint8List ciphertext, Uint8List key, Uint8List iv) {
  final cipher = CBCBlockCipher(AESEngine())
    ..init(false, ParametersWithIV(KeyParameter(key), iv));
  final plaintext = Uint8List(ciphertext.length);
  try {
    for (var offset = 0; offset < ciphertext.length; offset += _blockSize) {
      cipher.processBlock(ciphertext, offset, plaintext, offset);
    }
    return plaintext;
  } catch (_) {
    _wipe(plaintext);
    rethrow;
  }
}

Uint8List _removePkcs7Padding(Uint8List padded) {
  if (padded.isEmpty || padded.length % _blockSize != 0) {
    throw const FormatException('PKCS#7 input is not block-aligned');
  }
  final paddingLength = padded.last;
  if (paddingLength == 0 ||
      paddingLength > _blockSize ||
      paddingLength > padded.length) {
    throw const FormatException('PKCS#7 padding length is invalid');
  }
  final paddingStart = padded.length - paddingLength;
  for (var i = paddingStart; i < padded.length; i++) {
    if (padded[i] != paddingLength) {
      throw const FormatException('PKCS#7 padding bytes disagree');
    }
  }
  return Uint8List.sublistView(padded, 0, paddingStart);
}

String _processFullContent(String content) {
  var value = content.replaceAll(_fullBr, '\n');
  value = value.replaceAll(_fullOpenP, '\n');
  value = value.replaceAll(_fullCloseP, '\n');
  value = value.replaceAll(_fullAnyTag, '');
  for (final pattern in _contentStripPatterns) {
    value = value.replaceAll(pattern, '');
  }
  value = value.replaceAll(_ampX, '&x');
  value = value.replaceAll(_fullMultiNewline, '\n');
  return _trimRustWhitespace(value);
}

String _trimRustWhitespace(String value) {
  var start = 0;
  var end = value.length;
  while (start < end && _isRustWhitespace(value.codeUnitAt(start))) {
    start++;
  }
  while (end > start && _isRustWhitespace(value.codeUnitAt(end - 1))) {
    end--;
  }
  return value.substring(start, end);
}

bool _isRustWhitespace(int codeUnit) {
  return (codeUnit >= 0x09 && codeUnit <= 0x0d) ||
      codeUnit == 0x20 ||
      codeUnit == 0x85 ||
      codeUnit == 0xa0 ||
      codeUnit == 0x1680 ||
      (codeUnit >= 0x2000 && codeUnit <= 0x200a) ||
      codeUnit == 0x2028 ||
      codeUnit == 0x2029 ||
      codeUnit == 0x202f ||
      codeUnit == 0x205f ||
      codeUnit == 0x3000;
}

Uint8List _decodeCanonicalBase64(String value, String field) {
  if (value.isEmpty) {
    throw FormatException('$field is empty');
  }
  if (value.length % 4 != 0 || !_canonicalBase64.hasMatch(value)) {
    throw FormatException('$field is not standard padded base64');
  }
  late final Uint8List decoded;
  try {
    decoded = base64.decode(value);
  } on FormatException {
    throw FormatException('$field is not valid base64');
  }
  if (base64.encode(decoded) != value) {
    _wipe(decoded);
    throw FormatException('$field is not canonical base64');
  }
  return decoded;
}

BigInt _bytesToBigInt(List<int> bytes) {
  var value = BigInt.zero;
  for (final byte in bytes) {
    value = (value << 8) | BigInt.from(byte);
  }
  return value;
}

Uint8List _bigIntToBytes(BigInt value) {
  if (value == BigInt.zero) return Uint8List(0);
  final length = (value.bitLength + 7) >> 3;
  final bytes = Uint8List(length);
  var remaining = value;
  for (var i = length - 1; i >= 0; i--) {
    bytes[i] = (remaining & BigInt.from(0xff)).toInt();
    remaining >>= 8;
  }
  return bytes;
}

void _wipe(Uint8List bytes) {
  bytes.fillRange(0, bytes.length, 0);
}
