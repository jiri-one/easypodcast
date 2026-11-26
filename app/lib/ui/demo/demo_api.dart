import 'dart:convert';

import '../../core/api.dart';
import '../../core/models.dart';
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
  }) async {
    if (loginErrorCode case final int code) {
      throw ApiException(code, 'Demo login error');
    }
    return const LoginResult(token: 'demo', deviceId: 1);
  }

  @override
  Future<void> logout() async {}

  @override
  Future<Fetched<List<Podcast>>?> podcasts({String? ifNoneMatch}) async =>
      Fetched(_library.allPodcasts, null);

  @override
  Future<Podcast> subscribe(String feedUrl) => _library.subscribe(feedUrl);

  @override
  Future<void> unsubscribe(int podcastId) => _library.unsubscribe(podcastId);

  @override
  Future<Fetched<List<Episode>>?> episodes(
    int podcastId, {
    String? ifNoneMatch,
  }) async {
    final podcast = _library.podcast(podcastId);
    if (podcast == null) throw ApiException(404, 'Podcast not found');
    final etag = '"${podcast.id}-${podcast.episodesVersion}"';
    if (etag == ifNoneMatch) return null;
    return Fetched(_library.episodesOf(podcastId), etag);
  }

  @override
  Future<({Episode episode, String description})> episode(int episodeId) async {
    final episode = _library.episode(episodeId);
    if (episode == null) throw ApiException(404, 'Episode not found');
    return (
      episode: episode,
      description: await _library.description(episodeId),
    );
  }

  @override
  Future<StateSnapshot> state() async => StateSnapshot(
    episodes: _library.states,
    queue: _library.queueState,
    serverTime: nowUtc(),
  );

  @override
  Future<StatePushResult> pushState({
    List<EpisodeState> episodes = const [],
    QueueState? queue,
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
  Future<void> refresh() async => _library.refreshFeeds();

  @override
  Future<String> exportOpml() async {
    const escape = HtmlEscape(HtmlEscapeMode.attribute);
    final outlines = [
      for (final podcast in _library.podcasts)
        '<outline type="rss" text="${escape.convert(podcast.title)}" '
            'xmlUrl="${escape.convert(podcast.feedUrl)}"/>',
    ].join('\n');
    return '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<opml version="2.0"><body>\n$outlines\n</body></opml>';
  }

  static final _opmlRoot = RegExp(r'<opml(?:\s|>)');
  static final _opmlUrl = RegExp(r'''\bxmlUrl\s*=\s*(?:"([^"]*)"|'([^']*)')''');
  static final _xmlEntity = RegExp(r'&(amp|quot|apos|lt|gt);');
  static const _xmlCharacters = {
    'amp': '&',
    'quot': '"',
    'apos': "'",
    'lt': '<',
    'gt': '>',
  };

  @override
  Future<OpmlImportResult> importOpml(String opml) async {
    if (!_opmlRoot.hasMatch(opml)) throw ApiException(422, 'Invalid OPML');
    final urls = {
      for (final match in _opmlUrl.allMatches(opml))
        (match[1] ?? match[2]!).replaceAllMapped(
          _xmlEntity,
          (entity) => _xmlCharacters[entity[1]]!,
        ),
    };
    final knownUrls = _library.allPodcasts
        .map((podcast) => podcast.feedUrl)
        .toSet();
    var added = 0;
    var existing = 0;
    final failed = <({String feedUrl, String error})>[];
    for (final url in urls) {
      try {
        final podcast = await subscribe(url);
        if (knownUrls.add(podcast.feedUrl)) {
          added++;
        } else {
          existing++;
        }
      } on ApiException catch (error) {
        failed.add((feedUrl: url, error: error.message));
      }
    }
    return OpmlImportResult(added: added, existing: existing, failed: failed);
  }
}
