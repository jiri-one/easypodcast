import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../core/api.dart';
import '../core/library.dart';
import '../core/models.dart';
import 'local_store.dart';
import 'state_confirmation.dart';

class SqfliteLibrary extends Library {
  SqfliteLibrary._(this._store, this._api, this._clock);

  static Future<SqfliteLibrary> open(
    LocalStore store,
    ApiClient api, {
    DateTime Function() clock = nowUtc,
  }) async {
    final library = SqfliteLibrary._(store, api, clock);
    library._loadFrom(await store.load());
    return library;
  }

  final LocalStore _store;
  final ApiClient _api;
  final DateTime Function() _clock;
  final _finished = StreamController<int>.broadcast();

  final Map<int, Podcast> _podcasts = {};
  final Map<int, List<Episode>> _episodesByPodcast = {};
  final Map<int, Episode> _episodes = {};
  final Map<int, EpisodeState> _states = {};
  final Set<int> _pendingStates = {};
  final Map<int, EpisodeListInfo> _episodeLists = {};
  QueueState? _queue;
  bool _queuePending = false;

  Map<int, int>? _playedCounts;
  List<Podcast>? _podcastList;
  List<Episode>? _inProgress;
  List<Episode>? _newEpisodes;
  List<Episode>? _queueEpisodes;

  /// Set by the sync service; remote records never touch this episode.
  int? playingEpisodeId;

  void Function()? onLocalChange;
  void Function()? onPendingSend;
  Future<StateSnapshot?> Function()? refreshStatesAndQueue;

  void _loadFrom(LocalSnapshot snapshot) {
    _podcasts
      ..clear()
      ..addAll({for (final p in snapshot.podcasts) p.id: p});
    _episodes.clear();
    _episodesByPodcast.clear();
    for (final e in snapshot.episodes) {
      _episodes[e.id] = e;
      (_episodesByPodcast[e.podcastId] ??= []).add(e);
    }
    _states
      ..clear()
      ..addAll({for (final s in snapshot.states) s.episodeId: s});
    _pendingStates
      ..clear()
      ..addAll(snapshot.pendingStates);
    _episodeLists
      ..clear()
      ..addAll(snapshot.episodeLists);
    _queue = snapshot.queue;
    _queuePending = snapshot.queuePending;
    _invalidate();
  }

  void _invalidate() {
    _playedCounts = null;
    _podcastList = null;
    _inProgress = null;
    _newEpisodes = null;
    _queueEpisodes = null;
  }

  void _changed() {
    _invalidate();
    notifyListeners();
  }

  @override
  void dispose() {
    _finished.close();
    super.dispose();
  }

  @override
  List<Podcast> get podcasts => _podcastList ??= _sortedPodcasts();

  Map<int, int> _computePlayedCounts() {
    final played = <int, int>{};
    for (final state in _states.values) {
      if (!state.isPlayed) continue;
      final podcastId = _episodes[state.episodeId]?.podcastId;
      if (podcastId != null) played[podcastId] = (played[podcastId] ?? 0) + 1;
    }
    return played;
  }

  List<Podcast> _sortedPodcasts() {
    final list = [
      for (final p in _podcasts.values)
        if (p.subscribed) _withPlayedCount(p),
    ];
    list.sort((a, b) {
      final byPlayed = b.playedCount.compareTo(a.playedCount);
      if (byPlayed != 0) return byPlayed;
      final byTitle = a.title.toLowerCase().compareTo(b.title.toLowerCase());
      return byTitle != 0 ? byTitle : a.id.compareTo(b.id);
    });
    return List.unmodifiable(list);
  }

  /// The local count includes plays not yet reflected in the server's podcast list.
  Podcast _withPlayedCount(Podcast p) {
    final localPlayed = (_playedCounts ??= _computePlayedCounts())[p.id] ?? 0;
    if (!_episodeLists.containsKey(p.id) || localPlayed == p.playedCount) {
      return p;
    }
    return Podcast(
      id: p.id,
      feedUrl: p.feedUrl,
      title: p.title,
      author: p.author,
      description: p.description,
      imageUrl: p.imageUrl,
      link: p.link,
      subscribed: p.subscribed,
      episodeCount: p.episodeCount,
      playedCount: localPlayed,
      episodesVersion: p.episodesVersion,
      lastSuccessAt: p.lastSuccessAt,
      lastError: p.lastError,
    );
  }

  @override
  Podcast? podcast(int podcastId) => _podcasts[podcastId] == null
      ? null
      : _withPlayedCount(_podcasts[podcastId]!);

  @override
  List<Episode> episodesOf(int podcastId) =>
      UnmodifiableListView(_episodesByPodcast[podcastId] ?? const <Episode>[]);

  @override
  Episode? episode(int episodeId) => _episodes[episodeId];

  @override
  EpisodeState stateOf(int episodeId) =>
      _states[episodeId] ?? EpisodeState.initial(episodeId);

  bool _isFinished(int episodeId) =>
      (_states[episodeId]?.status ?? EpisodeStatus.none) != EpisodeStatus.none;

  @override
  List<Episode> get inProgress => _inProgress ??= _computeInProgress();

  List<Episode> _computeInProgress() {
    final states = [
      for (final s in _states.values)
        if (s.isInProgress && _episodes.containsKey(s.episodeId)) s,
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List.unmodifiable([for (final s in states) _episodes[s.episodeId]!]);
  }

  @override
  List<Episode> get queue => _queueEpisodes ??= List.unmodifiable([
    for (final id in _queue?.episodeIds ?? const <int>[])
      if (!_isFinished(id)) ?_episodes[id],
  ]);

  @override
  int? get queueHeadId {
    for (final id in _queue?.episodeIds ?? const <int>[]) {
      if (!_isFinished(id)) return id;
    }
    return null;
  }

  @override
  Future<Episode?> resolveQueueEpisode(int episodeId) async {
    final cached = _episodes[episodeId];
    if (cached != null) return cached;
    try {
      final detail = await _api
          .episode(episodeId)
          .timeout(const Duration(seconds: 2));
      return _episodes[episodeId] ??
          (detail.episode.id == episodeId ? detail.episode : null);
    } on ApiException {
      return _episodes[episodeId];
    } on OfflineException {
      return _episodes[episodeId];
    } on TimeoutException {
      return _episodes[episodeId];
    }
  }

  QueueState? get queueState => _queue;

  @override
  List<Episode> newEpisodes({int limit = 100}) {
    final all = _newEpisodes ??= _computeNew();
    return all.length <= limit ? all : List.unmodifiable(all.take(limit));
  }

  List<Episode> _computeNew() {
    final list = <Episode>[];
    for (final p in _podcasts.values) {
      if (!p.subscribed) continue;
      for (final e in _episodesByPodcast[p.id] ?? const <Episode>[]) {
        if (!e.removedFromFeed && stateOf(e.id).isNew) list.add(e);
      }
    }
    list.sort((a, b) {
      final pa = a.publishedAt, pb = b.publishedAt;
      if (pa == null || pb == null) {
        if (pa != pb) return pa == null ? 1 : -1;
        return b.id.compareTo(a.id);
      }
      final byDate = pb.compareTo(pa);
      return byDate != 0 ? byDate : b.id.compareTo(a.id);
    });
    return List.unmodifiable(list);
  }

  @override
  Stream<int> get finishedEpisodes => _finished.stream;

  @override
  Future<String> description(int episodeId) async {
    final cached = await _store.description(episodeId);
    if (cached != null) return cached;
    final detail = await _api.episode(episodeId);
    await _store.setDescription(episodeId, detail.description);
    return detail.description;
  }

  @override
  Future<Podcast> subscribe(String feedUrl) async {
    final podcast = await _api.subscribe(feedUrl);
    await _store.upsertPodcast(podcast);
    _podcasts[podcast.id] = podcast;
    _changed();
    try {
      await refreshEpisodes(podcast);
    } on OfflineException {
      // The next pull fetches the list because its version is not stored yet.
    }
    return podcast;
  }

  @override
  Future<void> unsubscribe(int podcastId) async {
    await _api.unsubscribe(podcastId);
    final p = _podcasts[podcastId];
    if (p == null) return;
    final updated = Podcast(
      id: p.id,
      feedUrl: p.feedUrl,
      title: p.title,
      author: p.author,
      description: p.description,
      imageUrl: p.imageUrl,
      link: p.link,
      subscribed: false,
      episodeCount: p.episodeCount,
      playedCount: p.playedCount,
      episodesVersion: p.episodesVersion,
      lastSuccessAt: p.lastSuccessAt,
      lastError: p.lastError,
    );
    await _store.upsertPodcast(updated);
    _podcasts[podcastId] = updated;
    _changed();
  }

  @override
  Future<Duration> prepareForPlayback(int episodeId) async {
    final state = stateOf(episodeId);
    if (state.isPlayed || state.isDismissed) {
      await _setStates([_state(episodeId, 0, EpisodeStatus.none)]);
      return Duration.zero;
    }
    return Duration(milliseconds: state.positionMs);
  }

  @override
  Future<void> recordPosition(
    int episodeId,
    Duration position, {
    Duration? duration,
  }) => recordPositionAt(
    episodeId,
    position,
    duration: duration,
    updatedAt: _stamp(stateOf(episodeId).updatedAt),
  );

  @override
  Future<void> recordPositionAt(
    int episodeId,
    Duration position, {
    Duration? duration,
    required DateTime updatedAt,
  }) async {
    if (!_canRecord(episodeId, updatedAt)) return;
    await _setStates([
      _state(
        episodeId,
        position.isNegative ? 0 : position.inMilliseconds,
        EpisodeStatus.none,
        durationMs: duration?.inMilliseconds,
        updatedAt: updatedAt,
      ),
    ]);
  }

  @override
  Future<void> markCompleted(int episodeId) =>
      markCompletedAt(episodeId, _stamp(stateOf(episodeId).updatedAt));

  @override
  Future<void> markCompletedAt(int episodeId, DateTime updatedAt) async {
    if (!_canRecord(episodeId, updatedAt)) return;
    await _setStates([
      _state(episodeId, 0, EpisodeStatus.played, updatedAt: updatedAt),
    ]);
  }

  bool _canRecord(int episodeId, DateTime updatedAt) {
    final current = stateOf(episodeId);
    return current.status == EpisodeStatus.none &&
        updatedAt.isAfter(current.updatedAt);
  }

  @override
  void requestPendingSend() {
    if (hasPending) onPendingSend?.call();
  }

  @override
  Future<void> dismiss(int episodeId) async {
    if (stateOf(episodeId).isPlayed) return;
    await _finish([episodeId], EpisodeStatus.dismissed);
  }

  @override
  Future<void> dismissOlder(int episodeId) async {
    final snapshot = await refreshStatesAndQueue?.call();
    final chosen = _episodes[episodeId];
    if (chosen == null) return;
    final cutoff = chosen.publishedAt;
    final protectedIds = {
      ...?_queue?.episodeIds,
      for (final state in snapshot?.episodes ?? const <EpisodeState>[])
        if (!state.isNew && state.isNewerThan(stateOf(state.episodeId)))
          state.episodeId,
    };
    final ids = [
      for (final e in episodesOf(chosen.podcastId))
        if ((e.id == episodeId ||
                (cutoff != null &&
                    e.publishedAt != null &&
                    !e.publishedAt!.isAfter(cutoff))) &&
            stateOf(e.id).isNew &&
            !protectedIds.contains(e.id))
          e.id,
    ];
    await _finish(ids, EpisodeStatus.dismissed);
  }

  @override
  Future<void> markPlayed(int episodeId) =>
      _finish([episodeId], EpisodeStatus.played);

  @override
  Future<void> markNew(int episodeId) =>
      _setStates([_state(episodeId, 0, EpisodeStatus.none)]);

  Future<void> _finish(List<int> ids, EpisodeStatus status) async {
    if (ids.isEmpty) return;
    await _setStates([for (final id in ids) _state(id, 0, status)]);
  }

  @override
  Future<void> enqueue(int episodeId, {bool next = false}) async {
    await refreshStatesAndQueue?.call();
    final ids = _editableQueueIds();
    if (next) {
      ids.remove(episodeId);
      final firstVisible = ids.indexWhere(_episodes.containsKey);
      final afterPlaying =
          firstVisible >= 0 && ids[firstVisible] == playingEpisodeId;
      ids.insert(afterPlaying ? firstVisible + 1 : 0, episodeId);
    } else if (!ids.contains(episodeId)) {
      ids.add(episodeId);
    }
    if (_isFinished(episodeId)) {
      await _setStates([_state(episodeId, 0, EpisodeStatus.none)], queue: ids);
    } else {
      await _saveQueueEdit(ids);
    }
  }

  @override
  Future<void> dequeue(int episodeId) async {
    await refreshStatesAndQueue?.call();
    final ids = _editableQueueIds()..remove(episodeId);
    await _saveQueueEdit(ids);
  }

  @override
  Future<void> moveInQueue(int episodeId, int newIndex) async {
    await refreshStatesAndQueue?.call();
    final ids = _editableQueueIds();
    final visible = [
      for (final id in ids)
        if (_episodes.containsKey(id) || id == episodeId) id,
    ];
    final index = visible.indexOf(episodeId);
    if (index >= 0) {
      final target = newIndex.clamp(0, visible.length - 1);
      if (target != index) {
        final anchor = visible[target];
        ids.remove(episodeId);
        ids.insert(ids.indexOf(anchor) + (target > index ? 1 : 0), episodeId);
      }
    }
    await _saveQueueEdit(ids);
  }

  List<int> _editableQueueIds() => [
    for (final id in _queue?.episodeIds ?? const <int>[])
      if (!_isFinished(id)) id,
  ];

  Future<void> _saveQueueEdit(List<int> ids) async {
    if (listEquals(ids, _queue?.episodeIds ?? const <int>[])) return;
    await _setStates(const [], queue: ids);
  }

  EpisodeState _state(
    int episodeId,
    int positionMs,
    EpisodeStatus status, {
    int? durationMs,
    DateTime? updatedAt,
  }) {
    final previous = stateOf(episodeId);
    return EpisodeState(
      episodeId: episodeId,
      positionMs: positionMs,
      status: status,
      durationMs: durationMs ?? previous.durationMs,
      updatedAt: updatedAt ?? _stamp(previous.updatedAt),
    );
  }

  /// Keeps a local change newer than what it replaces even if the clock stepped back.
  DateTime _stamp(DateTime previous) {
    final now = _clock();
    return now.isAfter(previous)
        ? now
        : previous.add(const Duration(milliseconds: 1));
  }

  Future<void> _setStates(List<EpisodeState> states, {List<int>? queue}) async {
    final finished = <int>[];
    for (final state in states) {
      final before = stateOf(state.episodeId).status;
      _states[state.episodeId] = state;
      _pendingStates.add(state.episodeId);
      if (state.status != EpisodeStatus.none && state.status != before) {
        finished.add(state.episodeId);
      }
    }
    QueueState? newQueue;
    if (queue != null) {
      newQueue = QueueState(
        episodeIds: List.unmodifiable(queue),
        updatedAt: _stamp(_queue?.updatedAt ?? oldestTime),
      );
      _queue = newQueue;
      _queuePending = true;
    }
    final saved = _store.writeStates([
      for (final s in states) (s, true),
    ], queue: newQueue == null ? null : (newQueue, true));
    _changed();
    finished.forEach(_finished.add);
    await saved;
    onLocalChange?.call();
  }

  int get pendingCount => _pendingStates.length + (_queuePending ? 1 : 0);

  bool get hasPending => _pendingStates.isNotEmpty || _queuePending;

  bool hasPendingVersion(int? episodeId, DateTime updatedAt) =>
      episodeId == null
      ? _queuePending && _queue!.updatedAt.isAtSameMomentAs(updatedAt)
      : _pendingStates.contains(episodeId) &&
            _states[episodeId]!.updatedAt.isAtSameMomentAs(updatedAt);

  ({List<EpisodeState> states, QueueState? queue}) pendingChanges({
    int maxStates = 2000,
    bool Function(int? id, DateTime updatedAt)? include,
  }) => (
    states: _pendingStates
        .map((id) => _states[id]!)
        .where(
          (state) => include?.call(state.episodeId, state.updatedAt) ?? true,
        )
        .take(maxStates)
        .toList(),
    queue: _queuePending && (include?.call(null, _queue!.updatedAt) ?? true)
        ? _queue
        : null,
  );

  /// A reply settles only the sent versions, including server-unknown IDs.
  Future<bool> applyPushResult(
    List<EpisodeState> sent,
    QueueState? sentQueue,
    StatePushResult result,
  ) {
    result.requireConfirmation(sent, sentQueue);
    final acknowledged = {
      for (final state in sent)
        if (hasPendingVersion(state.episodeId, state.updatedAt))
          state.episodeId: state,
    };
    final acknowledgedQueue =
        sentQueue != null && hasPendingVersion(null, sentQueue.updatedAt)
        ? sentQueue
        : null;
    return _mergeRemote(
      [
        for (final state in result.episodes)
          if (acknowledged.containsKey(state.episodeId)) state,
      ],
      sentQueue == null || acknowledgedQueue != null ? result.queue : null,
      acknowledgedStates: acknowledged,
      acknowledgedQueue: acknowledgedQueue,
    );
  }

  Future<bool> applyRemote(
    List<EpisodeState> remote,
    QueueState? remoteQueue,
  ) => _mergeRemote(remote, remoteQueue);

  Future<bool> _mergeRemote(
    List<EpisodeState> remote,
    QueueState? remoteQueue, {
    Map<int, EpisodeState> acknowledgedStates = const {},
    QueueState? acknowledgedQueue,
  }) async {
    final written = Map.of(acknowledgedStates);
    _pendingStates.removeAll(acknowledgedStates.keys);
    var statesChanged = false;
    final finished = <int>[];
    for (final r in remote) {
      final local = _states[r.episodeId];
      final equalConfirmation =
          local != null &&
          acknowledgedStates.containsKey(r.episodeId) &&
          r.updatedAt.isAtSameMomentAs(local.updatedAt) &&
          (r.positionMs != local.positionMs ||
              r.status != local.status ||
              r.durationMs != local.durationMs);
      if (!equalConfirmation &&
          (r.episodeId == playingEpisodeId ||
              (local != null && !r.isNewerThan(local)))) {
        continue;
      }
      final before = local?.status ?? EpisodeStatus.none;
      _states[r.episodeId] = r;
      _pendingStates.remove(r.episodeId);
      written[r.episodeId] = r;
      statesChanged = true;
      if (r.status != EpisodeStatus.none && r.status != before) {
        finished.add(r.episodeId);
      }
    }
    final queueChanged =
        remoteQueue != null &&
        (remoteQueue.isNewerThan(_queue) ||
            (acknowledgedQueue != null &&
                remoteQueue.updatedAt.isAtSameMomentAs(_queue!.updatedAt) &&
                !listEquals(remoteQueue.episodeIds, _queue!.episodeIds)));
    if (queueChanged) _queue = remoteQueue;
    final writeQueue = queueChanged || acknowledgedQueue != null;
    if (writeQueue) _queuePending = false;
    if (written.isNotEmpty || writeQueue) {
      final saved = _store.writeStates(
        [for (final s in written.values) (s, false)],
        queue: writeQueue ? (_queue!, false) : null,
        acknowledgedStates: acknowledgedStates,
        acknowledgedQueue: acknowledgedQueue,
      );
      if (statesChanged || queueChanged) _changed();
      finished.forEach(_finished.add);
      await saved;
    }
    return remote.any((s) => !_episodes.containsKey(s.episodeId)) ||
        (remoteQueue?.episodeIds.any((id) => !_episodes.containsKey(id)) ??
            false);
  }

  /// Subscribed or not; the server also lists podcasts that only have states.
  Iterable<Podcast> get knownPodcasts => _podcasts.values;

  /// The episodes_version whose list is stored locally, null if none is.
  String? storedEpisodesVersion(int podcastId) =>
      _episodeLists[podcastId]?.version;

  Future<void> replacePodcasts(List<Podcast> podcasts) async {
    await _store.replacePodcasts(podcasts);
    final ids = {for (final p in podcasts) p.id};
    _podcasts
      ..clear()
      ..addAll({for (final p in podcasts) p.id: p});
    for (final gone
        in _episodesByPodcast.keys.where((id) => !ids.contains(id)).toList()) {
      for (final e in _episodesByPodcast.remove(gone)!) {
        _episodes.remove(e.id);
      }
    }
    _episodeLists.removeWhere((id, _) => !ids.contains(id));
    _changed();
  }

  Future<void> refreshEpisodes(
    Podcast podcast, {
    bool Function()? isCurrent,
  }) async {
    final stored = _episodeLists[podcast.id];
    if (stored != null && stored.version == podcast.episodesVersion) return;
    final fetched = await _api.episodes(podcast.id, ifNoneMatch: stored?.etag);
    if (isCurrent != null && !isCurrent()) return;
    if (fetched == null) {
      final info = EpisodeListInfo(podcast.episodesVersion, stored?.etag);
      await _store.setEpisodeListInfo(podcast.id, info);
      _episodeLists[podcast.id] = info;
      return;
    }
    final info = EpisodeListInfo(podcast.episodesVersion, fetched.etag);
    await _store.replaceEpisodes(podcast.id, fetched.value, info);
    for (final e in _episodesByPodcast[podcast.id] ?? const <Episode>[]) {
      _episodes.remove(e.id);
    }
    _episodesByPodcast[podcast.id] = fetched.value;
    for (final e in fetched.value) {
      _episodes[e.id] = e;
    }
    _episodeLists[podcast.id] = info;
    _changed();
  }

  Future<void> clear() async {
    await _store.clearLibrary();
    _loadFrom(await _store.load());
    notifyListeners();
  }
}
