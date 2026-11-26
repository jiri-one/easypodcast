import 'dart:async';
import 'dart:io';

import 'package:easypodcast/core/downloads.dart';
import 'package:easypodcast/core/models.dart';
import 'package:easypodcast/core/services.dart';
import 'package:easypodcast/main.dart';
import 'package:easypodcast/player/player.dart';
import 'package:easypodcast/ui/cover_image.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'ui/fixtures/demo_downloads.dart';
import 'ui/fixtures/demo_library.dart';
import 'ui/fixtures/demo_services.dart';
import 'ui/fixtures/fake_playback_engine.dart';

const _episodeId = 103;
const _noCoverId = 105;
const _episodeCover = 'https://podcast.example/episode.png';
const _podcastCover = 'https://podcast.example/podcast.png';
const _episodeCoverBytes = [1, 2];
const _podcastCoverBytes = [3, 4];

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late AppServices services;
  late FakePlaybackEngine engine;
  late List<String> fetched;

  setUp(() async {
    engine = FakePlaybackEngine(DateTime.now);
    services = await createDemoServices(
      engine: engine,
      library: _CoverLibrary(),
    );
    fetched = [];
  });

  tearDown(() {
    services.player.dispose();
    services.downloads.dispose();
    services.library.dispose();
    services.settings.dispose();
  });

  void listen() => prefetchEpisodeCovers(
    library: services.library,
    downloads: services.downloads,
    player: services.player,
    fetch: (url) async => fetched.add(url),
  );

  test('a finished download fetches the covers the player can show', () async {
    listen();
    fetched.clear();
    final downloads = services.downloads as DemoDownloadService;
    downloads.queueDownload(_episodeId);
    downloads.setDownloadInfo(
      _episodeId,
      const DownloadInfo(DownloadStatus.running, progress: 0.5),
    );
    expect(fetched, isEmpty);

    await downloads.download(_episodeId);
    expect(fetched, [_episodeCover, _podcastCover]);
    await downloads.download(_noCoverId);
    expect(fetched, [_episodeCover, _podcastCover, _podcastCover]);
  });

  test(
    'a download already finished when listeners attach warms its cover',
    () async {
      await services.downloads.download(_episodeId);
      listen();
      expect(fetched, contains(_episodeCover));
    },
  );

  test(
    'an episode already playing when listeners attach warms its cover',
    () async {
      await services.player.play(_episodeId);
      listen();
      expect(fetched, containsAll([_episodeCover, _podcastCover]));
    },
  );

  test('each new current episode fetches its covers once', () async {
    listen();
    fetched.clear();
    final player = services.player;
    await player.play(_episodeId);
    await player.pause();
    await player.resume();
    expect(fetched, [_episodeCover, _podcastCover]);

    await player.play(_noCoverId);
    expect(fetched, [_episodeCover, _podcastCover, _podcastCover]);
  });

  group('Android media artwork', () {
    late EpisodeAudioHandler handler;

    setUp(() async {
      final parent = await Directory('../.ai').create(recursive: true);
      final cache = await parent.createTemp('media-art-test-');
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger = binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async => cache.path);
      addTearDown(() async {
        messenger.setMockMethodCallHandler(channel, null);
        await cache.delete(recursive: true);
      });
      handler = EpisodeAudioHandler(
        services.player as EpisodePlayer,
        services.library,
        services.downloads,
        services.settings,
        android: true,
        watchArtwork: CoverImage.watchArtwork,
      );
    });

    Future<Uri> artwork(int episodeId, {Uri? previous}) async {
      final item = await handler.mediaItem
          .firstWhere(
            (item) =>
                item?.id == 'episode:$episodeId' &&
                item?.artUri != null &&
                item?.artUri != previous,
          )
          .timeout(const Duration(seconds: 5));
      return item!.artUri!;
    }

    test('cached covers appear on the playing item alone', () async {
      await http.runWithClient(
        () async {
          await CoverImage.prefetch(_episodeCover);
          await CoverImage.prefetch(_podcastCover);
        },
        () => MockClient((request) async {
          final bytes = request.url.toString() == _episodeCover
              ? _episodeCoverBytes
              : _podcastCoverBytes;
          return http.Response.bytes(bytes, 200);
        }),
      );

      await handler.playFromMediaId('episode:$_episodeId');
      final episodeArt = await artwork(_episodeId);
      expect(episodeArt.scheme, 'file');
      expect(await File.fromUri(episodeArt).readAsBytes(), _episodeCoverBytes);
      final browsed = await handler.getChildren('podcast:1');
      expect(
        browsed.singleWhere((item) => item.id == 'episode:$_episodeId').artUri,
        isNull,
      );
      expect(
        (await handler.getMediaItem('episode:$_episodeId'))?.artUri,
        isNull,
      );

      await handler.playFromMediaId('episode:$_noCoverId');
      final podcastArt = await artwork(_noCoverId);
      expect(podcastArt.scheme, 'file');
      expect(await File.fromUri(podcastArt).readAsBytes(), _podcastCoverBytes);
    });

    test('playback starts before uncached artwork is ready', () async {
      final episodeResponse = Completer<http.Response>();
      final podcastResponse = Completer<http.Response>();
      final prefetches = <Future<void>>[];
      await http.runWithClient(
        () async {
          prefetchEpisodeCovers(
            library: services.library,
            downloads: services.downloads,
            player: services.player,
            fetch: (url) {
              final prefetch = CoverImage.prefetch(url);
              prefetches.add(prefetch);
              return prefetch;
            },
          );
          await handler.playFromMediaId('episode:$_episodeId');
          expect(services.player.isPlaying, isTrue);
          expect(handler.mediaItem.value?.id, 'episode:$_episodeId');
          expect(handler.mediaItem.value?.artUri, isNull);

          podcastResponse.complete(
            http.Response.bytes(_podcastCoverBytes, 200),
          );
          final fallback = await artwork(_episodeId);
          expect(
            await File.fromUri(fallback).readAsBytes(),
            _podcastCoverBytes,
          );

          episodeResponse.complete(
            http.Response.bytes(_episodeCoverBytes, 200),
          );
          final preferred = await artwork(_episodeId, previous: fallback);
          expect(
            await File.fromUri(preferred).readAsBytes(),
            _episodeCoverBytes,
          );
          await Future.wait(prefetches);
        },
        () => MockClient(
          (request) => request.url.toString() == _episodeCover
              ? episodeResponse.future
              : podcastResponse.future,
        ),
      );
    });
  });
}

class _CoverLibrary extends DemoLibrary {
  _CoverLibrary() : super(firstPodcastCover: _podcastCover);

  @override
  Episode? episode(int episodeId) {
    final imageUrl = switch (episodeId) {
      _episodeId => _episodeCover,
      _ => null,
    };
    if (imageUrl == null) return super.episode(episodeId);
    return Episode(
      id: episodeId,
      podcastId: 1,
      title: 'Episode $episodeId',
      enclosureUrl: 'https://podcast.example/$episodeId.mp3',
      imageUrl: imageUrl,
    );
  }
}
