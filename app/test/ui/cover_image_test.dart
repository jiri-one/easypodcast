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

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'each cover decodes at the requested size and can load again offline',
    () async {
      final parent = Directory(path.join(Directory.current.parent.path, '.ai'));
      await parent.create(recursive: true);
      final root = await parent.createTemp('cover-test-');
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger = binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'getApplicationCacheDirectory');
        return root.path;
      });
      addTearDown(() async {
        messenger.setMockMethodCallHandler(channel, null);
        await root.delete(recursive: true);
      });

      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder)
          .drawPaint(ui.Paint()..color = const ui.Color(0xff383838));
      final picture = recorder.endRecording();
      final image = await picture.toImage(192, 192);
      final bitmap = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      image.dispose();
      picture.dispose();

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
          final cache = Directory(path.join(root.path, 'podcast-covers'));
          expect(await cache.list().length, 1);
        },
        () => MockClient((_) async {
          requests++;
          if (requests > 1) throw const SocketException('Offline');
          return http.Response.bytes(bitmap.buffer.asUint8List(), 200);
        }),
      );
    },
  );
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
