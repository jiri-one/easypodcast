import 'package:easypodcast/core/api.dart';
import 'package:easypodcast/core/models.dart';

import 'demo_library.dart';

class DemoApiClient implements ApiClient {
  DemoApiClient(this._library);

  final DemoLibrary _library;
  int? loginErrorCode;

  @override
  Future<LoginResult> login({
    required String serverUrl,
    required String username,
    required String password,
    required String deviceName,
    Duration? timeout,
  }) async {
    if (loginErrorCode case final int code) {
      throw ApiException(code, 'Demo login error');
    }
    return const LoginResult(token: 'demo', deviceId: 1);
  }

  @override
  Future<void> logout({Duration? timeout}) async {}

  @override
  Future<Fetched<List<Podcast>>?> podcasts({
    String? ifNoneMatch,
    Duration? timeout,
  }) async => Fetched(_library.allPodcasts, null);

  @override
  Future<Podcast> subscribe(String feedUrl, {Duration? timeout}) =>
      _library.subscribe(feedUrl);

  @override
  Future<void> unsubscribe(int podcastId, {Duration? timeout}) =>
      _library.unsubscribe(podcastId);

  @override
  Future<void> setNewEpisodesVisibility(
    int podcastId,
    bool show, {
    String? serverId,
    Duration? timeout,
  }) => _library.setNewEpisodesVisibility(podcastId, show);

  @override
  Future<Fetched<List<Episode>>?> episodes(
    int podcastId, {
    String? ifNoneMatch,
    Duration? timeout,
  }) async {
    final podcast = _library.podcast(podcastId);
    if (podcast == null) throw ApiException(404, 'Podcast not found');
    final etag = '"${podcast.id}-${podcast.episodesVersion}"';
    if (etag == ifNoneMatch) return null;
    return Fetched(_library.episodesOf(podcastId), etag);
  }

  @override
  Future<List<int>> searchPodcast(
    int podcastId,
    String query, {
    Duration? timeout,
  }) async => const [];

  @override
  Future<List<int>> searchAll(String query, {Duration? timeout}) async =>
      const [];

  @override
  Future<({Episode episode, String description})> episode(
    int episodeId, {
    Duration? timeout,
  }) async {
    final episode = _library.episode(episodeId);
    if (episode == null) throw ApiException(404, 'Episode not found');
    return (
      episode: episode,
      description: await _library.description(episodeId),
    );
  }

  @override
  Future<Fetched<StateSnapshot>?> fetchState({
    String? ifNoneMatch,
    Duration? timeout,
  }) async => Fetched(
    StateSnapshot(
      episodes: _library.states,
      queue: _library.queueState,
      serverTime: nowUtc(),
    ),
    null,
  );

  @override
  Future<StatePushResult> pushState({
    String? serverId,
    List<EpisodeState> episodes = const [],
    QueueState? queue,
    Duration? timeout,
  }) async {
    final known = <EpisodeState>[];
    final unknown = <int>[];
    for (final state in episodes) {
      if (_library.episode(state.episodeId) == null) {
        unknown.add(state.episodeId);
      } else {
        known.add(state);
      }
    }
    _library.applyChanges(known, queue: queue);
    return StatePushResult(
      episodes: [for (final state in known) _library.stateOf(state.episodeId)],
      queue: queue == null ? null : _library.queueState,
      unknown: unknown,
    );
  }

  @override
  Future<EpisodeState?> episodeState(int episodeId, {Duration? timeout}) async {
    final state = _library.stateOf(episodeId);
    return state.updatedAt == oldestTime ? null : state;
  }

  @override
  Future<void> refresh({Duration? timeout}) async => _library.refreshFeeds();

  @override
  Future<String> exportOpml({Duration? timeout}) async =>
      '<opml version="2.0"><body/></opml>';

  @override
  Future<OpmlImportResult> importOpml(String opml, {Duration? timeout}) async =>
      const OpmlImportResult(added: 1, existing: 0, failed: []);
}
