import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../core/models.dart';

const coverGrayscale = ui.ColorFilter.matrix([
  0.2126,
  0.7152,
  0.0722,
  0,
  0,
  0.2126,
  0.7152,
  0.0722,
  0,
  0,
  0.2126,
  0.7152,
  0.0722,
  0,
  0,
  0,
  0,
  0,
  1,
  0,
]);

String? validCoverUrl(String? url) {
  final trimmed = url?.trim();
  if (trimmed == null) return null;
  final uri = Uri.tryParse(trimmed);
  return uri != null &&
          uri.host.isNotEmpty &&
          (uri.scheme == 'https' || uri.scheme == 'http')
      ? trimmed
      : null;
}

/// The episode's own cover first, then the podcast's.
List<String> coverUrls(Episode episode, Podcast? podcast) => {
  ?validCoverUrl(episode.imageUrl),
  ?validCoverUrl(podcast?.imageUrl),
}.toList();

class CoverImage extends ImageProvider<CoverImage> {
  const CoverImage(this.url);

  static const _maxCacheBytes = 64 * 1024 * 1024;
  static final _downloads = <String, Future<Uint8List>>{};
  static Future<void> _cacheWrites = Future.value();

  final String url;

  static Future<File?> prefetch(String url) async {
    final cover = CoverImage(url);
    try {
      final file = await cover._cacheFile();
      if (file == null) return null;
      if (await file.exists()) {
        await _touch(file);
        return file;
      }
      await cover._cache(file, await cover._sharedDownload());
      return await file.exists() ? file : null;
    } on Object {
      // Artwork is optional.
      return null;
    }
  }

  static Future<Uri?> artwork(Episode episode, Podcast? podcast) async {
    for (final url in coverUrls(episode, podcast)) {
      final file = await prefetch(url);
      if (file != null && await _isImage(file)) return file.uri;
    }
    return null;
  }

  // The cache keeps any status 200 body, and Android shows no cover for one
  // that is not an image.
  static Future<bool> _isImage(File file) async {
    try {
      final head = latin1.decode(
        await file.openRead(0, 12).expand((bytes) => bytes).toList(),
      );
      return head.startsWith('\xff\xd8\xff') ||
          head.startsWith('\x89PNG') ||
          head.startsWith('GIF8') ||
          (head.startsWith('RIFF') && head.endsWith('WEBP'));
    } on FileSystemException {
      return false;
    }
  }

  ResizeImage resized(double side, double devicePixelRatio) {
    final pixels = math.max(1, (side * devicePixelRatio).round());
    return ResizeImage(
      this,
      width: pixels,
      height: pixels,
      policy: ResizeImagePolicy.fit,
    );
  }

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
        final image = await _decode(await file.readAsBytes(), decode);
        unawaited(_touch(file));
        return image;
      } on Exception {
        // The cache can be cleared while an image is loading.
      }
    }
    final bytes = await _sharedDownload();
    final image = await _decode(bytes, decode);
    await _cache(file, bytes);
    return image;
  }

  // Eviction drops the oldest files first, so use counts as a write.
  static Future<void> _touch(File file) async {
    try {
      await file.setLastModified(DateTime.now());
    } on FileSystemException {
      // The cache can be cleared at any time.
    }
  }

  // A prefetch and a display that overlap share one request.
  Future<Uint8List> _sharedDownload() => _downloads.putIfAbsent(
    url,
    () => _download().whenComplete(() {
      _downloads.remove(url);
    }),
  );

  Future<void> _cache(File? file, Uint8List bytes) async {
    if (file != null && bytes.length <= _maxCacheBytes) {
      await (_cacheWrites = _cacheWrites.then((_) => _save(file, bytes)));
    }
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
    final directory = file.parent;
    final pending = File(path.join(directory.path, 'cover.tmp'));
    try {
      await directory.create(recursive: true);
      await pending.writeAsBytes(bytes);
      await pending.rename(file.path);
      final cached = <(File, FileStat)>[];
      var total = 0;
      await for (final entry in directory.list(followLinks: false)) {
        if (entry is! File || path.extension(entry.path) != '.img') continue;
        final stat = await entry.stat();
        if (stat.type != FileSystemEntityType.file) continue;
        total += stat.size;
        if (entry.path != file.path) cached.add((entry, stat));
      }
      if (total <= _maxCacheBytes) return;
      cached.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
      for (final (entry, stat) in cached) {
        await entry.delete();
        total -= stat.size;
        if (total <= _maxCacheBytes) break;
      }
    } on FileSystemException {
      try {
        await pending.delete();
      } on FileSystemException {
        return;
      }
    }
  }

  @override
  bool operator ==(Object other) => other is CoverImage && other.url == url;

  @override
  int get hashCode => url.hashCode;
}
