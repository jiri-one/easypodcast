import 'dart:convert';
import 'dart:io';

import 'package:easypodcast/core/api.dart';
import 'package:easypodcast/core/models.dart';
import 'package:easypodcast/core/sync.dart';
import 'package:easypodcast/data/http_api_client.dart';
import 'package:easypodcast/data/local_store.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support.dart';

final utcMillis = matches(RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$'));

EpisodeState listening(int id, int position, DateTime time) => EpisodeState(
  episodeId: id,
  positionMs: position,
  status: EpisodeStatus.none,
  updatedAt: time,
);

TypeMatcher<ApiException> apiError(int status) => isA<ApiException>().having(
  (error) => error.statusCode,
  'HTTP status',
  status,
);

DateTime nextQueueTime(QueueState? previous) {
  final now = nowUtc();
  return previous == null || now.isAfter(previous.updatedAt)
      ? now
      : previous.updatedAt.add(const Duration(milliseconds: 1));
}

void main() {
  setUpAll(sqfliteFfiInit);

  group('HTTP API', () {
    late WireClient wire;
    late HttpApiClient api;

    setUp(() {
      wire = WireClient('HTTP API');
      api = HttpApiClient(serverUrl: serverUrl, client: wire);
      addTearDown(wire.close);
    });

    Future<LoginResult> login([String candidate = password]) => api.login(
      serverUrl: '$serverUrl/api/',
      username: username,
      password: candidate,
      deviceName: 'HTTP API tests',
    );

    Future<List<Episode>> subscribe(String name) async {
      final podcast = await api.subscribe(fixture(name));
      wire.last.expectStatus(201);
      return (await api.episodes(podcast.id))!.value;
    }

    test('health is available without a token', () async {
      await wire.get(Uri.parse('$serverUrl/health'));
      wire.last.expectStatus(200);
      expect(wire.last.json, {'status': 'ok'});
    });

    test('login rejects a wrong password and authenticates a device', () async {
      await expectLater(login('wrong'), throwsA(apiError(401)));
      wire.last.expectStatus(401);
      expect(wire.last.json, {'error': isA<String>()});
      expect(api.token, isNull);

      final result = await login();
      wire.last.expectStatus(200);
      expect(result.token, isNotEmpty);
      expect(result.deviceId, greaterThan(0));
      expect(api.token, result.token);
      await api.podcasts();
      wire.last.expectStatus(200);
    });

    test('subscribe, list ETags and 304, and episode description', () async {
      await login();
      final alreadySubscribed = (await api.podcasts())!.value.any(
        (podcast) => podcast.feedUrl == feedUrl,
      );
      final podcast = await api.subscribe(feedUrl);
      wire.last.expectStatus(alreadySubscribed ? 200 : 201);
      expect(podcast.feedUrl, feedUrl);
      expect(podcast.title, 'Tichý testovací podcast');
      expect(podcast.subscribed, isTrue);
      expect(podcast.episodeCount, 3);
      expect(podcast.episodesVersion, isNotEmpty);
      expect(
        wire.last.json['last_success_at'],
        utcMillis,
        reason: wire.last.trace,
      );
      expect((await api.subscribe(feedUrl)).id, podcast.id);
      wire.last.expectStatus(200);

      final podcasts = (await api.podcasts())!;
      wire.last.expectStatus(200);
      expect(podcasts.value.map((item) => item.id), contains(podcast.id));
      expect(podcasts.etag, isNotEmpty);
      expect(await api.podcasts(ifNoneMatch: podcasts.etag), isNull);
      wire.last.expectStatus(304);
      expect(wire.last.request.headers['if-none-match'], podcasts.etag);
      expect(wire.last.response.headers['etag'], podcasts.etag);
      expect(wire.last.response.bodyBytes, isEmpty);

      final episodes = (await api.episodes(podcast.id))!;
      wire.last.expectStatus(200);
      expect(episodes.value.map((episode) => episode.guid), [
        'e2e-silence-3',
        'e2e-silence-2',
        'e2e-silence-1',
      ]);
      expect(wire.last.json[0]['published_at'], '2026-11-23T07:00:00.000Z');
      expect(episodes.value.first.durationS, 270);
      expect(episodes.etag, isNotEmpty);
      expect(
        await api.episodes(podcast.id, ifNoneMatch: episodes.etag),
        isNull,
      );
      wire.last.expectStatus(304);
      expect(wire.last.request.headers['if-none-match'], episodes.etag);
      expect(wire.last.response.headers['etag'], episodes.etag);
      expect(wire.last.response.bodyBytes, isEmpty);

      final first = episodes.value.last;
      final detail = await api.episode(first.id);
      wire.last.expectStatus(200);
      expect(detail.episode.toJson(), first.toJson());
      expect(
        detail.description,
        'Testovací díl bez zvuku. Odkaz (https://example.org/1)',
      );
    });

    test('state uses UTC milliseconds and strictly newer writes win', () async {
      await login();
      final id = (await subscribe('state')).first.id;
      expect(await api.episodeState(id), isNull);
      wire.last.expectStatus(200);
      expect(wire.last.json, {'state': null});

      final firstTime = nowUtc().subtract(const Duration(minutes: 1));
      final newerTime = firstTime.add(const Duration(milliseconds: 1));
      final first = listening(id, 65000, firstTime.toLocal());
      final newer = listening(id, 95000, newerTime);
      for (final (offered, expected) in [
        (first, first),
        (newer, newer),
        (listening(id, 180000, newerTime), newer),
        (listening(id, 220000, firstTime), newer),
      ]) {
        final result = await api.pushState(episodes: [offered]);
        wire.last.expectStatus(200);
        final request = jsonDecode(wire.last.requestBody);
        expect(
          request['episodes'][0]['updated_at'],
          utcMillis,
          reason: wire.last.trace,
        );
        expect(
          wire.last.json['episodes'][0]['updated_at'],
          formatTime(expected.updatedAt),
        );
        expect(
          result.episodes.single.toJson(),
          expected.toJson(),
          reason: wire.last.trace,
        );
        expect(result.unknown, isEmpty);
      }

      expect((await api.episodeState(id))?.toJson(), newer.toJson());
      wire.last.expectStatus(200);
      expect(wire.last.json['state']['updated_at'], formatTime(newerTime));
      final snapshot = await api.state();
      wire.last.expectStatus(200);
      expect(wire.last.json['server_time'], utcMillis);
      expect(snapshot.serverTime.isUtc, isTrue);
      expect(
        snapshot.episodes
            .singleWhere((state) => state.episodeId == id)
            .toJson(),
        newer.toJson(),
      );
    });

    test('unknown episode IDs are reported and never stored', () async {
      await login();
      final id = (await subscribe('unknown')).first.id;
      const missing = 90000001;
      final now = nowUtc();
      final result = await api.pushState(
        episodes: [listening(missing, 67000, now), listening(id, 70000, now)],
      );
      wire.last.expectStatus(200);
      expect(wire.last.json['unknown'], [missing], reason: wire.last.trace);
      expect(result.unknown, [missing]);
      expect(result.episodes.map((state) => state.episodeId), [id]);
      expect(
        (await api.state()).episodes.map((state) => state.episodeId),
        isNot(contains(missing)),
      );
    });

    test(
      'the 24-hour limit rejects an entire update with a future state or queue',
      () async {
        await login();
        final episodes = await subscribe('future');
        final id = episodes[0].id;
        final other = episodes[1].id;
        final snapshot = await api.state();
        final tooFar = snapshot.serverTime.add(
          const Duration(hours: 24, minutes: 1),
        );
        final within = snapshot.serverTime.add(
          const Duration(hours: 23, minutes: 59),
        );
        final valid = listening(id, 74000, within);
        final futureError = apiError(400)
            .having((error) => error.message, 'message', contains('24 hours'));

        await expectLater(
          api.pushState(episodes: [valid, listening(other, 80000, tooFar)]),
          throwsA(futureError),
        );
        wire.last.expectStatus(400);
        expect(wire.last.json, {'error': contains('24 hours')});
        expect(await api.episodeState(id), isNull);
        expect(await api.episodeState(other), isNull);

        await expectLater(
          api.pushState(
            episodes: [valid],
            queue: QueueState(episodeIds: [id], updatedAt: tooFar),
          ),
          throwsA(futureError),
        );
        wire.last.expectStatus(400);
        expect(await api.episodeState(id), isNull);
        expect((await api.state()).queue?.toJson(), snapshot.queue?.toJson());

        final accepted = await api.pushState(episodes: [valid]);
        wire.last.expectStatus(200);
        expect(accepted.episodes.single.toJson(), valid.toJson());
      },
    );

    test(
      'the client sends and decodes measured duration_ms in a state push',
      () async {
        await login();
        final id = (await subscribe('duration-push')).first.id;
        const duration = 210123;
        final state = EpisodeState.fromJson({
          ...listening(id, 69000, nowUtc()).toJson(),
          'duration_ms': duration,
        });
        final result = await api.pushState(episodes: [state]);
        wire.last.expectStatus(200);
        expect(
          [
            jsonDecode(wire.last.requestBody)['episodes'][0]['duration_ms'],
            wire.last.json['episodes'][0]['duration_ms'],
            result.episodes.single.toJson()['duration_ms'],
          ],
          [duration, duration, duration],
          reason: wire.last.trace,
        );
      },
    );

    test('single-episode and full state decode a server duration_ms', () async {
      final session = await login();
      final id = (await subscribe('duration-pull')).first.id;
      const duration = 168321;
      await wire.post(
        Uri.parse('$serverUrl/api/state'),
        headers: {
          'Authorization': 'Bearer ${session.token}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'episodes': [
            {
              ...listening(id, 62000, nowUtc()).toJson(),
              'duration_ms': duration,
            },
          ],
        }),
      );
      wire.last.expectStatus(200);
      expect(
        wire.last.json['episodes'][0]['duration_ms'],
        duration,
        reason: wire.last.trace,
      );

      final single = await api.episodeState(id);
      final singleExchange = wire.last;
      final snapshot = await api.state();
      final downloaded = snapshot.episodes.singleWhere(
        (state) => state.episodeId == id,
      );
      expect(
        [single?.toJson()['duration_ms'], downloaded.toJson()['duration_ms']],
        [duration, duration],
        reason: '${singleExchange.trace}\n${wire.last.trace}',
      );
    });

    test(
      'queue writes keep order and ignore equal or older timestamps',
      () async {
        await login();
        final ids = (await subscribe('queue'))
            .map((episode) => episode.id)
            .toList();
        final firstTime = nextQueueTime((await api.state()).queue);
        final newerTime = firstTime.add(const Duration(milliseconds: 1));
        final first = QueueState(
          episodeIds: [ids[2], ids[0]],
          updatedAt: firstTime,
        );
        final newer = QueueState(
          episodeIds: [ids[1], ids[2]],
          updatedAt: newerTime,
        );
        final empty = QueueState(
          episodeIds: [],
          updatedAt: newerTime.add(const Duration(milliseconds: 1)),
        );

        for (final (offered, expected) in [
          (first, first),
          (newer, newer),
          (QueueState(episodeIds: ids, updatedAt: newerTime), newer),
          (first, newer),
          (empty, empty),
        ]) {
          final result = await api.pushState(queue: offered);
          wire.last.expectStatus(200);
          expect(
            wire.last.json['queue'],
            expected.toJson(),
            reason: wire.last.trace,
          );
          expect(result.queue?.toJson(), expected.toJson());
        }
        expect((await api.state()).queue?.toJson(), empty.toJson());
      },
    );

    test(
      'OPML export and import report new, existing and failed feeds',
      () async {
        await login();
        final existing = fixture('opml-existing');
        final added = fixture('opml-added');
        const missing = '$fixtureServer/missing.xml';
        await api.subscribe(existing);
        final subscribed = (await api.podcasts())!.value.where(
          (podcast) => podcast.subscribed,
        );
        final exported = await api.exportOpml();
        wire.last.expectStatus(200);
        expect(exported, contains('xmlUrl="$existing"'));
        expect(exported, contains('Tichý testovací podcast'));

        final document = exported.replaceFirst('</body>', '''
    <outline type="rss" xmlUrl="$added"/>
    <outline type="rss" xmlUrl="$missing"/>
  </body>''');
        final result = await api.importOpml(document);
        wire.last.expectStatus(200);
        expect(result.added, 1, reason: wire.last.trace);
        expect(result.existing, subscribed.length);
        expect(result.failed.single.feedUrl, missing);
        expect(result.failed.single.error, isNotEmpty);
        expect(await api.exportOpml(), contains('xmlUrl="$added"'));
      },
    );

    test(
      'logout clears the local token and revokes it on the server',
      () async {
        final result = await login();
        await api.logout();
        wire.last.expectStatus(204);
        expect(wire.last.response.bodyBytes, isEmpty);
        expect(api.token, isNull);

        final replay = HttpApiClient(
          serverUrl: serverUrl,
          token: result.token,
          client: wire,
        );
        await expectLater(replay.state(), throwsA(apiError(401)));
        wire.last.expectStatus(401);
        expect(replay.token, isNull);
      },
    );
  });

  group('two devices', () {
    late DateTime deviceTime;

    setUp(() => deviceTime = nowUtc());

    void advance() => deviceTime = deviceTime.add(const Duration(seconds: 1));

    Future<Device> device(String name) => Device.open(name, () => deviceTime);

    Future<({Device a, Device b, List<int> ids})> pair(
      String name, {
      bool resetQueue = false,
    }) async {
      final a = await device('$name A');
      final podcast = await a.data.library.subscribe(fixture(name));
      if (resetQueue) {
        deviceTime = nextQueueTime((await a.data.api.state()).queue);
        await a.data.api.pushState(
          queue: QueueState(episodeIds: [], updatedAt: deviceTime),
        );
        await a.sync.syncNow();
      }
      final b = await device('$name B');
      final ids = a.data.library
          .episodesOf(podcast.id)
          .map((episode) => episode.id)
          .toList();
      expect(ids, hasLength(3));
      expect(
        b.data.library.episodesOf(podcast.id).map((episode) => episode.id),
        ids,
      );
      expect(
        a.store.meta(MetaKey.deviceId),
        isNot(b.store.meta(MetaKey.deviceId)),
      );
      return (a: a, b: b, ids: ids);
    }

    test(
      'pausing on A supplies the resume position and duration to B before play',
      () async {
        final (:a, :b, :ids) = await pair('handoff');
        final id = ids.first;
        await b.pauseAt(id, 65000);
        advance();
        const measured = Duration(milliseconds: 264321);
        await a.pauseAt(id, 93000, duration: measured);
        final remote = (await a.data.api.episodeState(id))!;
        expect(remote.positionMs, 93000);
        expect(remote.durationMs, measured.inMilliseconds);
        expect(b.data.library.stateOf(id).positionMs, 65000);
        deviceTime = deviceTime.add(const Duration(seconds: 31));

        await b.sync.freshStateBeforePlay(id);
        expect(b.wire.last.request.url.path, '/api/episodes/$id/state');
        expect(
          await b.data.library.prepareForPlayback(id),
          const Duration(milliseconds: 93000),
        );
        expect(b.data.library.stateOf(id).toJson(), remote.toJson());
        final stored = (await b.store.load()).states.singleWhere(
          (state) => state.episodeId == id,
        );
        expect(stored.toJson(), remote.toJson());
        expect(b.sync.status.value.pending, 0);
      },
    );

    test(
      'B reconnects after offline listening and adopts the newer A state',
      () async {
        final (:a, :b, :ids) = await pair('offline');
        final id = ids.first;
        b.wire.offline = true;
        await b.pauseAt(id, 71000);
        final offline = b.data.library.stateOf(id);
        expect(b.sync.status.value.phase, SyncPhase.offline);
        expect(b.sync.status.value.pending, 1);
        expect(await a.data.api.episodeState(id), isNull);

        advance();
        await a.pauseAt(id, 99000);
        final aState = (await a.data.api.episodeState(id))!;
        expect(aState.updatedAt.isAfter(offline.updatedAt), isTrue);
        expect(aState.positionMs, 99000);

        b.sync.didChangeAppLifecycleState(AppLifecycleState.paused);
        await b.waitForSync();
        advance();
        b.wire.offline = false;
        final start = b.wire.exchanges.length;
        b.sync.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await b.waitForSync();

        final check = b.wire.exchanges[start];
        expect(check.request.method, 'GET');
        expect(check.request.url.path, '/api/state');
        expect(check.request.headers['if-none-match'], isNotEmpty);
        final retry = b.wire.exchanges[start + 1];
        expect(retry.request.method, 'POST');
        expect(retry.request.url.path, '/api/state');
        expect(jsonDecode(retry.requestBody)['episodes'], [offline.toJson()]);
        expect((await a.data.api.episodeState(id))?.toJson(), aState.toJson());
        expect(b.data.library.stateOf(id).toJson(), aState.toJson());
        expect(b.sync.status.value.pending, 0);
        expect(b.sync.status.value.phase, SyncPhase.idle);
      },
    );

    test(
      'same-millisecond writes converge and survive both clients restarting',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'easypodcast-tie-',
        );
        addTearDown(() => directory.delete(recursive: true));
        Future<Device> open(String name) => Device.open(
          name,
          () => deviceTime,
          databasePath: '${directory.path}/$name.db',
        );
        final a = await open('tie-A');
        final podcast = await a.data.library.subscribe(fixture('tie'));
        final id = a.data.library.episodesOf(podcast.id).first.id;
        final b = await open('tie-B');

        b.wire.offline = true;
        await b.pauseAt(id, 71000, duration: const Duration(minutes: 15));
        await a.pauseAt(id, 99000, duration: const Duration(minutes: 20));
        final winner = a.data.library.stateOf(id);
        expect(b.data.library.stateOf(id).updatedAt, winner.updatedAt);
        expect(b.data.library.stateOf(id).positionMs, 71000);

        b.wire.offline = false;
        final start = b.wire.exchanges.length;
        await b.sync.syncNow();
        final acknowledgement = b.wire.exchanges
            .skip(start)
            .firstWhere((exchange) => exchange.request.method == 'POST');
        acknowledgement.expectStatus(200);
        expect(acknowledgement.json['episodes'], [winner.toJson()]);
        expect(b.data.library.stateOf(id).toJson(), winner.toJson());
        expect(b.sync.status.value.pending, 0);

        await a.close();
        await b.close();
        final restartedA = await open('tie-A');
        final restartedB = await open('tie-B');
        expect(restartedA.data.library.stateOf(id).toJson(), winner.toJson());
        expect(restartedB.data.library.stateOf(id).toJson(), winner.toJson());
        expect(restartedB.sync.status.value.pending, 0);
      },
    );

    test('new-server-id makes a reconnect drop offline changes and refetch the library', () async {
      final phone = await device('identity');
      final podcast = await phone.data.library.subscribe(fixture('identity'));
      await phone.sync.syncNow();
      final episode = phone.data.library.episodesOf(podcast.id).first;
      final oldId = phone.store.meta(MetaKey.serverId);
      final oldTag = phone.store.meta(MetaKey.stateEtag);
      expect(oldId, isNotEmpty);
      expect(oldTag, isNotEmpty);

      phone.wire.offline = true;
      await phone.pauseAt(episode.id, 71000);
      expect(phone.sync.status.value.pending, 1);
      final rotate = await Process.run(
        Platform.environment['EASYPODCAST_E2E_BINARY']!,
        ['new-server-id'],
      );
      expect(rotate.exitCode, 0, reason: '${rotate.stderr}');
      phone.wire.offline = false;

      final start = phone.wire.exchanges.length;
      await phone.sync.syncNow();
      final requests = phone.wire.exchanges.skip(start).toList();
      final check = requests.first;
      expect(check.request.method, 'GET');
      expect(check.request.url.path, '/api/state');
      expect(check.request.headers['if-none-match'], oldTag);
      check.expectStatus(200);
      final newId = phone.store.meta(MetaKey.serverId);
      expect(newId, isNot(oldId));
      expect(newId, check.json['server_id']);
      expect(
        requests.map((exchange) => exchange.request.method),
        everyElement('GET'),
      );
      expect(
        requests.map((exchange) => exchange.request.url.path),
        contains('/api/podcasts/${podcast.id}/episodes'),
      );
      expect(phone.data.library.episode(episode.id)?.title, episode.title);
      expect(phone.data.library.stateOf(episode.id).isNew, isTrue);
      expect(await phone.data.api.episodeState(episode.id), isNull);
      expect(phone.sync.status.value.pending, 0);
      expect(phone.sync.status.value.phase, SyncPhase.idle);
    });

    test('a Go server 400 repairs a future stamp after the device clock is corrected', () async {
      final (:a, :b, :ids) = await pair('bad-clock');
      final [future, valid, inbound] = ids;
      b.wire.offline = true;
      final validTime = deviceTime;
      deviceTime = validTime.add(const Duration(days: 2));
      await b.data.library.markPlayed(future);
      final rejected = b.data.library.stateOf(future);
      deviceTime = validTime;
      await b.pauseAt(valid, 71000);
      await a.pauseAt(inbound, 99000);

      final start = b.wire.exchanges.length;
      b.wire.offline = false;
      await b.sync.syncNow();
      b.wire.exchanges
          .skip(start)
          .firstWhere((exchange) => exchange.request.method == 'POST')
          .expectStatus(400);
      final repaired = (await a.data.api.episodeState(future))!;
      expect(repaired.toJson(), {
        ...rejected.toJson(),
        'updated_at': formatTime(validTime),
      });
      expect((await a.data.api.episodeState(valid))?.positionMs, 71000);
      expect(b.data.library.stateOf(inbound).positionMs, 99000);
      final snapshot = await b.store.load();
      expect(snapshot.pendingStates, isEmpty);
      expect(
        snapshot.states
            .singleWhere((state) => state.episodeId == future)
            .toJson(),
        repaired.toJson(),
      );
    });

    test('dismissing on A removes the episode from in-progress on B', () async {
      final (:a, :b, :ids) = await pair('dismiss');
      final id = ids.first;
      await a.pauseAt(id, 89000);
      await b.sync.syncNow();
      expect(
        b.data.library.inProgress.map((episode) => episode.id),
        contains(id),
      );
      advance();
      await a.data.library.dismiss(id);
      await a.waitForSync();
      await b.sync.syncNow();

      final state = b.data.library.stateOf(id);
      expect(state.isDismissed, isTrue);
      expect(state.positionMs, 0);
      expect(
        b.data.library.inProgress.map((episode) => episode.id),
        isNot(contains(id)),
      );
    });

    test('a state for an unknown local episode survives and appears after list refresh', () async {
      final a = await device('missing episode A');
      final b = await device('missing episode B');
      int? episodeId;
      String? lateListPath;
      EpisodeState? buffered;
      bool? bufferedAsPending;
      // Place the state on the server after B starts its pull.
      b.wire.beforeSend = (request) async {
        if (request.method != 'GET') return;
        if (episodeId == null && request.url.path == '/api/state') {
          final podcast = await a.data.library.subscribe(
            fixture('late-episode'),
          );
          final id = a.data.library.episodesOf(podcast.id).first.id;
          episodeId = id;
          lateListPath = '/api/podcasts/${podcast.id}/episodes';
          await a.pauseAt(id, 87000);
        } else if (request.url.path == lateListPath) {
          final id = episodeId!;
          expect(b.data.library.episode(id), isNull);
          expect(
            b.data.library.inProgress.map((episode) => episode.id),
            isNot(contains(id)),
          );
          final local = await b.store.load();
          buffered = local.states.singleWhere((state) => state.episodeId == id);
          bufferedAsPending = local.pendingStates.contains(id);
        }
      };
      await b.sync.syncNow();

      expect(
        b.sync.status.value.phase,
        SyncPhase.idle,
        reason: b.sync.status.value.error,
      );
      expect(episodeId, isNotNull);
      final id = episodeId!;
      expect(buffered?.positionMs, 87000);
      expect(bufferedAsPending, isFalse);
      expect(b.data.library.episode(id), isNotNull);
      expect(b.data.library.stateOf(id).positionMs, 87000);
      expect(
        b.data.library.inProgress.map((episode) => episode.id),
        contains(id),
      );
    });

    test('B refreshes the shared queue before a manual add', () async {
      final (:a, :b, :ids) = await pair('queue-edit', resetQueue: true);
      advance();
      await a.data.library.enqueue(ids[0]);
      await a.waitForSync();
      expect(b.data.library.queue, isEmpty);

      advance();
      await b.data.library.enqueue(ids[1]);
      await b.waitForSync();
      expect((await a.data.api.state()).queue?.episodeIds, [
        ids[0],
        ids[1],
      ], reason: b.wire.last.trace);
      expect(b.data.library.queue.map((episode) => episode.id), [
        ids[0],
        ids[1],
      ]);
    });

    test(
      'dismissal hides a queued episode without rewriting the stored queue',
      () async {
        final (:a, :b, :ids) = await pair('queue-dismiss', resetQueue: true);
        final id = ids.first;
        advance();
        await a.data.library.enqueue(id);
        await a.waitForSync();
        await b.sync.syncNow();
        expect(b.data.library.queue.map((episode) => episode.id), [id]);
        final before = (await a.data.api.state()).queue!;

        advance();
        await a.data.library.dismiss(id);
        await a.waitForSync();
        final dismissal = a.wire.last;
        await b.sync.syncNow();
        expect(
          [
            jsonDecode(dismissal.requestBody).containsKey('queue'),
            (await a.data.api.state()).queue?.toJson(),
            b.data.library.queue.map((episode) => episode.id).toList(),
          ],
          [false, before.toJson(), isEmpty],
          reason: dismissal.trace,
        );
      },
    );

    test(
      'manual queue edits prune terminal entries and revive the added episode',
      () async {
        final (:a, :b, :ids) = await pair('queue-prune', resetQueue: true);
        final [old, added, kept] = ids;
        advance();
        final stamp = deviceTime;
        await a.data.api.pushState(
          episodes: [
            EpisodeState(
              episodeId: old,
              positionMs: 0,
              status: EpisodeStatus.played,
              updatedAt: stamp,
            ),
            EpisodeState(
              episodeId: added,
              positionMs: 0,
              status: EpisodeStatus.dismissed,
              updatedAt: stamp,
            ),
          ],
          queue: QueueState(episodeIds: [old, kept], updatedAt: stamp),
        );
        await b.sync.syncNow();
        final shown = b.data.library.queue
            .map((episode) => episode.id)
            .toList();

        advance();
        await b.data.library.enqueue(added);
        await b.waitForSync();
        final snapshot = await a.data.api.state();
        expect(
          [
            shown,
            snapshot.queue?.episodeIds,
            snapshot.episodes
                .singleWhere((state) => state.episodeId == added)
                .status,
          ],
          [
            [kept],
            [kept, added],
            EpisodeStatus.none,
          ],
          reason: b.wire.last.trace,
        );
      },
    );
  });
}
