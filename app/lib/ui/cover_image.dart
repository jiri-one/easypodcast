import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class CoverImage extends ImageProvider<CoverImage> {
  const CoverImage(this.url);

  static const _maxCacheBytes = 64 * 1024 * 1024;

  final String url;

  @override
  Future<CoverImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(CoverImage key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(key._load(decode));

  Future<ImageInfo> _load(ImageDecoderCallback decode) async {
    final file = await _cacheFile();
    if (file != null) {
      try {
        return await _decode(await file.readAsBytes(), decode);
      } on Exception {
        // The cache can be cleared while an image is loading.
      }
    }
    final bytes = await _download();
    final image = await _decode(bytes, decode);
    if (file != null && bytes.length <= _maxCacheBytes) {
      await _save(file, bytes);
    }
    return image;
  }

  Future<ImageInfo> _decode(
    Uint8List bytes,
    ImageDecoderCallback decode,
  ) async {
    final codec = await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    try {
      return ImageInfo(image: (await codec.getNextFrame()).image);
    } finally {
      codec.dispose();
    }
  }

  Future<File?> _cacheFile() async {
    try {
      final root = await getApplicationCacheDirectory();
      final hash = utf8
          .encode(url)
          .fold<int>(
            0xcbf29ce484222325,
            (hash, byte) => (hash ^ byte) * 0x100000001b3,
          );
      return File(
        path.join(root.path, 'podcast-covers', '${hash.toRadixString(16)}.img'),
      );
    } on Exception {
      return null;
    }
  }

  Future<Uint8List> _download() async {
    final client = http.Client();
    try {
      final response = await client
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != HttpStatus.ok) {
        throw const FormatException('Cover image unavailable');
      }
      return response.bodyBytes;
    } finally {
      client.close();
    }
  }

  Future<void> _save(File file, Uint8List bytes) async {
    try {
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
      final directory = file.parent;
      var total = 0;
      await for (final entry in directory.list(followLinks: false)) {
        if (entry is! File) continue;
        total += await entry.length();
        if (total > _maxCacheBytes) {
          await directory.delete(recursive: true);
          break;
        }
      }
    } on FileSystemException {
      return;
    }
  }

  @override
  bool operator ==(Object other) => other is CoverImage && other.url == url;

  @override
  int get hashCode => url.hashCode;
}
