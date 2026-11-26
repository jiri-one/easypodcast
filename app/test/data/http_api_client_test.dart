import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easypodcast/core/api.dart';
import 'package:easypodcast/core/models.dart';
import 'package:easypodcast/data/http_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late List<http.Request> requests;
  late Future<http.Response> Function(http.Request) handler;
  late HttpApiClient api;
  const serverId = '342896fe-729d-489a-86db-1e035275f3d1';

  setUp(() {
    requests = [];
    handler = (_) async => http.Response('{}', 200);
    api = HttpApiClient(
      serverUrl: 'https://podcasts.example.test/',
      token: 'abc',
      client: MockClient((request) {
        requests.add(request);
        return handler(request);
      }),
      timeout: const Duration(milliseconds: 200),
    );
  });

  http.Response json(
    Object body, {
    int status = 200,
    Map<String, String>? headers,
  }) => http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    status,
    headers: {'content-type': 'application/json; charset=utf-8', ...?headers},
  );

  const podcastJson = {
    'id': 3,
    'feed_url': 'https://feeds.example.test/3.xml',
    'title': 'Kaktusy a lidé',
    'author': 'Nobody',
    'description': 'Plain text',
    'image_url': null,
    'link': null,
    'subscribed': true,
    'episode_count': 12,
    'played_count': 4,
    'episodes_version': 'abc123',
    'last_success_at': '2026-11-26T14:03:07.120Z',
    'last_error': null,
  };

  test(
    'podcasts send the token and parse the server JSON with its ETag',
    () async {
      handler = (_) async => json([podcastJson], headers: {'etag': '"t1"'});
      final fetched = await api.podcasts();
      final request = requests.single;
      expect(request.method, 'GET');
      expect(
        request.url.toString(),
        'https://podcasts.example.test/api/podcasts',
      );
      expect(request.headers['Authorization'], 'Bearer abc');
      expect(request.headers.containsKey('If-None-Match'), isFalse);
      expect(fetched!.etag, '"t1"');
      final p = fetched.value.single;
      expect(p.title, 'Kaktusy a lidé');
      expect(p.showInNewEpisodes, isTrue);
      expect(p.playedCount, 4);
      expect(p.lastSuccessAt, DateTime.utc(2026, 11, 26, 14, 3, 7, 120));
    },
  );

  test('the New episodes preference is parsed and sent as a PUT', () async {
    final hidden = {...podcastJson, 'show_in_new_episodes': false};
    expect(Podcast.fromJson(hidden).showInNewEpisodes, isFalse);

    handler = (_) async => http.Response('', 204);
    await api.setNewEpisodesVisibility(3, false);
    final request = requests.single;
    expect(request.method, 'PUT');
    expect(request.url.path, '/api/podcasts/3/new-episodes');
    expect(jsonDecode(request.body), {'show': false});
  });

  test('304 returns null and If-None-Match is sent', () async {
    handler = (_) async => http.Response('', 304);
    expect(await api.podcasts(ifNoneMatch: '"t1"'), isNull);
    expect(await api.episodes(3, ifNoneMatch: '"e1"'), isNull);
    expect(await api.fetchState(ifNoneMatch: 'W/"s1"'), isNull);
    expect(requests[0].headers['If-None-Match'], '"t1"');
    expect(requests[1].url.path, '/api/podcasts/3/episodes');
    expect(requests[1].headers['If-None-Match'], '"e1"');
    expect(requests[2].url.path, '/api/state');
    expect(requests[2].headers['If-None-Match'], 'W/"s1"');
  });

  test('episode detail carries the description', () async {
    handler = (_) async => json({
      'id': 7,
      'podcast_id': 3,
      'guid': 'g7',
      'title': 'Seven',
      'published_at': null,
      'duration_s': 1800,
      'enclosure_url': 'https://media.example.test/7.mp3',
      'enclosure_type': 'audio/mpeg',
      'enclosure_length': null,
      'link': null,
      'image_url': null,
      'removed_from_feed': false,
      'description': 'Links stay as https://example.test',
    });
    final detail = await api.episode(7);
    expect(detail.episode.durationS, 1800);
    expect(detail.description, 'Links stay as https://example.test');
  });

  test('search encodes the query and returns episode ids', () async {
    handler = (_) async => json({
      'episode_ids': [7, 2, 8],
    });
    const query = 'Tomáš & Roud + další # díl';
    expect(await api.searchPodcast(3, query), [7, 2, 8]);
    expect(await api.searchAll(query), [7, 2, 8]);
    expect(requests.map((r) => r.url.path), [
      '/api/podcasts/3/search',
      '/api/search',
    ]);
    for (final request in requests) {
      expect(request.method, 'GET');
      expect(request.url.queryParameters, {'q': query});
      expect(request.url.hasFragment, isFalse);
      expect(request.headers['Authorization'], 'Bearer abc');
    }
  });

  test(
    'state parses measured duration, a missing queue and server time',
    () async {
      handler = (_) async => json(
        {
          'episodes': [
            {
              'episode_id': 7,
              'position_ms': 61000,
              'status': '',
              'duration_ms': 165000,
              'updated_at': '2026-11-26T14:03:07.120Z',
            },
          ],
          'queue': null,
          'server_time': '2026-11-26T14:05:00.000Z',
          'server_id': serverId,
        },
        headers: {'etag': 'W/"s1"'},
      );
      final fetched = (await api.fetchState())!;
      final snapshot = fetched.value;
      expect(fetched.etag, 'W/"s1"');
      expect(snapshot.serverId, serverId);
      expect(snapshot.queue, isNull);
      expect(snapshot.episodes.single.isInProgress, isTrue);
      expect(snapshot.episodes.single.durationMs, 165000);
      expect(snapshot.serverTime, DateTime.utc(2026, 11, 26, 14, 5));
    },
  );

  test(
    'pushState sends states and queue in one body and parses unknown ids',
    () async {
      handler = (_) async => json({
        'episodes': [
          {
            'episode_id': 7,
            'position_ms': 0,
            'status': 'played',
            'duration_ms': null,
            'updated_at': '2026-11-26T14:03:07.120Z',
          },
        ],
        'queue': {
          'episode_ids': [8],
          'updated_at': '2026-11-26T14:03:07.121Z',
        },
        'unknown': [9],
        'server_id': serverId,
      });
      final at = DateTime.utc(2026, 11, 26, 14, 3, 7, 120);
      final result = await api.pushState(
        serverId: serverId,
        episodes: [
          EpisodeState(
            episodeId: 7,
            positionMs: 0,
            status: EpisodeStatus.played,
            durationMs: 165000,
            updatedAt: at,
          ),
        ],
        queue: QueueState(episodeIds: [8, 9], updatedAt: at),
      );
      final request = requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/api/state');
      expect(request.headers['Content-Type'], startsWith('application/json'));
      expect(jsonDecode(request.body), {
        'server_id': serverId,
        'episodes': [
          {
            'episode_id': 7,
            'position_ms': 0,
            'status': 'played',
            'duration_ms': 165000,
            'updated_at': '2026-11-26T14:03:07.120Z',
          },
        ],
        'queue': {
          'episode_ids': [8, 9],
          'updated_at': '2026-11-26T14:03:07.120Z',
        },
      });
      expect(result.serverId, serverId);
      expect(result.unknown, [9]);
      expect(result.queue!.episodeIds, [8]);
      expect(result.episodes.single.isPlayed, isTrue);
      expect(result.episodes.single.durationMs, isNull);

      await api.pushState();
      expect(jsonDecode(requests.last.body), {'episodes': <Object>[]});
    },
  );

  test('episodeState returns null for no state', () async {
    handler = (_) async => json({'state': null});
    expect(await api.episodeState(7), isNull);
    expect(requests.single.url.path, '/api/episodes/7/state');
  });

  test('errors carry the server message', () async {
    handler = (_) async => json({'error': 'not a usable feed'}, status: 422);
    await expectLater(
      api.subscribe('https://feeds.example.test/broken.xml'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.statusCode, 'status', 422)
            .having((e) => e.message, 'message', 'not a usable feed'),
      ),
    );
    handler = (_) async => http.Response(
      '<html>Bad gateway</html>',
      502,
      reasonPhrase: 'Bad Gateway',
    );
    await expectLater(
      api.refresh(),
      throwsA(
        isA<ApiException>().having((e) => e.message, 'message', 'Bad Gateway'),
      ),
    );
  });

  test('401 forgets the token and reports the logged-out session', () async {
    var called = 0;
    api.onUnauthorized = () => called++;
    handler = (_) async =>
        json({'error': 'valid bearer token required'}, status: 401);
    await expectLater(api.fetchState(), throwsA(isA<ApiException>()));
    expect(called, 1);
    expect(api.token, isNull);
  });

  test(
    'a delayed 401 from the previous token leaves the new session active',
    () async {
      final reply = Completer<http.Response>();
      handler = (_) => reply.future;
      var unauthorized = false;
      api.onUnauthorized = () => unauthorized = true;

      final rejected = expectLater(
        api.fetchState(),
        throwsA(isA<ApiException>()),
      );
      api.token = 'new-token';
      reply.complete(json({'error': 'token revoked'}, status: 401));
      await rejected;
      expect(api.token, 'new-token');
      expect(unauthorized, isFalse);
    },
  );

  test('wrong credentials at login are not a lost session', () async {
    var called = 0;
    api.onUnauthorized = () => called++;
    handler = (_) async => json({'error': 'wrong credentials'}, status: 401);
    await expectLater(
      api.login(
        serverUrl: 'https://other.example.test',
        username: 'listener',
        password: 'nope',
        deviceName: 'phone',
      ),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 401)),
    );
    expect(called, 0);
    expect(api.token, 'abc');
    expect(api.serverUrl, 'https://podcasts.example.test');
  });

  test('login switches server and token', () async {
    handler = (_) async =>
        json({'token': 'new-token', 'device_id': 4, 'server_id': serverId});
    final result = await api.login(
      serverUrl: 'https://other.example.test/api/',
      username: 'listener',
      password: 'secret',
      deviceName: 'phone',
    );
    final request = requests.single;
    expect(request.url.toString(), 'https://other.example.test/api/login');
    expect(request.headers.containsKey('Authorization'), isFalse);
    expect(jsonDecode(request.body), {
      'username': 'listener',
      'password': 'secret',
      'device_name': 'phone',
    });
    expect(result.deviceId, 4);
    expect(result.serverId, serverId);
    expect(api.token, 'new-token');
    expect(api.serverUrl, 'https://other.example.test');
  });

  test(
    'logout forgets the token even when the server is unreachable',
    () async {
      handler = (_) async => throw const SocketException('unreachable');
      await expectLater(api.logout(), throwsA(isA<OfflineException>()));
      expect(api.token, isNull);
    },
  );

  test('network failures and timeouts become OfflineException', () async {
    handler = (_) async => throw http.ClientException('connection refused');
    await expectLater(api.fetchState(), throwsA(isA<OfflineException>()));

    handler = (_) async => throw const SocketException('no route');
    await expectLater(api.fetchState(), throwsA(isA<OfflineException>()));

    handler = (_) => Completer<http.Response>().future;
    await expectLater(api.fetchState(), throwsA(isA<OfflineException>()));

    final watch = Stopwatch()..start();
    await expectLater(
      api.episodeState(7, timeout: const Duration(milliseconds: 20)),
      throwsA(isA<OfflineException>()),
    );
    expect(watch.elapsed, lessThan(const Duration(milliseconds: 150)));
  });

  testWidgets('feed operations and large reads get their full time budget', (
    tester,
  ) async {
    final api = HttpApiClient(
      serverUrl: 'https://podcasts.example.test',
      token: 'abc',
      client: MockClient((_) => Completer<http.Response>().future),
    );
    final expired = <String>[];
    Future<void> watch(String name, Future<Object?> request) async {
      try {
        await request;
      } on OfflineException {
        expired.add(name);
      }
    }

    final done = Future.wait([
      watch('subscribe', api.subscribe('https://feeds.example.test/3.xml')),
      watch('import', api.importOpml('<opml/>')),
      watch('episodes', api.episodes(3)),
      watch('state', api.fetchState()),
    ]);
    await tester.pump(const Duration(seconds: 29));
    expect(expired, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    expect(expired, unorderedEquals(['episodes', 'state']));
    await tester.pump(const Duration(seconds: 59));
    expect(expired, hasLength(2));
    await tester.pump(const Duration(seconds: 1));
    expect(
      expired,
      unorderedEquals(['episodes', 'state', 'subscribe', 'import']),
    );
    await done;
  });

  test('OPML import sends the document and parses failures', () async {
    handler = (_) async => json({
      'added': 2,
      'existing': 1,
      'failed': [
        {
          'feed_url': 'https://feeds.example.test/gone.xml',
          'error': 'HTTP 404',
        },
      ],
    });
    final result = await api.importOpml('<opml version="2.0"><body/></opml>');
    expect(requests.single.body, '<opml version="2.0"><body/></opml>');
    expect(result.added, 2);
    expect(result.failed.single.error, 'HTTP 404');
  });
}
