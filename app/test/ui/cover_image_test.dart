import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:easypodcast/ui/cover_image.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as path;

import 'fixtures/cover_cache.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'prefetch stores the raw bytes and only touches a cached cover',
    () async {
      final cache = await coverCache(binding);
      const url = 'https://podcast.example/episode.png';
      const bytes = [1, 2, 3];
      var requests = 0;
      await http.runWithClient(
        () async {
          await CoverImage.prefetch(url);
          final file = await cache.list().single as File;
          expect(await file.readAsBytes(), bytes);
          await file.setLastModified(DateTime.utc(2025));
          await CoverImage.prefetch(url);
          expect(
            (await file.lastModified()).isAfter(DateTime.utc(2025, 2)),
            isTrue,
          );
        },
        () => MockClient((_) async {
          requests++;
          return http.Response.bytes(bytes, 200);
        }),
      );
      expect(requests, 1);
    },
  );

  test('prefetch ignores an address that the HTTP client rejects', () async {
    await coverCache(binding);
    await http.runWithClient(
      () => CoverImage.prefetch('https:///cover.png'),
      () => MockClient((_) => throw ArgumentError('No host specified')),
    );
  });

  for (final prefetchFirst in [true, false]) {
    test('a prefetch and a display that overlap share one request, '
        '${prefetchFirst ? 'prefetch' : 'display'} first', () async {
      final cache = await coverCache(binding);
      final bytes = await _coverBytes();
      final cover = CoverImage('https://podcast.example/$prefetchFirst.png');
      addTearDown(cover.evict);
      final requested = Completer<void>();
      final answer = Completer<http.Response>();
      var requests = 0;
      await http.runWithClient(
        () async {
          Future<void> prefetch() => CoverImage.prefetch(cover.url);
          final first = prefetchFirst ? prefetch() : _imageSize(cover);
          await requested.future;
          final second = prefetchFirst ? _imageSize(cover) : prefetch();
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(requests, 1);
          answer.complete(http.Response.bytes(bytes, 200));
          await Future.wait([first, second]);
          expect(await _imageSize(cover), const ui.Size.square(192));
        },
        () => MockClient((_) {
          if (++requests == 1) requested.complete();
          return answer.future;
        }),
      );
      expect(await cache.list().length, 1);
    });
  }

  test('a prefetched cover can be displayed offline', () async {
    await coverCache(binding);
    final bytes = await _coverBytes();
    const cover = CoverImage('https://podcast.example/offline-episode.png');
    addTearDown(cover.evict);
    await http.runWithClient(
      () => CoverImage.prefetch(cover.url),
      () => MockClient((_) async => http.Response.bytes(bytes, 200)),
    );
    await http.runWithClient(
      () async => expect(await _imageSize(cover), const ui.Size.square(192)),
      () => MockClient((_) async => throw const SocketException('Offline')),
    );
  });

  test(
    'each cover decodes at the requested size and can load again offline',
    () async {
      final cache = await coverCache(binding);
      final bytes = await _coverBytes();
      var requests = 0;
      await http.runWithClient(
        () async {
          const cover = CoverImage('https://podcast.example/cached-cover.png');
          final thumbnail = ResizeImage(
            cover,
            width: 52,
            height: 52,
            policy: ResizeImagePolicy.fit,
          );
          final playerCover = ResizeImage(
            cover,
            width: 104,
            height: 104,
            policy: ResizeImagePolicy.fit,
          );
          addTearDown(() async {
            await thumbnail.evict();
            await playerCover.evict();
          });
          expect(await _imageSize(thumbnail), const ui.Size.square(52));
          expect(await _imageSize(playerCover), const ui.Size.square(104));
          expect(requests, 1);
          expect(await cache.list().length, 1);
        },
        () => MockClient((_) async {
          requests++;
          if (requests > 1) throw const SocketException('Offline');
          return http.Response.bytes(bytes, 200);
        }),
      );
    },
  );

  test(
    'cover cache evicts only the oldest file needed to stay under its limit',
    () async {
      final cache = await coverCache(binding);
      final bytes = await _coverBytes();
      final older = File(path.join(cache.path, 'older.img'));
      final newer = File(path.join(cache.path, 'newer.img'));
      for (final (file, size, year) in [(older, 31, 2024), (newer, 33, 2025)]) {
        final handle = await file.open(mode: FileMode.write);
        try {
          await handle.truncate(size * 1024 * 1024);
        } finally {
          await handle.close();
        }
        await file.setLastModified(DateTime.utc(year));
      }

      const cover = CoverImage('https://podcast.example/new-cover.png');
      addTearDown(cover.evict);
      await http.runWithClient(
        () async => expect(await _imageSize(cover), const ui.Size.square(192)),
        () => MockClient((_) async => http.Response.bytes(bytes, 200)),
      );

      expect(await older.exists(), isFalse);
      expect(await newer.exists(), isTrue);
      expect(await cache.list().length, 2);
    },
  );
}

Future<Uint8List> _coverBytes() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawPaint(ui.Paint()..color = const ui.Color(0xff383838));
  final picture = recorder.endRecording();
  final image = await picture.toImage(192, 192);
  final bitmap = (await image.toByteData(format: ui.ImageByteFormat.png))!;
  image.dispose();
  picture.dispose();
  return bitmap.buffer.asUint8List();
}

Future<ui.Size> _imageSize(ImageProvider provider) async {
  final stream = provider.resolve(ImageConfiguration.empty);
  final size = Completer<ui.Size>();
  final listener = ImageStreamListener((info, _) {
    size.complete(
      ui.Size(info.image.width.toDouble(), info.image.height.toDouble()),
    );
    info.dispose();
  }, onError: size.completeError);
  stream.addListener(listener);
  try {
    return await size.future;
  } finally {
    stream.removeListener(listener);
  }
}
