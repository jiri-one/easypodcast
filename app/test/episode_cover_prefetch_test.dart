import 'package:easypodcast/core/downloads.dart';
import 'package:easypodcast/core/models.dart';
import 'package:easypodcast/core/services.dart';
import 'package:easypodcast/main.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ui/fixtures/demo_downloads.dart';
import 'ui/fixtures/demo_library.dart';
import 'ui/fixtures/demo_services.dart';
import 'ui/fixtures/fake_playback_engine.dart';

const _episodeId = 103;
const _sharedCoverId = 104;
const _noCoverId = 105;
const _episodeCover = 'https://podcast.example/episode.png';
const _podcastCover = 'https://podcast.example/podcast.png';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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

  void listen() =>
      prefetchEpisodeCovers(services, fetch: (url) async => fetched.add(url));

  test('only a finished download with its own cover fetches artwork', () async {
    listen();
    final downloads = services.downloads as DemoDownloadService;
    downloads.queueDownload(_episodeId);
    downloads.setDownloadInfo(
      _episodeId,
      const DownloadInfo(DownloadStatus.running, progress: 0.5),
    );
    expect(fetched, isEmpty);

    await downloads.download(_episodeId);
    expect(fetched, [_episodeCover]);
    await downloads.download(_sharedCoverId);
    await downloads.download(_noCoverId);
    expect(fetched, [_episodeCover]);
  });

  test(
    'a download already finished when listeners attach warms its cover',
    () async {
      await services.downloads.download(_episodeId);
      listen();
      expect(fetched, [_episodeCover]);
    },
  );

  test('playback starts fetch only the episode cover', () async {
    listen();
    final player = services.player;
    await player.play(_episodeId);
    expect(fetched, [_episodeCover]);

    engine.buffer();
    await player.setSpeed(1.5);
    await player.pause();
    expect(fetched, [_episodeCover]);

    await player.resume();
    expect(fetched, [_episodeCover, _episodeCover]);
    await player.play(_sharedCoverId);
    await player.play(_noCoverId);
    expect(fetched, [_episodeCover, _episodeCover]);
  });
}

class _CoverLibrary extends DemoLibrary {
  _CoverLibrary() : super(firstPodcastCover: _podcastCover);

  @override
  Episode? episode(int episodeId) {
    final imageUrl = switch (episodeId) {
      _episodeId => _episodeCover,
      _sharedCoverId => _podcastCover,
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
