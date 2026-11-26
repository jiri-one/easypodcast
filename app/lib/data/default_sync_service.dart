import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../core/api.dart';
import '../core/models.dart';
import '../core/settings.dart';
import '../core/sync.dart';
import 'http_api_client.dart';
import 'local_store.dart';
import 'sqflite_library.dart';

typedef _RejectedVersion = ({
  DateTime updatedAt,
  Duration backoff,
  Duration retryAt,
  String error,
});

const _futureTimeError =
    'updated_at is more than 24 hours ahead of server time';

class _SyncOperation {
  Future<bool>? running;
  Timer? retry;
  Duration? backoff;
  Object? error;
  int forceGeneration = 0;

  bool get waiting => retry?.isActive ?? false;

  void force() {
    forceGeneration++;
    retry?.cancel();
  }

  void clearBackoff() {
    retry?.cancel();
    retry = null;
    backoff = null;
    error = null;
  }
}

class DefaultSyncService with WidgetsBindingObserver implements SyncService {
  DefaultSyncService({
    required this._api,
    required SqfliteLibrary library,
    required LocalStore store,
    this._settings,
    this.observeLifecycle = true,
    this.initialBackoff = const Duration(seconds: 5),
    this.maxBackoff = const Duration(minutes: 5),
    this.pullInterval = const Duration(minutes: 15),
    this.freshStateTimeout = const Duration(seconds: 2),
    this.queueRefreshTimeout = const Duration(seconds: 2),
    this.logoutSendTimeout = const Duration(seconds: 2),
    this._clock = nowUtc,
  }) : _library = library,
       _store = store {
    final last = store.meta(MetaKey.lastSync);
    _lastSuccess = last == null ? null : DateTime.tryParse(last)?.toUtc();
    _status = ValueNotifier(
      SyncStatus(
        phase: isLoggedIn ? SyncPhase.idle : SyncPhase.loggedOut,
        lastSuccess: _lastSuccess,
        pending: library.pendingCount,
      ),
    );
    library.onPendingSend = _request;
    library.refreshStatesAndQueue = _refreshStatesAndQueue;
  }

  final ApiClient _api;
  final SqfliteLibrary _library;
  final LocalStore _store;
  final Settings? _settings;
  final DateTime Function() _clock;

  /// Tests drive the lifecycle by calling [didChangeAppLifecycleState] themselves.
  final bool observeLifecycle;
  final Duration initialBackoff;
  final Duration maxBackoff;
  final Duration pullInterval;
  final Duration freshStateTimeout;
  final Duration queueRefreshTimeout;
  final Duration logoutSendTimeout;

  late final ValueNotifier<SyncStatus> _status;
  DateTime? _lastSuccess;
  Duration? _clockSkewWarning;

  bool _started = false;
  bool _observing = false;
  bool _foreground = false;
  bool _pullWanted = false;
  bool _loggingOut = false;
  int _session = 0;
  final _send = _SyncOperation();
  final _catalogue = _SyncOperation();
  Timer? _rejectedRetryTimer;
  Timer? _pullTimer;
  final _elapsed = Stopwatch()..start();
  final _rejected = <int?, _RejectedVersion>{};

  @override
  ValueListenable<SyncStatus> get status => _status;

  @override
  bool get isLoggedIn => _store.meta(MetaKey.token) != null;

  @visibleForTesting
  Duration? get currentBackoff => _send.backoff ?? _catalogue.backoff;

  @visibleForTesting
  bool get retryScheduled =>
      _send.waiting ||
      _catalogue.waiting ||
      (_rejectedRetryTimer?.isActive ?? false);

  @override
  Future<void> login({
    required String serverUrl,
    required String username,
    required String password,
    required String deviceName,
  }) async {
    final result = await _api.login(
      serverUrl: serverUrl,
      username: username,
      password: password,
      deviceName: deviceName,
    );
    _endSessionWork();
    final normalized = HttpApiClient.normalizeServerUrl(serverUrl);
    final previous = _store.meta(MetaKey.serverUrl);
    if (previous != null && previous != normalized) {
      // Ids belong to one server; another server's records would collide with them.
      await _library.clear();
    }
    await _store.setMeta(MetaKey.serverUrl, normalized);
    await _store.setMeta(MetaKey.deviceId, '${result.deviceId}');
    await _store.setMeta(MetaKey.deviceName, deviceName);
    await _store.setMeta(MetaKey.token, result.token);
    _settings
      ?..serverUrl = normalized
      ..deviceName = deviceName;
    _setStatus(SyncPhase.idle);
    if (_started) {
      _startPullTimer();
      _request(pull: true, force: true);
    }
  }

  @override
  Future<void> logout() async {
    if (_loggingOut) return;
    _loggingOut = true;
    _cancelTimers();
    try {
      await _flushPending(_session, logoutSendTimeout, Stopwatch()..start());
    } on Object {
      // Pending changes survive an unavailable server.
    }
    _endSessionWork();
    try {
      await _api.logout();
    } on Object {
      // The local session ends even if the server cannot be told.
    } finally {
      await _store.setMeta(MetaKey.token, null);
      _loggingOut = false;
      _setStatus(SyncPhase.loggedOut);
    }
  }

  /// The server rejected the token: the user has to log in again, local changes stay.
  void handleUnauthorized() {
    if (!isLoggedIn) return;
    _endSessionWork();
    unawaited(_store.setMeta(MetaKey.token, null));
    _setStatus(SyncPhase.loggedOut);
  }

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;
    if (observeLifecycle && !_observing) {
      _foreground =
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
    if (!isLoggedIn) {
      _setStatus(SyncPhase.loggedOut);
      return;
    }
    _startPullTimer();
    // Not awaited: an offline start must not hold up the first frame.
    _request(pull: true, force: true);
  }

  @override
  Future<void> stop() async {
    if (!_started) return;
    _cancelTimers();
    if (isLoggedIn && _library.hasPending) _request(force: true);
    await whenIdle();
    _cancelTimers();
    _started = false;
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
  }

  @override
  Future<void> syncNow() async {
    if (!isLoggedIn) return;
    _request(pull: true, force: true);
    await whenIdle();
  }

  @override
  Future<void> freshStateBeforePlay(int episodeId) async {
    if (!isLoggedIn || _loggingOut) return;
    final session = _session;
    final watch = Stopwatch()..start();
    try {
      await _flushPending(session, freshStateTimeout, watch);
      final remaining = freshStateTimeout - watch.elapsed;
      if (remaining <= Duration.zero || !_inSession(session) || _loggingOut) {
        return;
      }
      final remote = await _api
          .episodeState(episodeId, timeout: remaining)
          .timeout(remaining);
      if (remote == null ||
          remote.episodeId != episodeId ||
          !_inSession(session) ||
          _loggingOut) {
        return;
      }
      await _applyRemote(session, [remote], null);
    } on ApiException catch (e) {
      if (e.statusCode == 401 && _inSession(session)) handleUnauthorized();
    } on Object {
      // Offline or slow: playback starts from the local state.
    } finally {
      _kick();
    }
  }

  @override
  void setPlayingEpisode(int? episodeId) {
    _library.playingEpisodeId = episodeId;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (_foreground) return;
        _foreground = true;
        if (!_started || !isLoggedIn) return;
        _startPullTimer();
        _request(pull: true, force: true);
      case AppLifecycleState.paused ||
          AppLifecycleState.hidden ||
          AppLifecycleState.detached:
        _foreground = false;
        _pullTimer?.cancel();
        _pullTimer = null;
        if (_started && isLoggedIn && _library.hasPending) {
          _request(force: true);
        }
      case AppLifecycleState.inactive:
        break;
    }
  }

  @visibleForTesting
  Future<void> whenIdle() async {
    while (_send.running != null || _catalogue.running != null) {
      await Future.wait([?_send.running, ?_catalogue.running]);
    }
  }

  void _request({bool pull = false, bool force = false}) {
    _pullWanted |= pull;
    if (force) {
      _send.force();
      if (pull) _catalogue.force();
      _rejected.updateAll(
        (_, version) => (
          updatedAt: version.updatedAt,
          backoff: version.backoff,
          retryAt: Duration.zero,
          error: version.error,
        ),
      );
    }
    _kick();
  }

  void _kick() {
    if (!_started || !isLoggedIn || _loggingOut) {
      _setStatus(_status.value.phase, error: _status.value.error);
      return;
    }
    if (_send.running == null) {
      if (!_library.hasPending) _send.clearBackoff();
      if (!_send.waiting) {
        if (_hasSendablePending) {
          _sendPending();
        } else {
          _scheduleRejectedRetry();
        }
      }
    }
    if (_pullWanted &&
        _send.running == null &&
        _catalogue.running == null &&
        !_catalogue.waiting) {
      _pullWanted = false;
      _attempt(_catalogue, _pull);
    }
    final error =
        _send.error ?? _catalogue.error ?? _rejected.values.firstOrNull?.error;
    if (_send.running != null || _catalogue.running != null) {
      _setStatus(SyncPhase.syncing);
    } else if (error is OfflineException || error is TimeoutException) {
      _setStatus(SyncPhase.offline);
    } else if (error != null) {
      _setStatus(
        SyncPhase.error,
        error: error is ApiException ? error.message : '$error',
      );
    } else {
      _setStatus(SyncPhase.idle);
    }
  }

  Future<bool> _attempt(
    _SyncOperation operation,
    Future<void> Function(int) run,
  ) {
    final session = _session;
    return operation.running ??=
        Future<bool>.microtask(() async {
          if (!_inSession(session)) return false;
          final generation = operation.forceGeneration;
          try {
            await run(session);
            if (_inSession(session)) operation.clearBackoff();
            return true;
          } on Object catch (error) {
            if (!_inSession(session) || _loggingOut) return false;
            if (error is ApiException && error.statusCode == 401) {
              handleUnauthorized();
              return false;
            }
            operation.error = error;
            if (operation == _catalogue) _pullWanted = true;
            if (generation == operation.forceGeneration) {
              operation.backoff = _nextBackoff(operation.backoff);
              operation.retry?.cancel();
              operation.retry = Timer(operation.backoff!, _kick);
            }
            return false;
          }
        }).whenComplete(() {
          if (session != _session) return;
          operation.running = null;
          _kick();
        });
  }

  Future<bool> _sendPending({Duration? timeout}) =>
      _attempt(_send, (session) => _push(session, timeout: timeout));

  Future<void> _push(int session, {Duration? timeout}) async {
    final watch = timeout == null ? null : (Stopwatch()..start());
    await _library.repairRejectedTimes();
    if (!_inSession(session)) return;
    final changes = _sendableChanges();
    if (changes.states.isEmpty && changes.queue == null) return;
    await _pushBatch(
      session,
      changes.states,
      changes.queue,
      timeLeft: watch == null ? null : () => timeout! - watch.elapsed,
    );
  }

  Future<void> _pushBatch(
    int session,
    List<EpisodeState> states,
    QueueState? queue, {
    Duration Function()? timeLeft,
  }) async {
    if (!_inSession(session)) return;
    final remaining = timeLeft?.call();
    if (remaining != null && remaining <= Duration.zero) {
      throw TimeoutException('State send deadline expired');
    }
    final StatePushResult result;
    try {
      final request = _api.pushState(episodes: states, queue: queue);
      result = await (remaining == null ? request : request.timeout(remaining));
    } on ApiException catch (error) {
      if (error.statusCode != 400) rethrow;
      if (!_inSession(session)) return;
      final count = states.length + (queue == null ? 0 : 1);
      if (count == 1) {
        final id = states.firstOrNull?.episodeId;
        final at = queue?.updatedAt ?? states.single.updatedAt;
        if (error.message == _futureTimeError &&
            await _library.handleRejectedTime(id, at)) {
          return;
        }
        if (_inSession(session)) _deferRejected(id, at, error.message);
      } else {
        final middle = count ~/ 2;
        await _pushBatch(
          session,
          states.sublist(0, middle),
          null,
          timeLeft: timeLeft,
        );
        await _pushBatch(
          session,
          states.sublist(middle),
          queue,
          timeLeft: timeLeft,
        );
      }
      return;
    }
    if (!_inSession(session)) return;
    final missing = await _library.applyPushResult(states, queue, result);
    if (!_inSession(session)) return;
    if (_send.error != null || missing) _pullWanted = true;
    await _recordSuccess();
  }

  ({List<EpisodeState> states, QueueState? queue}) _sendableChanges({
    int maxStates = 2000,
  }) {
    final now = _elapsed.elapsed;
    return _library.pendingChanges(
      maxStates: maxStates,
      include: (id, at) {
        final rejected = _rejected[id];
        return rejected == null ||
            !rejected.updatedAt.isAtSameMomentAs(at) ||
            rejected.retryAt <= now;
      },
    );
  }

  bool get _hasSendablePending {
    final changes = _sendableChanges(maxStates: 1);
    return changes.states.isNotEmpty || changes.queue != null;
  }

  void _deferRejected(int? id, DateTime at, String error) {
    if (!_library.hasPendingVersion(id, at)) return;
    final rejected = _rejected[id];
    final repeats = rejected != null && rejected.updatedAt.isAtSameMomentAs(at);
    final backoff = _nextBackoff(repeats ? rejected.backoff : null);
    _rejected[id] = (
      updatedAt: at,
      backoff: backoff,
      retryAt: _elapsed.elapsed + backoff,
      error: error,
    );
    if (!repeats) _pullWanted = true;
  }

  void _pruneRejected() => _rejected.removeWhere(
    (id, version) => !_library.hasPendingVersion(id, version.updatedAt),
  );

  void _scheduleRejectedRetry() {
    _rejectedRetryTimer?.cancel();
    _rejectedRetryTimer = null;
    _pruneRejected();
    Duration? next;
    for (final version in _rejected.values) {
      if (next == null || version.retryAt < next) next = version.retryAt;
    }
    if (next == null) return;
    _rejectedRetryTimer = Timer(next - _elapsed.elapsed, _kick);
  }

  Future<void> _flushPending(
    int session,
    Duration timeout,
    Stopwatch watch,
  ) async {
    while (_inSession(session) &&
        (_send.running != null || _hasSendablePending)) {
      final remaining = timeout - watch.elapsed;
      if (remaining <= Duration.zero) return;
      if (!await _sendPending(timeout: remaining).timeout(remaining)) return;
    }
  }

  Future<StateSnapshot?> _refreshStatesAndQueue() async {
    if (!isLoggedIn || _loggingOut) return null;
    final session = _session;
    final watch = Stopwatch()..start();
    try {
      await _flushPending(session, queueRefreshTimeout, watch);
      final remaining = queueRefreshTimeout - watch.elapsed;
      if (remaining <= Duration.zero || !_inSession(session) || _loggingOut) {
        return null;
      }
      final snapshot = await _api.state().timeout(remaining);
      if (!_inSession(session) || _loggingOut) return null;
      _checkClock(snapshot.serverTime);
      await _applyRemote(session, snapshot.episodes, snapshot.queue);
      if (watch.elapsed > queueRefreshTimeout ||
          !_inSession(session) ||
          _loggingOut) {
        return null;
      }
      return snapshot;
    } on ApiException catch (e) {
      if (e.statusCode == 401 && _inSession(session)) handleUnauthorized();
      return null;
    } on OfflineException {
      return null;
    } on TimeoutException {
      return null;
    } finally {
      _kick();
    }
  }

  Future<void> _applyRemote(
    int session,
    List<EpisodeState> states,
    QueueState? queue,
  ) async {
    final missing = await _library.applyRemote(states, queue);
    if (missing && _inSession(session) && !_loggingOut) _request(pull: true);
  }

  Future<void> _pull(int session) async {
    bool isCurrent() => _inSession(session) && !_loggingOut;
    final snapshot = await _api.state();
    if (!isCurrent()) return;
    _checkClock(snapshot.serverTime);
    await _library.applyRemote(snapshot.episodes, snapshot.queue);
    if (!isCurrent()) return;
    final fetched = await _api.podcasts(
      ifNoneMatch: _store.meta(MetaKey.podcastsEtag),
    );
    if (!isCurrent()) return;
    if (fetched != null) {
      await _library.replacePodcasts(fetched.value);
      if (!isCurrent()) return;
      await _store.setMeta(MetaKey.podcastsEtag, fetched.etag);
    }
    for (final podcast in _library.knownPodcasts.toList()) {
      if (!isCurrent()) return;
      if (_send.running != null || (!_send.waiting && _hasSendablePending)) {
        await _sendPending();
        if (!isCurrent()) return;
      }
      await _library.refreshEpisodes(podcast, isCurrent: isCurrent);
    }
    if (isCurrent()) await _recordSuccess();
  }

  Future<void> _recordSuccess() async {
    _lastSuccess = _clock();
    await _store.setMeta(MetaKey.lastSync, formatTime(_lastSuccess!));
  }

  void _checkClock(DateTime serverTime) {
    final skew = _clock().difference(serverTime);
    final warning = skew.abs() > const Duration(minutes: 5) ? skew : null;
    if (warning == _clockSkewWarning) return;
    if (warning != null &&
        warning.isNegative != _clockSkewWarning?.isNegative) {
      debugPrint('EasyPodcast device time differs from server time by $skew.');
    }
    _clockSkewWarning = warning;
    _setStatus(_status.value.phase, error: _status.value.error);
  }

  Duration _nextBackoff(Duration? previous) {
    final backoff = previous == null ? initialBackoff : previous * 2;
    return backoff > maxBackoff ? maxBackoff : backoff;
  }

  void _startPullTimer() {
    _pullTimer?.cancel();
    if (!_foreground) return;
    _pullTimer = Timer.periodic(pullInterval, (_) => _request(pull: true));
  }

  void _cancelTimers() {
    _send.retry?.cancel();
    _catalogue.retry?.cancel();
    _rejectedRetryTimer?.cancel();
    _rejectedRetryTimer = null;
    _pullTimer?.cancel();
    _pullTimer = null;
  }

  bool _inSession(int session) => session == _session && isLoggedIn;

  void _endSessionWork() {
    _session++;
    _cancelTimers();
    _pullWanted = false;
    for (final operation in [_send, _catalogue]) {
      operation.running = null;
      operation.clearBackoff();
    }
    _rejected.clear();
    _clockSkewWarning = null;
  }

  void _setStatus(SyncPhase phase, {String? error}) {
    final old = _status.value;
    final pending = _library.pendingCount;
    if (old.phase == phase &&
        old.error == error &&
        old.clockSkewWarning == _clockSkewWarning &&
        old.pending == pending &&
        old.lastSuccess == _lastSuccess) {
      return;
    }
    _status.value = SyncStatus(
      phase: phase,
      lastSuccess: _lastSuccess,
      pending: pending,
      error: error,
      clockSkewWarning: _clockSkewWarning,
    );
  }

  void dispose() {
    _endSessionWork();
    _library.onPendingSend = null;
    _library.refreshStatesAndQueue = null;
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
    _status.dispose();
  }
}
