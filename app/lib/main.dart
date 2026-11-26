import 'dart:async';

import 'package:flutter/widgets.dart';

import 'core/downloads.dart';
import 'core/library.dart';
import 'core/models.dart';
import 'core/player.dart';
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
  prefetchEpisodeCovers(
    library: data.library,
    downloads: downloads,
    player: player,
  );
  await data.sync.start();
  runApp(
    EasyPodcastApp(
      services: AppServices(
        settings: settings,
        api: data.api,
        library: data.library,
        sync: data.sync,
        player: player,
        downloads: downloads,
      ),
    ),
  );
}

/// Keeps the cover the player will show on disk for downloaded and current
/// episodes, so it appears at once and offline.
void prefetchEpisodeCovers({
  required Library library,
  required DownloadService downloads,
  required PlayerController player,
  Future<void> Function(String url) fetch = CoverImage.prefetch,
}) {
  void prefetch(Episode? episode) {
    if (episode == null) return;
    // The podcast's cover too: the player falls back to it when the
    // episode's own image fails.
    for (final url in coverUrls(episode, library.podcast(episode.podcastId))) {
      unawaited(fetch(url));
    }
  }

  var downloaded = <int>{};
  void downloadsChanged() {
    final finished = downloads.downloadedEpisodeIds.toSet();
    for (final id in finished) {
      if (!downloaded.contains(id)) prefetch(library.episode(id));
    }
    downloaded = finished;
  }

  int? currentId;
  void currentChanged() {
    final episode = player.current;
    if (episode?.id == currentId) return;
    currentId = episode?.id;
    prefetch(episode);
  }

  downloads.addListener(downloadsChanged);
  player.addListener(currentChanged);
  downloadsChanged();
}
