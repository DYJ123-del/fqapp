import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/full_chapter_crypto.dart';
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

const List<int> _clientPrivateMaterial = [
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, //
  17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, //
];

const List<int> _serverPrivateMaterial = [
  0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, //
  0x48, 0x49, 0x4a, 0x4b, 0x4c, 0x4d, 0x4e, 0x4f, //
  0x50, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, //
  0x58, 0x59, 0x5a, 0x5b, 0x5c, 0x5d, 0x5e, 0x5f, //
];

final Uint8List _iv = Uint8List.fromList(
  List<int>.generate(16, (index) => index),
);

void main() {
  group('FullChapterHandshake', () {
    test('uses the fixed CM group and a minimal client public key', () {
      final handshake = _handshake();
      final encoded = base64.decode(handshake.clientPublicKeyBase64);
      final publicKey = _bytesToBigInt(encoded);

      expect(base64.encode(encoded), handshake.clientPublicKeyBase64);
      expect(encoded.first, isNot(0));
      expect(
        publicKey,
        _pow2(_bytesToBigInt(_clientPrivateMaterial) % (_cmPrime - BigInt.one)),
      );
      expect(publicKey >= BigInt.two, isTrue);
      expect(publicKey <= _cmPrime - BigInt.two, isTrue);
      expect(publicKey.modPow(_cmPrimeOrder, _cmPrime), BigInt.one);
    });

    test('decrypts and processes fixed HTML, then appends the suffix', () {
      final handshake = _handshake();
      const suffix = '\n\n（完）';
      final encrypted = _encrypt(
        handshake,
        utf8.encode(
          '<p class="pictureDesc" group-id="9" idx="1">图</p>'
          '<p>第一段</p><p>第二段<br/>第三段</p>'
          '<div>保留文字</div>&amp;x',
        ),
      );

      final result = handshake.decryptChapter(
        serverKeyBase64: encrypted.serverKey,
        contentBase64: encrypted.content,
        contentSuffix: suffix,
      );

      expect(result, '图\n第一段\n第二段\n第三段\n保留文字&x\n\n（完）');
    });

    test('processes a fixed JSON payload without treating it as HTML', () {
      final handshake = _handshake();
      final encrypted = _encrypt(
        handshake,
        utf8.encode('{"title":"第一段","body":"<p>正文</p><br>续行"}'),
      );

      final result = handshake.decryptChapter(
        serverKeyBase64: encrypted.serverKey,
        contentBase64: encrypted.content,
      );

      expect(result, '{"title":"第一段","body":"\n正文\n续行"}');
    });

    test('decodes malformed UTF-8 lossily', () {
      final handshake = _handshake();
      final encrypted = _encrypt(handshake, <int>[
        0xff,
        ...utf8.encode('<p>正文</p>'),
      ]);

      final result = handshake.decryptChapter(
        serverKeyBase64: encrypted.serverKey,
        contentBase64: encrypted.content,
      );

      expect(result, '\ufffd\n正文');
    });

    test('decrypts a short plaintext carried by one ciphertext block', () {
      final handshake = _handshake();
      final encrypted = _encrypt(handshake, utf8.encode('短文'));

      final result = handshake.decryptChapter(
        serverKeyBase64: encrypted.serverKey,
        contentBase64: encrypted.content,
      );

      expect(result, '短文');
    });

    test('runs the same decrypt in a background isolate', () async {
      final handshake = _handshake();
      final encrypted = _encrypt(handshake, utf8.encode('<p>隔离区</p>'));

      final result = await handshake.decryptChapterInBackground(
        serverKeyBase64: encrypted.serverKey,
        contentBase64: encrypted.content,
      );

      expect(result, '隔离区');
    });

    test('appends a suffix after processing, including suffix-only text', () {
      final handshake = _handshake();
      final encrypted = _encrypt(handshake, utf8.encode(' \n\t '));

      final result = handshake.decryptChapter(
        serverKeyBase64: encrypted.serverKey,
        contentBase64: encrypted.content,
        contentSuffix: '（完）',
      );

      expect(result, '（完）');
    });

    test('rejects empty processed content when there is no suffix', () {
      final handshake = _handshake();
      final encrypted = _encrypt(handshake, utf8.encode(' \n\t '));

      expect(
        () => handshake.decryptChapter(
          serverKeyBase64: encrypted.serverKey,
          contentBase64: encrypted.content,
        ),
        throwsFormatException,
      );
    });

    test('rejects invalid PKCS#7 padding', () {
      final handshake = _handshake();
      final encrypted = _encrypt(
        handshake,
        List<int>.filled(16, 0x41),
        pad: false,
      );

      expect(
        () => handshake.decryptChapter(
          serverKeyBase64: encrypted.serverKey,
          contentBase64: encrypted.content,
        ),
        throwsFormatException,
      );
    });

    test('rejects empty plaintext after a valid PKCS#7 block', () {
      final handshake = _handshake();
      final encrypted = _encrypt(handshake, const <int>[]);

      expect(
        () => handshake.decryptChapter(
          serverKeyBase64: encrypted.serverKey,
          contentBase64: encrypted.content,
        ),
        throwsFormatException,
      );
    });

    test('rejects ciphertext that is not block-aligned', () {
      final handshake = _handshake();
      final peer = _peerFor(handshake);
      final malformed = Uint8List.fromList([
        ..._iv,
        ...List<int>.filled(15, 0x41),
      ]);

      expect(
        () => handshake.decryptChapter(
          serverKeyBase64: peer.serverKey,
          contentBase64: base64.encode(malformed),
        ),
        throwsFormatException,
      );
    });

    test('rejects invalid server keys before decrypting content', () {
      final handshake = _handshake();
      final peer = _peerFor(handshake);
      final peerBytes = base64.decode(peer.serverKey);
      final leadingZeroKey = base64.encode(
        Uint8List.fromList([0, ...peerBytes]),
      );
      final nonSubgroupKey = base64.encode(
        _bigIntToBytes(_cmPrime - BigInt.two),
      );
      final content = base64.encode(Uint8List(32));
      final invalidKeys = <String>[
        '',
        'Ag',
        '-w==',
        'AQ==',
        leadingZeroKey,
        nonSubgroupKey,
      ];

      for (final key in invalidKeys) {
        expect(
          () => handshake.decryptChapter(
            serverKeyBase64: key,
            contentBase64: content,
          ),
          throwsFormatException,
          reason: key.isEmpty ? 'empty key' : 'invalid key',
        );
      }
    });

    test('rejects non-canonical content base64', () {
      final handshake = _handshake();
      final peer = _peerFor(handshake);

      for (final content in ['', 'AB==', 'AA==\n']) {
        expect(
          () => handshake.decryptChapter(
            serverKeyBase64: peer.serverKey,
            contentBase64: content,
          ),
          throwsFormatException,
        );
      }
    });

    test('rejects a shared secret shorter than the AES-256 key', () {
      final handshake = FullChapterHandshake.generate(
        random: _FixedRandom([...List<int>.filled(31, 0), 1]),
      );
      final content = base64.encode(Uint8List(32));

      expect(handshake.clientPublicKeyBase64, 'Ag==');
      expect(
        () => handshake.decryptChapter(
          serverKeyBase64: 'Ag==',
          contentBase64: content,
        ),
        throwsFormatException,
      );
    });

    test('destroy blocks later decryption and is idempotent', () {
      final handshake = _handshake();
      final encrypted = _encrypt(handshake, utf8.encode('<p>正文</p>'));

      handshake.destroy();
      handshake.destroy();

      expect(handshake.isDestroyed, isTrue);
      expect(
        () => handshake.decryptChapter(
          serverKeyBase64: encrypted.serverKey,
          contentBase64: encrypted.content,
        ),
        throwsStateError,
      );
    });
  });
}

FullChapterHandshake _handshake() {
  return FullChapterHandshake.generate(
    random: _FixedRandom(_clientPrivateMaterial),
  );
}

({String serverKey, String content}) _encrypt(
  FullChapterHandshake handshake,
  List<int> plaintext, {
  bool pad = true,
}) {
  final peer = _peerFor(handshake);
  final input = Uint8List.fromList(plaintext);
  final padded = pad ? _padPkcs7(input) : input;
  if (padded.length % 16 != 0) {
    throw StateError('test plaintext is not block-aligned');
  }
  final ciphertext = _encryptCbc(padded, peer.aesKey, _iv);
  final blob = Uint8List(_iv.length + ciphertext.length)
    ..setRange(0, _iv.length, _iv)
    ..setRange(_iv.length, _iv.length + ciphertext.length, ciphertext);
  return (serverKey: peer.serverKey, content: base64.encode(blob));
}

({String serverKey, Uint8List aesKey}) _peerFor(
  FullChapterHandshake handshake,
) {
  final privateKey =
      _bytesToBigInt(_serverPrivateMaterial) % (_cmPrime - BigInt.one);
  final serverKey = _pow2(privateKey);
  final serverKeyBytes = _bigIntToBytes(serverKey);
  if (serverKeyBytes.isEmpty || serverKeyBytes.first == 0) {
    throw StateError('test server key must be minimally encoded');
  }

  final clientKey = _bytesToBigInt(
    base64.decode(handshake.clientPublicKeyBase64),
  );
  final shared = clientKey.modPow(privateKey, _cmPrime);
  final sharedBytes = _bigIntToBytes(shared);
  if (sharedBytes.length < 32) {
    throw StateError('test shared secret is too short');
  }
  return (
    serverKey: base64.encode(serverKeyBytes),
    aesKey: Uint8List.fromList(sharedBytes.sublist(0, 32)),
  );
}

BigInt _pow2(BigInt exponent) {
  return BigInt.two.modPow(exponent, _cmPrime);
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

Uint8List _padPkcs7(Uint8List input) {
  final paddingLength = 16 - input.length % 16;
  final padded = Uint8List(input.length + paddingLength);
  padded.setRange(0, input.length, input);
  padded.fillRange(input.length, padded.length, paddingLength);
  return padded;
}

Uint8List _encryptCbc(Uint8List plaintext, Uint8List key, Uint8List iv) {
  final cipher = CBCBlockCipher(AESEngine())
    ..init(true, ParametersWithIV(KeyParameter(key), iv));
  final ciphertext = Uint8List(plaintext.length);
  for (var offset = 0; offset < plaintext.length; offset += 16) {
    cipher.processBlock(plaintext, offset, ciphertext, offset);
  }
  return ciphertext;
}

class _FixedRandom implements Random {
  _FixedRandom(this._bytes);

  final List<int> _bytes;
  int _next = 0;

  @override
  int nextInt(int max) {
    if (max != 256) {
      throw UnsupportedError('test random only emits bytes');
    }
    if (_next >= _bytes.length) {
      throw StateError('test random exhausted');
    }
    return _bytes[_next++];
  }

  @override
  double nextDouble() {
    throw UnsupportedError('test random only emits bytes');
  }

  @override
  bool nextBool() {
    throw UnsupportedError('test random only emits bytes');
  }
}
