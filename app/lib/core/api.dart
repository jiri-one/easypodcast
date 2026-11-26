import 'models.dart';

class ApiException implements Exception {
  ApiException(this.statusCode, this.message);

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
  const LoginResult({required this.token, required this.deviceId});

  final String token;
  final int deviceId;
}

class StateSnapshot {
  const StateSnapshot({
    required this.episodes,
    required this.queue,
    required this.serverTime,
  });

  final List<EpisodeState> episodes;
  final QueueState? queue;
  final DateTime serverTime;
}

class StatePushResult {
  const StatePushResult({
    required this.episodes,
    required this.queue,
    required this.unknown,
  });

  final List<EpisodeState> episodes;
  final QueueState? queue;
  final List<int> unknown;
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
  });

  Future<void> logout();

  /// Null means not modified since [ifNoneMatch].
  Future<Fetched<List<Podcast>>?> podcasts({String? ifNoneMatch});

  Future<Podcast> subscribe(String feedUrl);

  Future<void> unsubscribe(int podcastId);

  /// Null means not modified since [ifNoneMatch].
  Future<Fetched<List<Episode>>?> episodes(int podcastId, {String? ifNoneMatch});

  Future<({Episode episode, String description})> episode(int episodeId);

  Future<StateSnapshot> state();

  Future<StatePushResult> pushState({
    List<EpisodeState> episodes = const [],
    QueueState? queue,
  });

  Future<EpisodeState?> episodeState(int episodeId, {Duration? timeout});

  Future<void> refresh();

  Future<String> exportOpml();

  Future<OpmlImportResult> importOpml(String opml);
}
