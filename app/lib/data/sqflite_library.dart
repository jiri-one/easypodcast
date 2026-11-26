import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../core/api.dart';
import '../core/library.dart';
import '../core/models.dart';
import 'local_store.dart';

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
  final Map<int, bool> _pendingNewEpisodes = {};
  final Map<int, List<Episode>> _episodesByPodcast = {};
  final Map<int, Episode> _episodes = {};
  final Map<int, EpisodeState> _states = {};
  final Set<int?> _pending = {};
  final Map<int?, DateTime> _clockRejections = {};
  final Map<int, EpisodeListInfo> _episodeLists = {};
  QueueState? _queue;
  final _queueEdits = <void Function(List<int>)>[];
  bool _clearing = false;
  Future<void> _queueCommands = Future.value();

  Map<int, int>? _playedCounts;
  List<Podcast>? _podcastList;
  List<Episode>? _inProgress;
  List<Episode>? _queueEpisodes;

  /// Set by the sync service; remote records never touch this episode.
  int? playingEpisodeId;

  void Function({bool force})? onPendingSend;
  Future<List<EpisodeState>?> Function()? refreshStatesAndQueue;

  void _loadFrom(LocalSnapshot snapshot) {
    _podcasts
      ..clear()
      ..addAll({for (final p in snapshot.podcasts) p.id: p});
    _pendingNewEpisodes
      ..clear()
      ..addAll(snapshot.pendingNewEpisodes);
    _episodes.clear();
    _episodesByPodcast.clear();
    for (final e in snapshot.episodes) {
      _episodes[e.id] = e;
      (_episodesByPodcast[e.podcastId] ??= []).add(e);
    }
    _states
      ..clear()
      ..addAll({for (final s in snapshot.states) s.episodeId: s});
    _pending
      ..clear()
      ..addAll(snapshot.pendingStates);
    _clockRejections
      ..clear()
      ..addAll(snapshot.clockRejections);
    _episodeLists
      ..clear()
      ..addAll(snapshot.episodeLists);
    _queue = snapshot.queue;
    if (snapshot.queuePending) _pending.add(null);
    _invalidate();
  }

  void _invalidate() {
    _playedCounts = null;
    _podcastList = null;
    _inProgress = null;
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
        if (p.subscribed) _podcastView(p),
    ];
    list.sort((a, b) {
      final byPlayed = b.playedCount.compareTo(a.playedCount);
      if (byPlayed != 0) return byPlayed;
      final byTitle = a.title.toLowerCase().compareTo(b.title.toLowerCase());
      return byTitle != 0 ? byTitle : a.id.compareTo(b.id);
    });
    return List.unmodifiable(list);
  }

  bool _showInNewEpisodes(Podcast p) =>
      _pendingNewEpisodes[p.id] ?? p.showInNewEpisodes;

  Podcast _podcastView(Podcast p) {
    final show = _showInNewEpisodes(p);
    final played = _episodeLists.containsKey(p.id)
        ? (_playedCounts ??= _computePlayedCounts())[p.id] ?? 0
        : p.playedCount;
    if (show == p.showInNewEpisodes && played == p.playedCount) {
      return p;
    }
    return p.copyWith(playedCount: played, showInNewEpisodes: show);
  }

  @override
  Podcast? podcast(int podcastId) =>
      _podcasts[podcastId] == null ? null : _podcastView(_podcasts[podcastId]!);

  @override
  List<Episode> episodesOf(int podcastId) =>
      UnmodifiableListView(_episodesByPodcast[podcastId] ?? const <Episode>[]);

  @override
  Episode? episode(int episodeId) => _episodes[episodeId];

  @override
  EpisodeState stateOf(int episodeId) =>
      _states[episodeId] ?? EpisodeState.initial(episodeId);

  bool _isFinished(int episodeId) => _states[episodeId]?.isFinished ?? false;

  @override
  List<Episode> get inProgress => _inProgress ??= _computeInProgress();

  @override
  Episode? get recentUnfinishedEpisode {
    Episode? recent;
    DateTime? latest;
    for (final state in _states.values) {
      if (state.isFinished ||
          state.positionMs <= 0 ||
          (latest != null && !state.updatedAt.isAfter(latest))) {
        continue;
      }
      final episode = _episodes[state.episodeId];
      if (episode == null) continue;
      recent = episode;
      latest = state.updatedAt;
    }
    return recent;
  }

  List<Episode> _computeInProgress([EpisodeState? sample]) {
    final states = [
      for (final s in _states.values)
        if (s.isInProgress && _episodes.containsKey(s.episodeId))
          s.episodeId == sample?.episodeId ? sample! : s,
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
      final detail = await _api.episode(
        episodeId,
        timeout: const Duration(seconds: 2),
      );
      return _episodes[episodeId] ??
          (detail.episode.id == episodeId ? detail.episode : null);
    } on ApiException {
      return _episodes[episodeId];
    } on OfflineException {
      return _episodes[episodeId];
    }
  }

  QueueState? get queueState => _queue;

  @override
  List<Episode> newEpisodes({required DateTime since}) {
    final fresh =
        [
          for (final podcast in _podcasts.values)
            if (podcast.subscribed && _showInNewEpisodes(podcast))
              for (final e
                  in _episodesByPodcast[podcast.id] ?? const <Episode>[])
                if (!e.removedFromFeed &&
                    e.publishedAt?.isBefore(since) == false &&
                    (_states[e.id]?.isNew ?? true))
                  e,
        ]..sort((a, b) {
          final byDate = b.publishedAt!.compareTo(a.publishedAt!);
          return byDate != 0 ? byDate : b.id.compareTo(a.id);
        });
    return List.unmodifiable(fresh);
  }

  @override
  Stream<int> get finishedEpisodes => _finished.stream;

  @override
  Future<String> description(int episodeId) async {
    final cached = await _store.description(episodeId);
    String? version() =>
        _podcasts[_episodes[episodeId]?.podcastId]?.episodesVersion;
    final requestedVersion = version();
    if (cached != null &&
        (requestedVersion == null || cached.version == requestedVersion)) {
      return cached.text;
    }
    final String text;
    try {
      text = (await _api.episode(episodeId)).description;
    } on Exception {
      if (cached == null) rethrow;
      return cached.text;
    }
    await _store.setDescription(
      episodeId,
      text,
      requestedVersion,
      replace: requestedVersion == version(),
    );
    return text;
  }

  @override
  Future<Podcast> subscribe(String feedUrl) async {
    final subscription = await _api.subscribe(feedUrl);
    final podcast = await _store.saveSubscription(subscription);
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
    await _store.saveUnsubscribe(podcastId);
    final p = _podcasts[podcastId];
    if (p == null) return;
    _podcasts[podcastId] = p.copyWith(subscribed: false);
    _changed();
  }

  @override
  Future<void> setNewEpisodesVisibility(int podcastId, bool show) async {
    if (_clearing || !_podcasts.containsKey(podcastId)) return;
    await _store.queueNewEpisodesChange(podcastId, show);
    if (_clearing) return;
    _pendingNewEpisodes[podcastId] = show;
    _changed();
    requestPendingSend();
  }

  MapEntry<int, bool>? get pendingNewEpisodesChange =>
      _pendingNewEpisodes.entries.firstOrNull;

  Future<void> completeNewEpisodesChange(
    int podcastId,
    bool show, {
    required bool applied,
  }) async {
    final removed = await _store.completeNewEpisodesChange(
      podcastId,
      show,
      applied: applied,
    );
    if (_clearing) return;
    if (removed && _pendingNewEpisodes[podcastId] == show) {
      _pendingNewEpisodes.remove(podcastId);
    }
    final podcast = _podcasts[podcastId];
    if (applied && podcast != null) {
      _podcasts[podcastId] = podcast.copyWith(showInNewEpisodes: show);
    }
    _changed();
  }

  @override
  Future<Duration> prepareForPlayback(int episodeId) async {
    final state = stateOf(episodeId);
    if (state.isFinished) {
      await _setStates([_state(episodeId, 0, EpisodeStatus.none)]);
      return Duration.zero;
    }
    requestPendingSend();
    return state.resumePosition;
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
    updatedAt: stampAfter(stateOf(episodeId).updatedAt, _clock()),
  );

  @override
  Future<void> recordPositionAt(
    int episodeId,
    Duration position, {
    Duration? duration,
    required DateTime updatedAt,
  }) async {
    if (!_canRecord(episodeId, updatedAt)) return;
    final positionMs = position.isNegative ? 0 : position.inMilliseconds;
    final previous = stateOf(episodeId);
    if ((previous.positionMs - positionMs).abs() <=
        samePositionTolerance.inMilliseconds) {
      return;
    }
    final state = _state(
      episodeId,
      positionMs,
      EpisodeStatus.none,
      durationMs: duration?.inMilliseconds,
      updatedAt: updatedAt,
    );
    final visibleChange =
        episodeId != playingEpisodeId ||
        previous.durationMs != state.durationMs ||
        previous.isInProgress != state.isInProgress ||
        (previous.positionMs == 0) != (state.positionMs == 0) ||
        (state.isInProgress && _changesProgressOrder(state));
    await _setStates([state], forceSend: false, notify: visibleChange);
  }

  bool _changesProgressOrder(EpisodeState state) {
    final previous = inProgress;
    if (previous.firstOrNull?.id == state.episodeId &&
        state.updatedAt.isAfter(stateOf(state.episodeId).updatedAt)) {
      return false;
    }
    return !listEquals(previous, _computeInProgress(state));
  }

  @override
  Future<void> markCompleted(int episodeId) => markCompletedAt(
    episodeId,
    stampAfter(stateOf(episodeId).updatedAt, _clock()),
  );

  @override
  Future<void> markCompletedAt(int episodeId, DateTime updatedAt) async {
    if (!_canRecord(episodeId, updatedAt)) {
      requestPendingSend();
      return;
    }
    await _setStates([
      _state(episodeId, 0, EpisodeStatus.played, updatedAt: updatedAt),
    ]);
  }

  bool _canRecord(int episodeId, DateTime updatedAt) {
    final current = stateOf(episodeId);
    return !current.isFinished &&
        (updatedAt.isAfter(current.updatedAt) ||
            _correctedTime(episodeId, current.updatedAt) != null);
  }

  @override
  void requestPendingSend() {
    if (hasPending) onPendingSend?.call(force: true);
  }

  @override
  Future<void> dismiss(int episodeId) async {
    if (stateOf(episodeId).isPlayed) return;
    await _finish([episodeId], EpisodeStatus.dismissed);
  }

  @override
  Future<void> dismissOlder(int episodeId) async {
    final serverId = _store.meta(MetaKey.serverId);
    final refreshed = await refreshStatesAndQueue?.call();
    if (!_sameServer(serverId)) return;
    if (refreshed == null) throw BulkDismissNeedsConnection();
    final protectedIds = {
      for (final state in refreshed)
        if (!state.isNew && state.isNewerThan(stateOf(state.episodeId)))
          state.episodeId,
    };
    final ids = [
      for (final e in dismissOlderCandidates(episodeId))
        if (!protectedIds.contains(e.id)) e.id,
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
  bool get queueSaving => _queueEdits.isNotEmpty;

  @override
  List<Episode> get projectedQueue {
    if (!queueSaving) return queue;
    final ids = _editableQueueIds();
    for (final edit in _queueEdits) {
      edit(ids);
    }
    return List.unmodifiable([for (final id in ids) ?_episodes[id]]);
  }

  @override
  Future<void> enqueue(int episodeId, {bool next = false}) => _editQueue((ids) {
    if (next) {
      ids.remove(episodeId);
      final firstVisible = ids.indexWhere(_episodes.containsKey);
      final afterPlaying =
          firstVisible >= 0 && ids[firstVisible] == playingEpisodeId;
      ids.insert(afterPlaying ? firstVisible + 1 : 0, episodeId);
    } else if (!ids.contains(episodeId)) {
      ids.add(episodeId);
    }
  }, revive: episodeId);

  @override
  Future<void> dequeue(int episodeId) =>
      _editQueue((ids) => ids.remove(episodeId));

  @override
  Future<void> moveInQueue(int episodeId, int newIndex) => _editQueue((ids) {
    final visible = [
      for (final id in ids)
        if (_episodes.containsKey(id) || id == episodeId) id,
    ];
    final index = visible.indexOf(episodeId);
    if (index < 0) return;
    final target = newIndex.clamp(0, visible.length - 1);
    if (target == index) return;
    final anchor = visible[target];
    ids.remove(episodeId);
    ids.insert(ids.indexOf(anchor) + (target > index ? 1 : 0), episodeId);
  });

  Future<void> _editQueue(void Function(List<int>) edit, {int? revive}) {
    final serverId = _store.meta(MetaKey.serverId);
    final command = _queueCommands
        .then((_) async {
          if (!_sameServer(serverId)) return;
          await refreshStatesAndQueue?.call();
          if (!_sameServer(serverId)) return;
          final ids = _editableQueueIds();
          edit(ids);
          final states = [
            if (revive != null && _isFinished(revive))
              _state(revive, 0, EpisodeStatus.none),
          ];
          if (states.isNotEmpty ||
              !listEquals(ids, _queue?.episodeIds ?? const <int>[])) {
            await _setStates(states, queue: ids);
          }
        })
        .whenComplete(() {
          _queueEdits.remove(edit);
          notifyListeners();
        });
    _queueCommands = command.onError((Object _, StackTrace _) {});
    _queueEdits.add(edit);
    notifyListeners();
    return command;
  }

  bool _sameServer(String? serverId) =>
      !_clearing &&
      (serverId == null || serverId == _store.meta(MetaKey.serverId));

  List<int> _editableQueueIds() => [
    for (final id in _queue?.episodeIds ?? const <int>[])
      if (!_isFinished(id)) id,
  ];

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
      updatedAt:
          _correctedTime(episodeId, previous.updatedAt) ??
          updatedAt ??
          stampAfter(previous.updatedAt, _clock()),
    );
  }

  DateTime? _correctedTime(int? id, DateTime previous) {
    if (_clockRejections[id] != previous) return null;
    final now = _clock();
    return now.isBefore(previous) ? now : null;
  }

  void _updateClockRejection(int? id, DateTime at) {
    final rejected = _clockRejections[id];
    if (rejected == null) return;
    if (at.isBefore(rejected)) {
      _clockRejections.remove(id);
    } else {
      _clockRejections[id] = at;
    }
  }

  Future<void> _write(Set<int?> ids, {DateTime? lastSync}) =>
      _store.writeStates(
        [for (final id in ids.whereType<int>()) _states[id]!],
        queue: ids.contains(null) ? _queue : null,
        pending: _pending,
        clockRejections: _clockRejections,
        lastSync: lastSync,
      );

  Future<void> _setStates(
    List<EpisodeState> states, {
    List<int>? queue,
    bool forceSend = true,
    bool notify = true,
  }) async {
    if (_clearing) return;
    final finished = <int>[];
    for (final state in states) {
      final before = stateOf(state.episodeId).status;
      _states[state.episodeId] = state;
      _pending.add(state.episodeId);
      _updateClockRejection(state.episodeId, state.updatedAt);
      if (state.isFinished && state.status != before) {
        finished.add(state.episodeId);
      }
    }
    if (queue != null) {
      final previous = _queue?.updatedAt ?? oldestTime;
      _queue = QueueState(
        episodeIds: List.unmodifiable(queue),
        updatedAt:
            _correctedTime(null, previous) ?? stampAfter(previous, _clock()),
      );
      _pending.add(null);
      _updateClockRejection(null, _queue!.updatedAt);
    }
    final saved = _write({
      for (final s in states) s.episodeId,
      if (queue != null) null,
    });
    if (notify) _changed();
    finished.forEach(_finished.add);
    await saved;
    onPendingSend?.call(force: forceSend);
  }

  int get pendingCount => _pending.length + _pendingNewEpisodes.length;

  bool get hasPending => pendingCount != 0;
  bool get hasClockRejections => _clockRejections.isNotEmpty;
  bool get hasUnrejectedPending => pendingCount > _clockRejections.length;

  bool _repairTime(int? id, DateTime now) {
    if (!now.isBefore(_clockRejections[id]!)) return false;
    _clockRejections.remove(id);
    if (id == null) {
      _queue = QueueState(episodeIds: _queue!.episodeIds, updatedAt: now);
    } else {
      final state = _states[id]!;
      _states[id] = EpisodeState(
        episodeId: id,
        positionMs: state.positionMs,
        status: state.status,
        durationMs: state.durationMs,
        updatedAt: now,
      );
    }
    return true;
  }

  Future<void> repairRejectedTimes() async {
    final now = _clock();
    final repaired = {
      for (final id in _clockRejections.keys.toList())
        if (_repairTime(id, now)) id,
    };
    if (repaired.isEmpty) return;
    final saved = _write(repaired);
    _changed();
    await saved;
  }

  ({List<EpisodeState> states, QueueState? queue}) pendingChanges({
    bool includeRejected = true,
  }) => (
    states: _pending
        .whereType<int>()
        .where((id) => includeRejected || !_clockRejections.containsKey(id))
        .take(2000)
        .map((id) => _states[id]!)
        .toList(),
    queue:
        _pending.contains(null) &&
            (includeRejected || !_clockRejections.containsKey(null))
        ? _queue
        : null,
  );

  Future<bool> applyPushResult(
    List<EpisodeState> sent,
    QueueState? sentQueue,
    StatePushResult result,
    DateTime lastSync,
  ) {
    final echoed = <int?, DateTime>{
      for (final s in result.episodes) s.episodeId: s.updatedAt,
      if (result.queue case final queue?) null: queue.updatedAt,
    };
    final skipped = {...result.future, ...result.unknown};
    final current = <int?>{};
    void confirm(int? id, DateTime sentAt, bool stillCurrent) {
      final at = echoed[id];
      if (!skipped.contains(id) &&
          (at == null ||
              at.millisecondsSinceEpoch < sentAt.millisecondsSinceEpoch)) {
        throw FormatException(
          'Missing confirmation for ${id == null ? 'queue' : 'episode $id'}',
        );
      }
      if (stillCurrent && _pending.contains(id)) current.add(id);
    }

    for (final state in sent) {
      confirm(
        state.episodeId,
        state.updatedAt,
        identical(_states[state.episodeId], state),
      );
    }
    if (sentQueue != null) {
      confirm(null, sentQueue.updatedAt, identical(_queue, sentQueue));
    }
    final rejected = current.intersection(result.future);
    final accepted = current.difference(rejected);
    for (final id in rejected) {
      _clockRejections[id] = id == null
          ? _queue!.updatedAt
          : _states[id]!.updatedAt;
    }
    return _mergeRemote(
      [
        for (final state in result.episodes)
          if (accepted.contains(state.episodeId)) state,
      ],
      sentQueue == null || accepted.contains(null) ? result.queue : null,
      acknowledged: accepted,
      rejected: rejected,
      lastSync: lastSync,
    );
  }

  Future<bool> applyRemote(
    List<EpisodeState> remote,
    QueueState? remoteQueue,
  ) => _mergeRemote(remote, remoteQueue);

  Future<bool> _mergeRemote(
    List<EpisodeState> remote,
    QueueState? remoteQueue, {
    Set<int?> acknowledged = const {},
    Set<int?> rejected = const {},
    DateTime? lastSync,
  }) async {
    final written = {...acknowledged, ...rejected};
    _pending
      ..removeAll(written)
      ..addAll(rejected);
    var changed = false;
    for (final id in rejected) {
      if (_repairTime(id, _clock())) changed = true;
    }
    final finished = <int>[];
    for (final r in remote) {
      final local = _states[r.episodeId];
      final equalConfirmation =
          local != null &&
          acknowledged.contains(r.episodeId) &&
          r.updatedAt.millisecondsSinceEpoch ==
              local.updatedAt.millisecondsSinceEpoch &&
          (r.positionMs != local.positionMs ||
              r.status != local.status ||
              r.durationMs != local.durationMs);
      if (!equalConfirmation &&
          (r.episodeId == playingEpisodeId ||
              (local != null && !r.isNewerThan(local)))) {
        continue;
      }
      _states[r.episodeId] = r;
      _pending.remove(r.episodeId);
      written.add(r.episodeId);
      changed = true;
      if (r.isFinished && r.status != local?.status) finished.add(r.episodeId);
    }
    if (remoteQueue != null &&
        (remoteQueue.isNewerThan(_queue) ||
            (acknowledged.contains(null) &&
                remoteQueue.updatedAt.millisecondsSinceEpoch ==
                    _queue!.updatedAt.millisecondsSinceEpoch &&
                !listEquals(remoteQueue.episodeIds, _queue!.episodeIds)))) {
      _queue = remoteQueue;
      _pending.remove(null);
      written.add(null);
      changed = true;
    }
    if (written.isNotEmpty || lastSync != null) {
      _clockRejections.removeWhere((id, _) => !_pending.contains(id));
      final saved = _write(written, lastSync: lastSync);
      if (changed) _changed();
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
    final byId = {for (final p in podcasts) p.id: p};
    final removed = _podcasts.keys.toSet().difference(byId.keys.toSet());
    await _store.replacePodcasts(podcasts, removed);
    _podcasts
      ..clear()
      ..addAll(byId);
    for (final id in removed) {
      for (final e in _episodesByPodcast.remove(id) ?? const <Episode>[]) {
        _episodes.remove(e.id);
      }
      _episodeLists.remove(id);
    }
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

  Future<void> clear(String serverId) async {
    _clearing = true;
    _queueEdits.clear();
    try {
      await _store.clearLibrary(serverId);
      _loadFrom(await _store.load());
      playingEpisodeId = null;
    } finally {
      _clearing = false;
    }
    notifyListeners();
  }
}
