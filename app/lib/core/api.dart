import 'models.dart';

class ApiException implements Exception {
  ApiException(this.statusCode, this.message, {this.serverId});

  final String? serverId;
  final int statusCode;
  final String message;

  @override
  String toString() => 'ApiException($statusCode, $message)';
}

/// No connection, DNS failure or timeout: the caller keeps its changes and retries later.
class OfflineException implements Exception {
  OfflineException([this.cause]);

  final Object? cause;

  @override
  String toString() => 'OfflineException($cause)';
}

class Fetched<T> {
  const Fetched(this.value, this.etag);

  final T value;
  final String? etag;
}

class LoginResult {
  const LoginResult({
    required this.token,
    required this.deviceId,
    this.serverId,
  });

  final String token;
  final int deviceId;
  final String? serverId;
}

class StateSnapshot {
  const StateSnapshot({
    required this.episodes,
    required this.queue,
    required this.serverTime,
    this.serverId,
  });

  final List<EpisodeState> episodes;
  final QueueState? queue;
  final DateTime serverTime;
  final String? serverId;
}

class StatePushResult {
  const StatePushResult({
    required this.episodes,
    required this.queue,
    required this.unknown,
    this.future = const {},
    this.serverId,
  });

  final List<EpisodeState> episodes;
  final QueueState? queue;
  final List<int> unknown;

  /// Null identifies a skipped queue.
  final Set<int?> future;
  final String? serverId;
}

class OpmlImportResult {
  const OpmlImportResult({
    required this.added,
    required this.existing,
    required this.failed,
  });

  final int added;
  final int existing;
  final List<({String feedUrl, String error})> failed;
}

/// One method per endpoint of the HTTP API v1 in docs/architecture.md.
abstract interface class ApiClient {
  Future<LoginResult> login({
    required String serverUrl,
    required String username,
    required String password,
    required String deviceName,
    Duration? timeout,
  });

  Future<void> logout({Duration? timeout});

  /// Null means not modified since [ifNoneMatch].
  Future<Fetched<List<Podcast>>?> podcasts({
    String? ifNoneMatch,
    Duration? timeout,
  });

  Future<Podcast> subscribe(String feedUrl, {Duration? timeout});

  Future<void> unsubscribe(int podcastId, {Duration? timeout});

  Future<void> setShowInNewEpisodes(
    int podcastId,
    bool show, {
    Duration? timeout,
  });

  /// Null means not modified since [ifNoneMatch].
  Future<Fetched<List<Episode>>?> episodes(
    int podcastId, {
    String? ifNoneMatch,
    Duration? timeout,
  });

  Future<List<int>> searchPodcast(
    int podcastId,
    String query, {
    Duration? timeout,
  });

  Future<List<int>> searchAll(String query, {Duration? timeout});

  Future<({Episode episode, String description})> episode(
    int episodeId, {
    Duration? timeout,
  });

  Future<Fetched<StateSnapshot>?> fetchState({
    String? ifNoneMatch,
    Duration? timeout,
  });

  Future<StatePushResult> pushState({
    String? serverId,
    List<EpisodeState> episodes = const [],
    QueueState? queue,
    Duration? timeout,
  });

  Future<EpisodeState?> episodeState(int episodeId, {Duration? timeout});

  Future<void> refresh({Duration? timeout});

  Future<String> exportOpml({Duration? timeout});

  Future<OpmlImportResult> importOpml(String opml, {Duration? timeout});
}
