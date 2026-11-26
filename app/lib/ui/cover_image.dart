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
  static int _writeId = 0;

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
        final size = await file.length();
        if (size > 0 && size <= _maxCacheBytes) {
          return await _decode(await file.readAsBytes(), decode);
        }
      } on Exception {
        // A cache file can be purged or damaged while the app is open.
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
    final temporary = File('${file.path}.$pid-${_writeId++}.tmp');
    try {
      await file.parent.create(recursive: true);
      await temporary.writeAsBytes(bytes);
      await temporary.rename(file.path);
      await _trim(file.parent);
    } on FileSystemException {
      try {
        await temporary.delete();
      } on FileSystemException {
        return;
      }
    }
  }

  Future<void> _trim(Directory directory) async {
    final entries = await Future.wait([
      await for (final entry in directory.list())
        if (entry is File && entry.path.endsWith('.img'))
          entry.stat().then((stat) => (entry, stat)),
    ]);
    entries.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
    var total = entries.fold<int>(0, (sum, entry) => sum + entry.$2.size);
    for (final (file, stat) in entries) {
      if (total <= _maxCacheBytes) break;
      await file.delete();
      total -= stat.size;
    }
  }

  @override
  bool operator ==(Object other) => other is CoverImage && other.url == url;

  @override
  int get hashCode => url.hashCode;
}
