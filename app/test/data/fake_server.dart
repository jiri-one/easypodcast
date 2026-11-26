import 'dart:async';
import 'dart:convert';

import 'package:easypodcast/core/api.dart';
import 'package:easypodcast/core/models.dart';
import 'package:easypodcast/data/default_sync_service.dart';
import 'package:easypodcast/data/http_api_client.dart';
import 'package:easypodcast/data/local_store.dart';
import 'package:easypodcast/data/sqflite_library.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// One clock for all devices and the server, moved by the test.
class TestClock {
  TestClock([DateTime? start]) : now = start ?? DateTime.utc(2026, 11, 20, 8);

  DateTime now;

  DateTime call() => now;

  void advance(Duration delta) => now = now.add(delta);
}

/// The server's state rules (docs/architecture.md, rules 1 to 4) kept in memory.
class FakeServer {
  FakeServer(this.clock);

  final TestClock clock;
  String serverId = '342896fe-729d-489a-86db-1e035275f3d1';
  final Map<int, Podcast> _podcasts = {};
  final Map<int, List<Episode>> _episodes = {};
  final Map<int, EpisodeState> states = {};
  final Map<int, String> descriptions = {};
  QueueState? queue;
  int _versionCounter = 0;
  int _nextEpisodeId = 1000;

  Iterable<int> get episodeIds =>
      _episodes.values.expand((list) => list.map((e) => e.id));

  Podcast addPodcast(int id, String title, {bool subscribed = true}) {
    final podcast = Podcast(
      id: id,
      feedUrl: 'https://feeds.example.test/$id.xml',
      title: title,
      subscribed: subscribed,
      episodesVersion: 'v${++_versionCounter}',
    );
    _podcasts[id] = podcast;
    _episodes[id] = [];
    return podcast;
  }

  List<int> addEpisodes(int podcastId, int count, {DateTime? firstPublished}) {
    final start = firstPublished ?? DateTime.utc(2026, 1, 1);
    final list = _episodes[podcastId]!;
    final ids = <int>[];
    for (var i = 0; i < count; i++) {
      final id = _nextEpisodeId++;
      ids.add(id);
      list.insert(
        0,
        Episode(
          id: id,
          podcastId: podcastId,
          title: 'Episode $id',
          enclosureUrl: 'https://media.example.test/$id.mp3',
          publishedAt: start.add(Duration(days: list.length)),
        ),
      );
      descriptions[id] = 'About episode $id';
    }
    _bump(podcastId);
    return ids;
  }

  void _bump(int podcastId) {
    final p = _podcasts[podcastId]!;
    _podcasts[podcastId] = p.copyWith(
      episodeCount: _episodes[podcastId]!.length,
      episodesVersion: 'v${++_versionCounter}',
    );
  }

  void setSubscribed(int podcastId, bool subscribed) => _podcasts[podcastId] =
      _podcasts[podcastId]!.copyWith(subscribed: subscribed);

  void setShowInNewEpisodes(int podcastId, bool show) => _podcasts[podcastId] =
      _podcasts[podcastId]!.copyWith(showInNewEpisodes: show);

  List<Podcast> listPodcasts() {
    final result = <Podcast>[];
    for (final p in _podcasts.values) {
      final ids = {for (final e in _episodes[p.id]!) e.id};
      final withState = states.keys.where(ids.contains);
      if (!p.subscribed && withState.isEmpty) continue;
      result.add(
        p.copyWith(
          episodeCount: ids.length,
          playedCount: withState.where((id) => states[id]!.isPlayed).length,
        ),
      );
    }
    return result;
  }

  List<Episode>? listEpisodes(int podcastId) => _episodes[podcastId];

  StatePushResult push(List<EpisodeState> incoming, QueueState? q) {
    final limit = clock().add(const Duration(hours: 24));
    final future = <int?>{};
    if (q != null && q.updatedAt.isAfter(limit)) {
      future.add(null);
      q = null;
    }
    final known = episodeIds.toSet();
    final unknown = <int>[];
    final order = <int>[];
    for (final s in incoming) {
      if (s.updatedAt.isAfter(limit)) {
        future.add(s.episodeId);
        continue;
      }
      if (!order.contains(s.episodeId)) order.add(s.episodeId);
      if (!known.contains(s.episodeId)) {
        if (!unknown.contains(s.episodeId)) unknown.add(s.episodeId);
        continue;
      }
      final current = states[s.episodeId];
      if (current == null || s.isNewerThan(current)) states[s.episodeId] = s;
    }
    if (q != null) {
      for (final id in q.episodeIds) {
        if (!known.contains(id) && !unknown.contains(id)) unknown.add(id);
      }
      if (q.isNewerThan(queue)) {
        queue = QueueState(
          episodeIds: [
            for (final id in q.episodeIds)
              if (known.contains(id)) id,
          ],
          updatedAt: q.updatedAt,
        );
      }
    }
    return StatePushResult(
      episodes: [
        for (final id in order)
          if (states[id] != null) states[id]!,
      ],
      queue: queue,
      future: future,
      unknown: unknown,
      serverId: serverId,
    );
  }
}

Map<String, Object?> episodeJson(Episode e) => {
  'id': e.id,
  'podcast_id': e.podcastId,
  'title': e.title,
  'published_at': e.publishedAt?.toIso8601String(),
  'enclosure_url': e.enclosureUrl,
  'enclosure_length': e.enclosureLength,
  'duration_s': e.durationS,
  'image_url': e.imageUrl,
  'removed_from_feed': e.removedFromFeed,
};

class FakeApiClient implements HttpApiClient {
  FakeApiClient(this.server);

  final FakeServer server;
  bool online = true;
  @override
  String? token;
  @override
  String serverUrl = 'https://podcasts.example.test';
  @override
  final timeout = const Duration(seconds: 10);
  @override
  void Function()? onUnauthorized;
  int? statusOverride;
  Duration? episodeStateDelay;
  Duration? episodeStateTimeout;
  Future<void> Function()? beforeStateReply;
  Future<void> Function()? beforePodcasts;
  Future<void> Function(int)? beforeEpisodes;
  Future<void> Function(int)? beforeEpisode;
  Future<void> Function()? beforePush;
  StatePushResult Function(StatePushResult)? transformPushResult;

  int pushCalls = 0;
  int stateCalls = 0;
  int stateNotModified = 0;
  int podcastsCalls = 0;
  final Map<int, int> episodesCalls = {};
  final Map<int, int> episodesNotModified = {};
  final List<List<EpisodeState>> pushedStates = [];
  final List<QueueState?> pushedQueues = [];
  final List<String> syncCalls = [];

  void _check({bool auth = true}) {
    if (!online) throw OfflineException('no network');
    if (statusOverride case final status?) {
      throw ApiException(status, 'forced $status');
    }
    if (auth && token == null) {
      throw ApiException(401, 'valid bearer token required');
    }
  }

  Future<void> _wait(Future<void>? hook, Duration? timeout) async {
    if (hook == null) return;
    await (timeout == null
        ? hook
        : hook.timeout(timeout, onTimeout: () => throw OfflineException()));
  }

  String _tag(Object value) => '"${jsonEncode(value).hashCode}"';

  @override
  Future<LoginResult> login({
    required String serverUrl,
    required String username,
    required String password,
    required String deviceName,
    Duration? timeout,
  }) async {
    _check(auth: false);
    if (password != 'secret') throw ApiException(401, 'wrong credentials');
    token = 'token-$deviceName';
    this.serverUrl = HttpApiClient.normalizeServerUrl(serverUrl);
    return LoginResult(
      token: token!,
      deviceId: deviceName.hashCode.abs(),
      serverId: server.serverId,
    );
  }

  @override
  Future<void> logout({Duration? timeout}) async {
    syncCalls.add('logout');
    try {
      _check();
    } finally {
      token = null;
    }
  }

  @override
  Future<Fetched<List<Podcast>>?> podcasts({
    String? ifNoneMatch,
    Duration? timeout,
  }) async {
    _check();
    podcastsCalls++;
    syncCalls.add('podcasts');
    await _wait(beforePodcasts?.call(), timeout);
    final list = server.listPodcasts();
    final tag = _tag([
      for (final p in list)
        [
          p.id,
          p.episodesVersion,
          p.subscribed,
          p.playedCount,
          p.showInNewEpisodes,
        ],
    ]);
    if (tag == ifNoneMatch) return null;
    return Fetched(list, tag);
  }

  @override
  Future<Podcast> subscribe(String feedUrl, {Duration? timeout}) async {
    _check();
    final id = int.parse(Uri.parse(feedUrl).pathSegments.last.split('.').first);
    server.setSubscribed(id, true);
    return server.listPodcasts().firstWhere((p) => p.id == id);
  }

  @override
  Future<void> unsubscribe(int podcastId, {Duration? timeout}) async {
    _check();
    server.setSubscribed(podcastId, false);
  }

  @override
  Future<void> setShowInNewEpisodes(
    int podcastId,
    bool show, {
    Duration? timeout,
  }) async {
    _check();
    server.setShowInNewEpisodes(podcastId, show);
  }

  @override
  Future<Fetched<List<Episode>>?> episodes(
    int podcastId, {
    String? ifNoneMatch,
    Duration? timeout,
  }) async {
    _check();
    episodesCalls[podcastId] = (episodesCalls[podcastId] ?? 0) + 1;
    await _wait(beforeEpisodes?.call(podcastId), timeout);
    final list = server.listEpisodes(podcastId);
    if (list == null) throw ApiException(404, 'not found');
    final tag = _tag([for (final e in list) episodeJson(e)]);
    if (tag == ifNoneMatch) {
      episodesNotModified[podcastId] =
          (episodesNotModified[podcastId] ?? 0) + 1;
      return null;
    }
    return Fetched(List.of(list), tag);
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
    _check();
    await _wait(beforeEpisode?.call(episodeId), timeout);
    final episode = server._episodes.values
        .expand((l) => l)
        .where((e) => e.id == episodeId)
        .firstOrNull;
    if (episode == null) throw ApiException(404, 'not found');
    return (episode: episode, description: server.descriptions[episodeId]!);
  }

  @override
  Future<Fetched<StateSnapshot>?> fetchState({
    String? ifNoneMatch,
    Duration? timeout,
  }) async {
    _check();
    stateCalls++;
    syncCalls.add('state');
    final snapshot = StateSnapshot(
      episodes: server.states.values.toList(),
      queue: server.queue,
      serverTime: server.clock(),
      serverId: server.serverId,
    );
    final tag = _tag([
      snapshot.serverId,
      for (final state in snapshot.episodes) state.toJson(),
      snapshot.queue?.toJson(),
    ]);
    await _wait(beforeStateReply?.call(), timeout);
    if (tag == ifNoneMatch) {
      stateNotModified++;
      return null;
    }
    return Fetched(snapshot, tag);
  }

  @override
  Future<StatePushResult> pushState({
    String? serverId,
    List<EpisodeState> episodes = const [],
    QueueState? queue,
    Duration? timeout,
  }) async {
    _check();
    pushCalls++;
    syncCalls.add('push');
    pushedStates.add(List.of(episodes));
    pushedQueues.add(queue);
    await _wait(beforePush?.call(), timeout);
    if (serverId != null && serverId != server.serverId) {
      throw ApiException(
        409,
        'server identity changed',
        serverId: server.serverId,
      );
    }
    final result = server.push(episodes, queue);
    return transformPushResult?.call(result) ?? result;
  }

  @override
  Future<EpisodeState?> episodeState(int episodeId, {Duration? timeout}) async {
    _check();
    syncCalls.add('episode:$episodeId');
    episodeStateTimeout = timeout;
    if (episodeStateDelay case final delay?) {
      await _wait(Future<void>.delayed(delay), timeout);
    }
    return server.states[episodeId];
  }

  @override
  Future<void> refresh({Duration? timeout}) async => _check();

  @override
  Future<String> exportOpml({Duration? timeout}) async {
    _check();
    return '<opml version="2.0"><body/></opml>';
  }

  @override
  Future<OpmlImportResult> importOpml(String opml, {Duration? timeout}) async {
    _check();
    return const OpmlImportResult(added: 0, existing: 0, failed: []);
  }
}

/// One phone or PC: its own database, library and sync service against the shared server.
class Device {
  Device._(this.db, this.store, this.api, this.library, this.sync);

  final Database db;
  final LocalStore store;
  final FakeApiClient api;
  final SqfliteLibrary library;
  final DefaultSyncService sync;

  static int _nextDatabase = 0;

  static Future<Device> open(
    FakeServer server, {
    Database? db,
    TestClock? deviceClock,
    Stream<bool>? networkUp,
    bool observeLifecycle = false,
    Duration pullInterval = const Duration(minutes: 15),
    Duration initialBackoff = const Duration(milliseconds: 20),
    Duration maxBackoff = const Duration(milliseconds: 160),
    Duration freshStateTimeout = const Duration(milliseconds: 100),
    Duration queueRefreshTimeout = const Duration(seconds: 2),
    Duration logoutSendTimeout = const Duration(seconds: 2),
  }) async {
    final database =
        db ??
        await LocalStore.open(
          databaseFactoryFfi,
          'file:device-${++_nextDatabase}?mode=memory',
        );
    final store = LocalStore(database);
    final api = FakeApiClient(server);
    final library = await SqfliteLibrary.open(
      store,
      api,
      clock: (deviceClock ?? server.clock).call,
    );
    api.token = store.meta(MetaKey.token);
    final sync = DefaultSyncService(
      api: api,
      library: library,
      store: store,
      networkUp: networkUp,
      observeLifecycle: observeLifecycle,
      pullInterval: pullInterval,
      initialBackoff: initialBackoff,
      maxBackoff: maxBackoff,
      freshStateTimeout: freshStateTimeout,
      queueRefreshTimeout: queueRefreshTimeout,
      logoutSendTimeout: logoutSendTimeout,
      clock: (deviceClock ?? server.clock).call,
    );
    return Device._(database, store, api, library, sync);
  }

  Future<void> loginAndStart(String name) async {
    await sync.login(
      serverUrl: 'https://podcasts.example.test',
      username: 'listener',
      password: 'secret',
      deviceName: name,
    );
    await sync.start();
    await sync.whenIdle();
  }

  Future<void> close() async {
    await sync.stop();
    sync.dispose();
    library.dispose();
    await db.close();
  }
}

Future<void> settle([Duration delay = Duration.zero]) =>
    Future<void>.delayed(delay);
