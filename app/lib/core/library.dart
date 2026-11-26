import 'package:flutter/foundation.dart';

import 'models.dart';

/// The local view of everything the UI shows. Commands change the local copy at once and leave
/// sending to the sync service, so they work offline.
abstract class Library extends ChangeNotifier {
  /// Subscribed podcasts, most played first, then by title.
  List<Podcast> get podcasts;

  Podcast? podcast(int podcastId);

  /// Newest first.
  List<Episode> episodesOf(int podcastId);

  Episode? episode(int episodeId);

  EpisodeState stateOf(int episodeId);

  /// In-progress episodes, most recently listened first.
  List<Episode> get inProgress;

  List<Episode> get queue;

  /// New episodes of subscribed podcasts, newest first.
  List<Episode> newEpisodes({int limit = 100});

  /// Ids of episodes that just became played or dismissed, locally or from another device.
  Stream<int> get finishedEpisodes;

  /// Plain text; fetched once and cached.
  Future<String> description(int episodeId);

  Future<Podcast> subscribe(String feedUrl);

  Future<void> unsubscribe(int podcastId);

  /// Turns a played or dismissed episode back into a fresh one and returns where to start.
  Future<Duration> prepareForPlayback(int episodeId);

  Future<void> recordPosition(int episodeId, Duration position);

  /// Playback reached the end: played, out of the queue.
  Future<void> markCompleted(int episodeId);

  Future<void> dismiss(int episodeId);

  /// Dismisses every new or in-progress episode of the podcast published before [before].
  Future<void> dismissOlder(int podcastId, DateTime before);

  Future<void> markPlayed(int episodeId);

  Future<void> markNew(int episodeId);

  Future<void> enqueue(int episodeId, {bool next = false});

  Future<void> dequeue(int episodeId);

  Future<void> moveInQueue(int episodeId, int newIndex);
}
