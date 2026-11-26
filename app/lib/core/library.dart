import 'package:flutter/foundation.dart';

import 'models.dart';

/// The UI reads the local copy so it works offline.
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

  Episode? get recentUnfinishedEpisode {
    final candidates = [
      ...inProgress,
      ...queue,
      for (final podcast in podcasts) ...episodesOf(podcast.id),
    ];
    Episode? recent;
    DateTime? latest;
    for (final episode in candidates) {
      final state = stateOf(episode.id);
      if (state.status == EpisodeStatus.none &&
          state.positionMs > 0 &&
          (latest == null || state.updatedAt.isAfter(latest))) {
        recent = episode;
        latest = state.updatedAt;
      }
    }
    return recent;
  }

  /// Episodes still eligible for queue playback, in queue order.
  List<Episode> get queue;

  int? get queueHeadId => queue.firstOrNull?.id;

  Future<Episode?> resolveQueueEpisode(int episodeId) async =>
      episode(episodeId);

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

  /// Updates the position and measured duration of an unfinished episode.
  Future<void> recordPosition(
    int episodeId,
    Duration position, {
    Duration? duration,
  });

  Future<void> recordPositionAt(
    int episodeId,
    Duration position, {
    Duration? duration,
    required DateTime updatedAt,
  }) => recordPosition(episodeId, position, duration: duration);

  /// Marks an unfinished episode as played when playback reaches the end.
  Future<void> markCompleted(int episodeId);

  Future<void> markCompletedAt(int episodeId, DateTime updatedAt) =>
      markCompleted(episodeId);

  void requestPendingSend() {}

  /// Played episodes keep their status when dismissal is requested.
  Future<void> dismiss(int episodeId);

  /// Dismisses this and older episodes of its podcast that are new and unqueued.
  Future<void> dismissOlder(int episodeId);

  Future<void> markPlayed(int episodeId);

  Future<void> markNew(int episodeId);

  Future<void> enqueue(int episodeId, {bool next = false});

  Future<void> dequeue(int episodeId);

  Future<void> moveInQueue(int episodeId, int newIndex);
}
