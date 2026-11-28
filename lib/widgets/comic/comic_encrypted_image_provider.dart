import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../services/manga_image_crypto.dart';

const String _windowsBrowserUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36';

/// Downloads one encrypted manga page from the CDN and decrypts it locally.
///
/// The request carries only the browser user agent used by the existing core;
/// it must never carry install authentication or loopback capability headers.
/// Decryption goes through [decryptMangaImage] and the plaintext is decoded via
/// [MemoryImage], so no ciphertext, key, or decrypted bytes reach disk.
class ComicEncryptedImageProvider
    extends ImageProvider<ComicEncryptedImageProvider> {
  const ComicEncryptedImageProvider({required this.url, required this.keyHex});

  final String url;
  final String keyHex;

  @override
  Future<ComicEncryptedImageProvider> obtainKey(
    ImageConfiguration configuration,
  ) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    ComicEncryptedImageProvider key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(_load(key, decode));

  Future<ImageInfo> _load(
    ComicEncryptedImageProvider key,
    ImageDecoderCallback decode,
  ) async {
    final encrypted = await _download(Uri.parse(key.url));
    final plain = await decryptMangaImage(encrypted, key.keyHex);
    final memory = MemoryImage(plain);
    final memoryKey = await memory.obtainKey(const ImageConfiguration());
    return _firstImage(memory.loadImage(memoryKey, decode));
  }

  Future<ImageInfo> _firstImage(ImageStreamCompleter completer) {
    final result = Completer<ImageInfo>();
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        if (!result.isCompleted) result.complete(info);
        completer.removeListener(listener);
      },
      onError: (Object error, StackTrace? stack) {
        if (!result.isCompleted) result.completeError(error, stack);
        completer.removeListener(listener);
      },
    );
    completer.addListener(listener);
    return result.future;
  }

  static Future<Uint8List> _download(Uri uri) async {
    if ((uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.path == '/src' ||
        uri.path.startsWith('/src/')) {
      throw const FormatException('漫画图片地址无效');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      return await _readResponse(
        client,
        uri,
      ).timeout(const Duration(seconds: 30));
    } finally {
      client.close(force: true);
    }
  }

  static Future<Uint8List> _readResponse(HttpClient client, Uri uri) async {
    final request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.userAgentHeader, _windowsBrowserUserAgent);
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('漫画图片请求失败');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  @override
  bool operator ==(Object other) =>
      other is ComicEncryptedImageProvider &&
      other.url == url &&
      other.keyHex == keyHex;

  @override
  int get hashCode => Object.hash(ComicEncryptedImageProvider, url, keyHex);
}
