import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easypodcast/core/downloads.dart';
import 'package:easypodcast/core/models.dart';
import 'package:easypodcast/core/services.dart';
import 'package:easypodcast/main.dart';
import 'package:easypodcast/player/player.dart';
import 'package:easypodcast/ui/cover_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'ui/fixtures/cover_cache.dart';
import 'ui/fixtures/demo_downloads.dart';
import 'ui/fixtures/demo_library.dart';
import 'ui/fixtures/demo_services.dart';
import 'ui/fixtures/fake_playback_engine.dart';

const _episodeId = 103;
const _noCoverId = 105;
const _episodeCover = 'https://podcast.example/episode.png';
const _podcastCover = 'https://podcast.example/podcast.png';
final _episodeCoverBytes = base64Decode(
  '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAP////////////////////////////////////////'
  '//////////////////////////////////////////////wAALCAABAAEBAREA/8QAFAABAAAA'
  'AAAAAAAAAAAAAAAAAv/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AL//Z',
);
final _podcastCoverBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR42mOwAAAAOgA5TJ7RDwAA'
  'AABJRU5ErkJggg==',
);

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
    late Completer<http.Response> episodeCover;
    late List<Future<Uri?>> lookups;

    setUp(() async {
      await coverCache(binding);
      episodeCover = Completer();
      final client = MockClient(
        (request) async => request.url.toString() == _episodeCover
            ? await episodeCover.future
            : http.Response.bytes(_podcastCoverBytes, 200),
      );
      lookups = [];
      handler = EpisodeAudioHandler(
        services.player as EpisodePlayer,
        services.library,
        services.downloads,
        services.settings,
        android: true,
        artwork: (episode, podcast) {
          final lookup = http.runWithClient(
            () => CoverImage.artwork(episode, podcast),
            () => client,
          );
          lookups.add(lookup);
          return lookup;
        },
      );
    });

    Future<List<int>?> shownArt() async {
      await Future.wait(lookups);
      final uri = handler.mediaItem.value?.artUri;
      return uri == null ? null : File.fromUri(uri).readAsBytes();
    }

    test('the cover appears on the playing item alone', () async {
      episodeCover.complete(http.Response.bytes(_episodeCoverBytes, 200));
      await handler.playFromMediaId('episode:$_episodeId');
      expect(await shownArt(), _episodeCoverBytes);
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
      expect(handler.mediaItem.value?.artUri, isNull);
      expect(await shownArt(), _podcastCoverBytes);
    });

    test('playback starts before a missing episode cover falls back', () async {
      await handler.playFromMediaId('episode:$_episodeId');
      expect(services.player.isPlaying, isTrue);
      expect(handler.mediaItem.value?.id, 'episode:$_episodeId');
      expect(handler.mediaItem.value?.artUri, isNull);

      episodeCover.complete(http.Response.bytes(_episodeCoverBytes, 404));
      expect(await shownArt(), _podcastCoverBytes);
    });

    test('a cover fetched after a switch stays off the next episode', () async {
      await handler.playFromMediaId('episode:$_episodeId');
      await handler.playFromMediaId('episode:$_noCoverId');
      await lookups.last;

      episodeCover.complete(http.Response.bytes(_episodeCoverBytes, 200));
      expect(await shownArt(), _podcastCoverBytes);
      expect(handler.mediaItem.value?.id, 'episode:$_noCoverId');
    });

    for (final cachedEarlier in [false, true]) {
      test('an episode cover page sent with status 200 '
          '${cachedEarlier ? 'and cached earlier ' : ''}'
          'falls back to the podcast cover', () async {
        final page = http.Response(
          '<!DOCTYPE html><title>Not found</title>',
          200,
        );
        if (cachedEarlier) {
          await http.runWithClient(
            () => CoverImage.prefetch(_episodeCover),
            () => MockClient((_) async => page),
          );
        }
        episodeCover.complete(page);
        await handler.playFromMediaId('episode:$_episodeId');
        expect(await shownArt(), _podcastCoverBytes);
      });
    }
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
