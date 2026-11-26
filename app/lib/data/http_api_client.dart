import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/api.dart';
import '../core/models.dart';
import 'state_confirmation.dart';

class HttpApiClient implements ApiClient {
  HttpApiClient({
    required String serverUrl,
    this.token,
    http.Client? client,
    this.timeout = const Duration(seconds: 10),
  }) : _serverUrl = normalizeServerUrl(serverUrl),
       _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;
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
    } on SocketException catch (e) {
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
    throw ApiException(status, _errorMessage(response));
  }

  static String _errorMessage(http.Response response) {
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map && decoded['error'] is String) {
        return decoded['error'] as String;
      }
    } on FormatException {
      // Proxies answer with HTML; the reason phrase is better than nothing.
    }
    return response.reasonPhrase ?? 'HTTP ${response.statusCode}';
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
      authenticated: false,
      serverUrl: normalized,
    );
    final body = _object(response);
    final result = LoginResult(
      token: body['token'] as String,
      deviceId: body['device_id'] as int,
    );
    _serverUrl = normalized;
    token = result.token;
    return result;
  }

  @override
  Future<void> logout() async {
    final requestToken = token;
    try {
      await _send('POST', '/api/logout');
    } finally {
      if (token == requestToken) token = null;
    }
  }

  @override
  Future<Fetched<List<Podcast>>?> podcasts({String? ifNoneMatch}) async {
    final response = await _send(
      'GET',
      '/api/podcasts',
      ifNoneMatch: ifNoneMatch,
    );
    if (response.statusCode == 304) return null;
    return Fetched([
      for (final item in _list(_json(response))) Podcast.fromJson(item),
    ], response.headers['etag']);
  }

  @override
  Future<Podcast> subscribe(String feedUrl) async {
    final response = await _send(
      'POST',
      '/api/podcasts',
      json: {'feed_url': feedUrl},
      timeout: const Duration(seconds: 30),
    );
    return Podcast.fromJson(_object(response));
  }

  @override
  Future<void> unsubscribe(int podcastId) async {
    await _send('DELETE', '/api/podcasts/$podcastId');
  }

  @override
  Future<Fetched<List<Episode>>?> episodes(
    int podcastId, {
    String? ifNoneMatch,
  }) async {
    final response = await _send(
      'GET',
      '/api/podcasts/$podcastId/episodes',
      ifNoneMatch: ifNoneMatch,
    );
    if (response.statusCode == 304) return null;
    return Fetched([
      for (final item in _list(_json(response))) Episode.fromJson(item),
    ], response.headers['etag']);
  }

  @override
  Future<({Episode episode, String description})> episode(int episodeId) async {
    final body = _object(await _send('GET', '/api/episodes/$episodeId'));
    return (
      episode: Episode.fromJson(body),
      description: body['description'] as String? ?? '',
    );
  }

  @override
  Future<StateSnapshot> state() async {
    final body = _object(await _send('GET', '/api/state'));
    final queue = body['queue'];
    return StateSnapshot(
      episodes: [
        for (final item in _list(body['episodes'])) EpisodeState.fromJson(item),
      ],
      queue: queue == null
          ? null
          : QueueState.fromJson((queue as Map).cast<String, Object?>()),
      serverTime: DateTime.parse(body['server_time'] as String).toUtc(),
    );
  }

  @override
  Future<StatePushResult> pushState({
    List<EpisodeState> episodes = const [],
    QueueState? queue,
  }) async {
    final body = _object(
      await _send(
        'POST',
        '/api/state',
        json: {
          'episodes': [for (final e in episodes) e.toJson()],
          'queue': ?queue?.toJson(),
        },
      ),
    );
    final stored = body['queue'];
    final result = StatePushResult(
      episodes: [
        for (final item in _list(body['episodes'])) EpisodeState.fromJson(item),
      ],
      queue: stored == null
          ? null
          : QueueState.fromJson((stored as Map).cast<String, Object?>()),
      unknown: [
        for (final id in (body['unknown'] as List?) ?? const []) id as int,
      ],
    );
    result.requireConfirmation(episodes, queue);
    return result;
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
  Future<void> refresh() async {
    await _send('POST', '/api/refresh');
  }

  @override
  Future<String> exportOpml() async {
    final response = await _send('GET', '/api/opml');
    return utf8.decode(response.bodyBytes);
  }

  @override
  Future<OpmlImportResult> importOpml(String opml) async {
    final body = _object(
      await _send(
        'POST',
        '/api/opml',
        body: opml,
        contentType: 'text/x-opml; charset=utf-8',
        timeout: const Duration(minutes: 5),
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
