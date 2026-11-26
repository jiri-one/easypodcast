import 'dart:async';

import 'package:flutter/widgets.dart';

import 'core/models.dart';
import 'core/services.dart';
import 'core/settings.dart';
import 'data/data_layer.dart';
import 'downloads/downloads.dart';
import 'player/player.dart';
import 'ui/app_root.dart';
import 'ui/cover_image.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await Settings.load();
  final data = await openDataLayer();
  final downloads = await openDownloads(
    library: data.library,
    settings: settings,
  );
  final player = await openPlayer(
    library: data.library,
    sync: data.sync,
    downloads: downloads,
    settings: settings,
  );
  final services = AppServices(
    settings: settings,
    api: data.api,
    library: data.library,
    sync: data.sync,
    player: player,
    downloads: downloads,
  );
  prefetchEpisodeCovers(services);
  await data.sync.start();
  runApp(EasyPodcastApp(services: services));
}

void prefetchEpisodeCovers(
  AppServices services, {
  Future<void> Function(String url) fetch = CoverImage.prefetch,
}) {
  final AppServices(:library, :downloads, :player) = services;

  void prefetch(Episode? episode) {
    if (episode == null) return;
    final url = validCoverUrl(episode.imageUrl);
    if (url == null ||
        url == validCoverUrl(library.podcast(episode.podcastId)?.imageUrl)) {
      return;
    }
    unawaited(fetch(url));
  }

  var downloaded = <int>{};
  void downloadsChanged() {
    final finished = downloads.downloadedEpisodeIds.toSet();
    for (final id in finished) {
      if (!downloaded.contains(id)) prefetch(library.episode(id));
    }
    downloaded = finished;
  }

  int? playingId;
  void playbackChanged() {
    final episode = player.isPlaying ? player.current : null;
    if (episode?.id == playingId) return;
    playingId = episode?.id;
    prefetch(episode);
  }

  downloads.addListener(downloadsChanged);
  player.addListener(playbackChanged);
  downloadsChanged();
  playbackChanged();
}
