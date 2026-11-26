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

  final HttpApiClient _api;
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
  bool _identityConfirmed = false;
  Future<void>? _identityReset;
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
    if (_identityReset case final reset?) await reset;
    _endSessionWork();
    final normalized = HttpApiClient.normalizeServerUrl(serverUrl);
    await _rememberServer(_session, result.serverId!, loginUrl: normalized);
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
    try {
      final remote = await _api
          .episodeState(episodeId, timeout: freshStateTimeout)
          .timeout(freshStateTimeout);
      if (remote == null ||
          remote.episodeId != episodeId ||
          !_inSession(session) ||
          _loggingOut) {
        return;
      }
      final missing = await _library.applyRemote([remote], null);
      if (missing && _inSession(session) && !_loggingOut) _pullWanted = true;
    } on ApiException catch (e) {
      if (e.statusCode == 401 && _inSession(session)) handleUnauthorized();
    } on Object catch (error) {
      if (_inSession(session) &&
          (error is OfflineException || error is TimeoutException)) {
        _identityConfirmed = false;
      }
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
    while (_send.running != null ||
        _catalogue.running != null ||
        _identityReset != null) {
      await Future.wait([?_send.running, ?_catalogue.running, ?_identityReset]);
    }
  }

  void _request({bool pull = false, bool force = false}) {
    _pullWanted |= pull;
    if (force) {
      _send.force();
      if (pull) {
        _identityConfirmed = false;
        _catalogue.force();
      }
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
    if (_identityReset != null) return;
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
            if (operation == _send ||
                error is OfflineException ||
                error is TimeoutException) {
              _identityConfirmed = false;
            }
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
    final timeLeft = watch == null ? null : () => timeout! - watch.elapsed;
    await _library.repairRejectedTimes();
    if (!_inSession(session)) return;
    if (!_identityConfirmed) {
      final state = await _pullState(session, timeout: timeLeft?.call());
      if (!_inSession(session)) return;
      _pullWanted |= state?.missing ?? false;
    }
    final changes = _sendableChanges();
    if (changes.states.isEmpty && changes.queue == null) return;
    await _pushBatch(
      session,
      changes.states,
      changes.queue,
      timeLeft: timeLeft,
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
    if (!await _rememberServer(session, result.serverId!) ||
        !_inSession(session)) {
      return;
    }
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

  Future<List<EpisodeState>?> _refreshStatesAndQueue() async {
    if (!isLoggedIn || _loggingOut) return null;
    final session = _session;
    final watch = Stopwatch()..start();
    try {
      await _flushPending(session, queueRefreshTimeout, watch);
      final remaining = queueRefreshTimeout - watch.elapsed;
      if (remaining <= Duration.zero || !_inSession(session) || _loggingOut) {
        return null;
      }
      final state = await _pullState(session, timeout: remaining);
      if (!_inSession(session) || _loggingOut) return null;
      _pullWanted |= state?.missing ?? false;
      if (watch.elapsed > queueRefreshTimeout) return null;
      return state?.episodes ?? const [];
    } on ApiException catch (e) {
      if (e.statusCode == 401 && _inSession(session)) handleUnauthorized();
      return null;
    } on OfflineException {
      if (_inSession(session)) _identityConfirmed = false;
      return null;
    } on TimeoutException {
      if (_inSession(session)) _identityConfirmed = false;
      return null;
    } finally {
      _kick();
    }
  }

  Future<void> _pull(int session) async {
    bool isCurrent() => _inSession(session) && !_loggingOut;
    await _pullState(session);
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
    Exception? listError;
    for (final podcast in _library.knownPodcasts.toList()) {
      if (!isCurrent()) return;
      if (_send.running != null || (!_send.waiting && _hasSendablePending)) {
        await _sendPending();
        if (!isCurrent()) return;
      }
      try {
        await _library.refreshEpisodes(podcast, isCurrent: isCurrent);
      } on OfflineException catch (error) {
        listError = error;
      } on TimeoutException catch (error) {
        listError = error;
      }
    }
    if (listError != null) throw listError;
    if (isCurrent()) await _recordSuccess();
  }

  Future<({List<EpisodeState> episodes, bool missing})?> _pullState(
    int session, {
    Duration? timeout,
  }) async {
    if (timeout != null && timeout <= Duration.zero) {
      throw TimeoutException('State check deadline expired');
    }
    final request = _api.fetchState(
      ifNoneMatch: _store.meta(MetaKey.stateEtag),
    );
    final fetched = await (timeout == null
        ? request
        : request.timeout(timeout));
    if (fetched != null &&
        !await _rememberServer(session, fetched.value.serverId!)) {
      return null;
    }
    if (!_inSession(session)) return null;
    _identityConfirmed = true;
    if (fetched == null) return null;
    final snapshot = fetched.value;
    _checkClock(snapshot.serverTime);
    final playing = _library.playingEpisodeId;
    final missing = await _library.applyRemote(
      snapshot.episodes,
      snapshot.queue,
    );
    // A protected playing episode can still need the same snapshot later.
    if (_inSession(session) &&
        !snapshot.episodes.any((item) => item.episodeId == playing)) {
      await _store.setMeta(MetaKey.stateEtag, fetched.etag);
    }
    return (episodes: snapshot.episodes, missing: missing);
  }

  Future<bool> _rememberServer(
    int session,
    String serverId, {
    String? loginUrl,
  }) async {
    if (loginUrl == null && !_inSession(session)) return false;
    final previous = _store.meta(MetaKey.serverId);
    if (previous == serverId) return true;
    final previousUrl = _store.meta(MetaKey.serverUrl);
    final urlChanged =
        loginUrl != null && previousUrl != null && loginUrl != previousUrl;
    if (previous == null && !urlChanged) {
      await _store.setMeta(MetaKey.serverId, serverId);
      return true;
    }
    try {
      await (_identityReset = _library.clear(serverId));
      _lastSuccess = null;
    } finally {
      _identityReset = null;
    }
    if (loginUrl == null && session == _session) {
      _endSessionWork();
      _startPullTimer();
      _request(pull: true);
    }
    return false;
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

  bool _inSession(int session) =>
      session == _session && isLoggedIn && _identityReset == null;

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
    _identityConfirmed = false;
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
