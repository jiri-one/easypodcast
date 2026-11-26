import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../core/api.dart';
import '../core/models.dart';

class HttpApiClient implements ApiClient {
  HttpApiClient({
    String serverUrl = '',
    this.token,
    http.Client? client,
    Duration? timeout,
  }) : _serverUrl = normalizeServerUrl(serverUrl),
       timeout = timeout ?? const Duration(seconds: 10),
       _listTimeout = timeout ?? const Duration(seconds: 30),
       _client =
           client ??
           IOClient(HttpClient()..idleTimeout = const Duration(seconds: 45));

  static const _feedTimeout = Duration(seconds: 90);
  final http.Client _client;
  final Duration timeout;
  final Duration _listTimeout;
  String _serverUrl;
  String? token;

  /// Called on any 401 of an authenticated request, after the token has been forgotten.
  void Function()? onUnauthorized;

  String get serverUrl => _serverUrl;
  set serverUrl(String value) => _serverUrl = normalizeServerUrl(value);

  /// Accepts the server with or without the `/api` suffix the contract uses as base URL.
  static String normalizeServerUrl(String url) {
    var result = url.trim();
    while (result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    if (result.endsWith('/api')) {
      result = result.substring(0, result.length - 4);
    }
    return result;
  }

  Future<http.Response> _send(
    String method,
    String path, {
    Object? json,
    String? body,
    String? contentType,
    String? ifNoneMatch,
    Duration? timeout,
    bool authenticated = true,
    String? serverUrl,
  }) async {
    final request = http.Request(
      method,
      Uri.parse('${serverUrl ?? _serverUrl}$path'),
    );
    request.headers['Accept'] = 'application/json';
    final requestToken = authenticated ? token : null;
    if (authenticated) {
      if (requestToken == null) throw ApiException(401, 'not logged in');
      request.headers['Authorization'] = 'Bearer $requestToken';
    }
    if (ifNoneMatch != null) request.headers['If-None-Match'] = ifNoneMatch;
    if (json != null) {
      request.headers['Content-Type'] = 'application/json; charset=utf-8';
      request.bodyBytes = utf8.encode(jsonEncode(json));
    } else if (body != null) {
      request.headers['Content-Type'] =
          contentType ?? 'text/plain; charset=utf-8';
      request.bodyBytes = utf8.encode(body);
    }
    final http.Response response;
    try {
      response = await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(timeout ?? this.timeout);
    } on TimeoutException catch (e) {
      throw OfflineException(e);
    } on http.ClientException catch (e) {
      throw OfflineException(e);
    } on IOException catch (e) {
      throw OfflineException(e);
    }
    final status = response.statusCode;
    if (status == 304 || (status >= 200 && status < 300)) return response;
    if (status == 401 && authenticated && requestToken == token) {
      token = null;
      onUnauthorized?.call();
    }
    throw _error(response);
  }

  static ApiException _error(http.Response response) {
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map && decoded['error'] is String) {
        return ApiException(
          response.statusCode,
          decoded['error'] as String,
          serverId: decoded['server_id'] as String?,
        );
      }
    } on FormatException {
      // Proxies answer with HTML; the reason phrase is better than nothing.
    }
    return ApiException(
      response.statusCode,
      response.reasonPhrase ?? 'HTTP ${response.statusCode}',
    );
  }

  static Object? _json(http.Response response) =>
      jsonDecode(utf8.decode(response.bodyBytes));

  static Map<String, Object?> _object(http.Response response) =>
      (_json(response) as Map).cast<String, Object?>();

  static List<Map<String, Object?>> _list(Object? value) => [
    for (final item in (value as List?) ?? const [])
      (item as Map).cast<String, Object?>(),
  ];

  @override
  Future<LoginResult> login({
    required String serverUrl,
    required String username,
    required String password,
    required String deviceName,
    Duration? timeout,
  }) async {
    final normalized = normalizeServerUrl(serverUrl);
    final response = await _send(
      'POST',
      '/api/login',
      json: {
        'username': username,
        'password': password,
        'device_name': deviceName,
      },
      timeout: timeout,
      authenticated: false,
      serverUrl: normalized,
    );
    final body = _object(response);
    final result = LoginResult(
      token: body['token'] as String,
      deviceId: body['device_id'] as int,
      serverId: body['server_id'] as String,
    );
    _serverUrl = normalized;
    token = result.token;
    return result;
  }

  @override
  Future<void> logout({Duration? timeout}) async {
    final requestToken = token;
    try {
      await _send('POST', '/api/logout', timeout: timeout);
    } finally {
      if (token == requestToken) token = null;
    }
  }

  @override
  Future<Fetched<List<Podcast>>?> podcasts({
    String? ifNoneMatch,
    Duration? timeout,
  }) async {
    final response = await _send(
      'GET',
      '/api/podcasts',
      timeout: timeout,
      ifNoneMatch: ifNoneMatch,
    );
    if (response.statusCode == 304) return null;
    return Fetched([
      for (final item in _list(_json(response))) Podcast.fromJson(item),
    ], response.headers['etag']);
  }

  @override
  Future<Podcast> subscribe(String feedUrl, {Duration? timeout}) async {
    final response = await _send(
      'POST',
      '/api/podcasts',
      json: {'feed_url': feedUrl},
      timeout: timeout ?? _feedTimeout,
    );
    return Podcast.fromJson(_object(response));
  }

  @override
  Future<void> unsubscribe(int podcastId, {Duration? timeout}) async {
    await _send('DELETE', '/api/podcasts/$podcastId', timeout: timeout);
  }

  @override
  Future<Fetched<List<Episode>>?> episodes(
    int podcastId, {
    String? ifNoneMatch,
    Duration? timeout,
  }) async {
    final response = await _send(
      'GET',
      '/api/podcasts/$podcastId/episodes',
      ifNoneMatch: ifNoneMatch,
      timeout: timeout ?? _listTimeout,
    );
    if (response.statusCode == 304) return null;
    return Fetched([
      for (final item in _list(_json(response))) Episode.fromJson(item),
    ], response.headers['etag']);
  }

  @override
  Future<List<int>> searchPodcast(
    int podcastId,
    String query, {
    Duration? timeout,
  }) => _searchEpisodes('/api/podcasts/$podcastId/search', query, timeout);

  @override
  Future<List<int>> searchAll(String query, {Duration? timeout}) =>
      _searchEpisodes('/api/search', query, timeout);

  Future<List<int>> _searchEpisodes(
    String path,
    String query,
    Duration? timeout,
  ) async {
    final params = Uri(queryParameters: {'q': query}).query;
    final response = await _send('GET', '$path?$params', timeout: timeout);
    return (_object(response)['episode_ids'] as List?)?.cast<int>() ?? const [];
  }

  @override
  Future<({Episode episode, String description})> episode(
    int episodeId, {
    Duration? timeout,
  }) async {
    final body = _object(
      await _send('GET', '/api/episodes/$episodeId', timeout: timeout),
    );
    return (
      episode: Episode.fromJson(body),
      description: body['description'] as String? ?? '',
    );
  }

  @override
  Future<Fetched<StateSnapshot>?> fetchState({
    String? ifNoneMatch,
    Duration? timeout,
  }) async {
    final response = await _send(
      'GET',
      '/api/state',
      ifNoneMatch: ifNoneMatch,
      timeout: timeout ?? _listTimeout,
    );
    if (response.statusCode == 304) {
      if (ifNoneMatch == null) throw const FormatException('Unexpected 304');
      return null;
    }
    final body = _object(response);
    final queue = body['queue'];
    final snapshot = StateSnapshot(
      episodes: [
        for (final item in _list(body['episodes'])) EpisodeState.fromJson(item),
      ],
      queue: queue == null
          ? null
          : QueueState.fromJson((queue as Map).cast<String, Object?>()),
      serverTime: DateTime.parse(body['server_time'] as String).toUtc(),
      serverId: body['server_id'] as String,
    );
    return Fetched(snapshot, response.headers['etag']);
  }

  @override
  Future<StatePushResult> pushState({
    String? serverId,
    List<EpisodeState> episodes = const [],
    QueueState? queue,
    Duration? timeout,
  }) async {
    final body = _object(
      await _send(
        'POST',
        '/api/state',
        timeout: timeout,
        json: {
          'server_id': ?serverId,
          'episodes': [for (final e in episodes) e.toJson()],
          'queue': ?queue?.toJson(),
        },
      ),
    );
    final stored = body['queue'];
    return StatePushResult(
      episodes: [
        for (final item in _list(body['episodes'])) EpisodeState.fromJson(item),
      ],
      queue: stored == null
          ? null
          : QueueState.fromJson((stored as Map).cast<String, Object?>()),
      future: {
        for (final id in (body['future'] as List?) ?? const [])
          id == 'queue' ? null : id as int,
      },
      unknown: [
        for (final id in (body['unknown'] as List?) ?? const []) id as int,
      ],
      serverId: body['server_id'] as String,
    );
  }

  @override
  Future<EpisodeState?> episodeState(int episodeId, {Duration? timeout}) async {
    final body = _object(
      await _send('GET', '/api/episodes/$episodeId/state', timeout: timeout),
    );
    final state = body['state'];
    return state == null
        ? null
        : EpisodeState.fromJson((state as Map).cast<String, Object?>());
  }

  @override
  Future<void> refresh({Duration? timeout}) async {
    await _send('POST', '/api/refresh', timeout: timeout);
  }

  @override
  Future<String> exportOpml({Duration? timeout}) async {
    final response = await _send('GET', '/api/opml', timeout: timeout);
    return utf8.decode(response.bodyBytes);
  }

  @override
  Future<OpmlImportResult> importOpml(String opml, {Duration? timeout}) async {
    final body = _object(
      await _send(
        'POST',
        '/api/opml',
        body: opml,
        contentType: 'text/x-opml; charset=utf-8',
        timeout: timeout ?? _feedTimeout,
      ),
    );
    return OpmlImportResult(
      added: body['added'] as int? ?? 0,
      existing: body['existing'] as int? ?? 0,
      failed: [
        for (final item in _list(body['failed']))
          (
            feedUrl: item['feed_url'] as String? ?? '',
            error: item['error'] as String? ?? '',
          ),
      ],
    );
  }
}
