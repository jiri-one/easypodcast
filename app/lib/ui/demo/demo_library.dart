import 'dart:async';

import '../../core/api.dart';
import '../../core/library.dart';
import '../../core/models.dart';
import 'demo_content.dart';

class DemoLibrary extends Library {
  DemoLibrary({String? firstPodcastCover})
    : this._(createDemoContent(firstPodcastCover: firstPodcastCover));

  DemoLibrary._(DemoContent content)
    : _podcasts = content.podcasts,
      _episodes = content.episodes,
      _states = content.states,
      _queue = content.queue;

  final Map<int, Podcast> _podcasts;
  final Map<int, Episode> _episodes;
  final Map<int, EpisodeState> _states;
  final _finished = StreamController<int>.broadcast();
  QueueState _queue;
  int? playingEpisodeId;

  List<Podcast> get allPodcasts =>
      List.unmodifiable(_podcasts.values.map(_podcastWith));

  List<EpisodeState> get states => List.unmodifiable(_states.values);

  QueueState get queueState => _queue;

  @override
  List<Podcast> get podcasts {
    final subscribed = allPodcasts
        .where((podcast) => podcast.subscribed)
        .toList();
    subscribed.sort((a, b) {
      final byPlayed = b.playedCount.compareTo(a.playedCount);
      if (byPlayed != 0) return byPlayed;
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
    return List.unmodifiable(subscribed);
  }

  @override
  Podcast? podcast(int podcastId) {
    final show = _podcasts[podcastId];
    return show == null ? null : _podcastWith(show);
  }

  Podcast _podcastWith(
    Podcast podcast, {
    bool? subscribed,
    DateTime? refreshedAt,
  }) => Podcast(
    id: podcast.id,
    feedUrl: podcast.feedUrl,
    title: podcast.title,
    author: podcast.author,
    description: podcast.description,
    imageUrl: podcast.imageUrl,
    link: podcast.link,
    subscribed: subscribed ?? podcast.subscribed,
    episodeCount: podcast.episodeCount,
    playedCount: episodesOf(podcast.id)
        .where((e) => stateOf(e.id).isPlayed)
        .length,
    episodesVersion: podcast.episodesVersion,
    lastSuccessAt: refreshedAt ?? podcast.lastSuccessAt,
    lastError: refreshedAt == null ? podcast.lastError : null,
  );

  @override
  List<Episode> episodesOf(int podcastId) => List.unmodifiable(
    _episodes.values.where((episode) => episode.podcastId == podcastId),
  );

  @override
  Episode? episode(int episodeId) => _episodes[episodeId];

  @override
  EpisodeState stateOf(int episodeId) =>
      _states[episodeId] ?? EpisodeState.initial(episodeId);

  @override
  List<Episode> get inProgress {
    final active = _states.values.where((state) => state.isInProgress).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List.unmodifiable([
      for (final state in active) ?_episodes[state.episodeId],
    ]);
  }

  @override
  List<Episode> get queue => List.unmodifiable([
    for (final id in _queue.episodeIds)
      if (stateOf(id).status == EpisodeStatus.none) ?_episodes[id],
  ]);

  @override
  List<Episode> newEpisodes({int limit = 100}) {
    final fresh =
        [
          for (final episode in _episodes.values)
            if (_podcasts[episode.podcastId]!.subscribed &&
                !episode.removedFromFeed &&
                stateOf(episode.id).isNew)
              episode,
        ]..sort((a, b) {
          final byDate = (b.publishedAt ?? oldestTime).compareTo(
            a.publishedAt ?? oldestTime,
          );
          return byDate != 0 ? byDate : b.id.compareTo(a.id);
        });
    return List.unmodifiable(fresh.take(limit));
  }

  @override
  Stream<int> get finishedEpisodes => _finished.stream;

  @override
  Future<String> description(int episodeId) async {
    final episode = _episodes[episodeId];
    if (episode == null) throw ApiException(404, 'Episode not found');
    if (episodeId == 204) {
      return 'Promítač otevírá prázdný sál a ukazuje, jak se dřív měnily kotouče. '
          'Fotografie sálu jsou na https://podcast.example/kino.';
    }
    return _podcasts[episode.podcastId]!.description;
  }

  void refreshFeeds() {
    final now = nowUtc();
    for (final podcast in _podcasts.values.toList()) {
      if (podcast.subscribed) {
        _podcasts[podcast.id] = _podcastWith(podcast, refreshedAt: now);
      }
    }
    notifyListeners();
  }

  @override
  Future<Podcast> subscribe(String feedUrl) async {
    final url = feedUrl.trim();
    final feed = Uri.tryParse(url);
    if (feed == null ||
        !['http', 'https'].contains(feed.scheme) ||
        feed.host.isEmpty) {
      throw ApiException(422, 'Invalid feed URL');
    }
    final existing = _podcasts.values
        .where((p) => p.feedUrl == url)
        .firstOrNull;
    final show = existing == null
        ? Podcast(
            id: _podcasts.length + 1,
            title: feed.host,
            feedUrl: url,
            lastSuccessAt: nowUtc(),
          )
        : _podcastWith(existing, subscribed: true);
    _podcasts[show.id] = show;
    notifyListeners();
    return show;
  }

  @override
  Future<void> unsubscribe(int podcastId) async {
    final show = _podcasts[podcastId];
    if (show == null || !show.subscribed) return;
    _podcasts[podcastId] = _podcastWith(show, subscribed: false);
    notifyListeners();
  }

  @override
  Future<Duration> prepareForPlayback(int episodeId) async {
    final state = stateOf(episodeId);
    if (state.status == EpisodeStatus.none) {
      return Duration(milliseconds: state.positionMs);
    }
    await markNew(episodeId);
    return Duration.zero;
  }

  @override
  Future<void> recordPosition(
    int episodeId,
    Duration position, {
    Duration? duration,
  }) async {
    if (stateOf(episodeId).status != EpisodeStatus.none) return;
    applyChanges([
      _newState(
        episodeId,
        EpisodeStatus.none,
        positionMs: position.isNegative ? 0 : position.inMilliseconds,
        durationMs: duration?.inMilliseconds,
      ),
    ]);
  }

  @override
  Future<void> markCompleted(int episodeId) async {
    if (stateOf(episodeId).status != EpisodeStatus.none) return;
    await markPlayed(episodeId);
  }

  @override
  Future<void> dismiss(int episodeId) async {
    if (stateOf(episodeId).isPlayed) return;
    applyChanges([_newState(episodeId, EpisodeStatus.dismissed)]);
  }

  @override
  Future<void> dismissOlder(int episodeId) async {
    final chosen = _episodes[episodeId];
    if (chosen == null) return;
    final cutoff = chosen.publishedAt;
    final queued = _queue.episodeIds.toSet();
    applyChanges([
      for (final episode in episodesOf(chosen.podcastId))
        if ((episode.id == episodeId ||
                (cutoff != null &&
                    episode.publishedAt?.isAfter(cutoff) == false)) &&
            stateOf(episode.id).isNew &&
            !queued.contains(episode.id))
          _newState(episode.id, EpisodeStatus.dismissed),
    ]);
  }

  @override
  Future<void> markPlayed(int episodeId) async =>
      applyChanges([_newState(episodeId, EpisodeStatus.played)]);

  @override
  Future<void> markNew(int episodeId) async =>
      applyChanges([_newState(episodeId, EpisodeStatus.none)]);

  @override
  Future<void> enqueue(int episodeId, {bool next = false}) async {
    if (!_episodes.containsKey(episodeId)) return;
    final ids = _editableQueueIds();
    if (next) {
      ids.remove(episodeId);
      final first = ids.firstOrNull;
      ids.insert(first != null && first == playingEpisodeId ? 1 : 0, episodeId);
    } else if (!ids.contains(episodeId)) {
      ids.add(episodeId);
    }
    _saveQueue(ids, [
      if (stateOf(episodeId).status != EpisodeStatus.none)
        _newState(episodeId, EpisodeStatus.none),
    ]);
  }

  @override
  Future<void> dequeue(int episodeId) async =>
      _saveQueue(_editableQueueIds()..remove(episodeId));

  @override
  Future<void> moveInQueue(int episodeId, int newIndex) async {
    final ids = _editableQueueIds();
    if (!ids.remove(episodeId)) return;
    ids.insert(newIndex.clamp(0, ids.length), episodeId);
    _saveQueue(ids);
  }

  List<int> _editableQueueIds() => [
    for (final id in _queue.episodeIds)
      if (stateOf(id).status == EpisodeStatus.none) id,
  ];

  void _saveQueue(List<int> ids, [List<EpisodeState> states = const []]) =>
      applyChanges(
        states,
        queue: QueueState(
          episodeIds: ids,
          updatedAt: _nextTime(_queue.updatedAt),
        ),
      );

  EpisodeState _newState(
    int episodeId,
    EpisodeStatus status, {
    int positionMs = 0,
    int? durationMs,
  }) {
    final previous = stateOf(episodeId);
    return EpisodeState(
      episodeId: episodeId,
      positionMs: positionMs,
      status: status,
      durationMs: durationMs ?? previous.durationMs,
      updatedAt: _nextTime(previous.updatedAt),
    );
  }

  DateTime _nextTime(DateTime previous) {
    final now = nowUtc();
    return now.isAfter(previous)
        ? now
        : previous.add(const Duration(milliseconds: 1));
  }

  void applyChanges(Iterable<EpisodeState> states, {QueueState? queue}) {
    var changed = false;
    for (final state in states) {
      final previous = stateOf(state.episodeId);
      if (!_episodes.containsKey(state.episodeId) ||
          !state.isNewerThan(previous)) {
        continue;
      }
      _states[state.episodeId] = state;
      changed = true;
      if (state.status != previous.status &&
          state.status != EpisodeStatus.none) {
        _finished.add(state.episodeId);
      }
    }
    if (queue != null && queue.isNewerThan(_queue)) {
      _queue = QueueState(
        episodeIds: List.unmodifiable(queue.episodeIds),
        updatedAt: queue.updatedAt,
      );
      changed = true;
    }
    if (changed) notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_finished.close());
    super.dispose();
  }
}
