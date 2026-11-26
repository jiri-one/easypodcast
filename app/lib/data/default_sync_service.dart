import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../core/api.dart';
import '../core/models.dart';
import '../core/sync.dart';
import 'http_api_client.dart';
import 'local_store.dart';
import 'sqflite_library.dart';

class _SyncOperation {
  Future<void>? running;
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

class DefaultSyncService extends SyncService with WidgetsBindingObserver {
  DefaultSyncService({
    required this._api,
    required this._library,
    required this._store,
    this._networkUp,
    this.observeLifecycle = true,
    this.initialBackoff = const Duration(seconds: 5),
    this.maxBackoff = const Duration(minutes: 5),
    this.pullInterval = const Duration(minutes: 15),
    this.freshStateTimeout = const Duration(seconds: 2),
    this.queueRefreshTimeout = const Duration(seconds: 2),
    this.logoutSendTimeout = const Duration(seconds: 2),
    this._clock = nowUtc,
  }) {
    _status = ValueNotifier(
      SyncStatus(
        phase: isLoggedIn ? SyncPhase.idle : SyncPhase.loggedOut,
        lastSuccess: _lastSuccess,
        pending: _library.pendingCount,
      ),
    );
    _library.onPendingSend = _request;
    _library.refreshStatesAndQueue = _refreshStatesAndQueue;
  }

  final ApiClient _api;
  final SqfliteLibrary _library;
  final LocalStore _store;
  final Stream<bool>? _networkUp;
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
  DateTime? get _lastSuccess {
    final last = _store.meta(MetaKey.lastSync);
    return last == null ? null : DateTime.tryParse(last)?.toUtc();
  }

  Duration? _clockSkewWarning;

  bool _started = false;
  bool _observing = false;
  bool _foreground = false;
  bool _pullWanted = false;
  bool _loggingOut = false;
  Future<void>? _identityReset;
  int _session = 0;
  final _send = _SyncOperation();
  final _catalogue = _SyncOperation();
  _SyncOperation? _lastFailure;
  Timer? _pullTimer;
  StreamSubscription<bool>? _networkSub;

  @override
  ValueListenable<SyncStatus> get status => _status;

  @override
  bool get isLoggedIn => _store.meta(MetaKey.token) != null;

  @override
  String get serverUrl => _store.meta(MetaKey.serverUrl) ?? '';

  @override
  String get deviceName => _store.meta(MetaKey.deviceName) ?? '';

  @visibleForTesting
  Duration? get currentBackoff => _send.backoff ?? _catalogue.backoff;

  @visibleForTesting
  bool get retryScheduled => _send.waiting || _catalogue.waiting;

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
    await _store.setMeta(MetaKey.deviceName, deviceName);
    await _store.setMeta(MetaKey.token, result.token);
    _updateStatus();
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
      await sendPending(timeout: logoutSendTimeout);
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
      _updateStatus();
    }
  }

  /// The server rejected the token: the user has to log in again, local changes stay.
  void handleUnauthorized() {
    if (!isLoggedIn) return;
    _endSessionWork();
    unawaited(_store.setMeta(MetaKey.token, null));
    _updateStatus();
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
    _networkSub ??= _networkUp?.listen((_) {
      if (isLoggedIn && _library.hasPending) _request(force: true);
    });
    if (!isLoggedIn) {
      _updateStatus();
      return;
    }
    _startPullTimer();
    // Not awaited: an offline start must not hold up the first frame.
    _request(pull: true, force: true);
  }

  @override
  Future<void> stop() async {
    if (!_started) return;
    if (_networkSub case final sub?) {
      _networkSub = null;
      await sub.cancel();
    }
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
      final remote = await _api.episodeState(
        episodeId,
        timeout: freshStateTimeout,
      );
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
    } on Object {
      // Playback can start from the saved position.
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
      if (pull) _catalogue.force();
    }
    _kick();
  }

  void _kick() {
    if (_identityReset != null) return;
    if (!_started || !isLoggedIn || _loggingOut) {
      _updateStatus();
      return;
    }
    if (_send.running == null) {
      if (!_library.hasPending) _send.clearBackoff();
      if (_hasSendablePending) _sendPending();
    }
    if (_pullWanted &&
        _send.running == null &&
        _catalogue.running == null &&
        !_catalogue.waiting) {
      _pullWanted = false;
      _attempt(_catalogue, _pull);
    }
    _updateStatus();
  }

  bool get _hasSendablePending =>
      _library.hasPending &&
      (!_send.waiting ||
          (_send.error == null && _library.hasUnrejectedPending));

  Future<void> _attempt(
    _SyncOperation operation,
    Future<void> Function(int) run,
  ) {
    final session = _session;
    return operation.running ??=
        Future<void>.microtask(() async {
          if (!_inSession(session)) return;
          final generation = operation.forceGeneration;
          try {
            await run(session);
            if (!_inSession(session)) return;
            if (operation == _send && _library.hasClockRejections) {
              operation.error = null;
              if (!operation.waiting &&
                  generation == operation.forceGeneration) {
                _scheduleRetry(operation);
              }
            } else {
              operation.clearBackoff();
            }
          } on Object catch (error) {
            if (!_inSession(session) || _loggingOut) return;
            if (error is ApiException && error.statusCode == 401) {
              handleUnauthorized();
              return;
            }
            operation.error = error;
            _lastFailure = operation;
            if (operation == _catalogue) _pullWanted = true;
            if (generation == operation.forceGeneration) {
              _scheduleRetry(operation);
            }
          }
        }).whenComplete(() {
          if (session != _session) return;
          operation.running = null;
          _kick();
        });
  }

  Future<void> _sendPending({Duration? timeout, bool sendOnly = false}) =>
      _attempt(
        _send,
        (session) => _push(session, timeout: timeout, sendOnly: sendOnly),
      );

  Future<void> _push(
    int session, {
    Duration? timeout,
    required bool sendOnly,
  }) async {
    final watch = Stopwatch()..start();
    await _library.repairRejectedTimes();
    var includeRejected = sendOnly || !_send.waiting;
    while (_inSession(session)) {
      final (:states, :queue) = _library.pendingChanges(
        includeRejected: includeRejected,
      );
      if (states.isEmpty && queue == null) return;
      final remaining = timeout == null ? null : timeout - watch.elapsed;
      if (remaining != null && remaining <= Duration.zero) return;
      final serverId = _store.meta(MetaKey.serverId);
      final StatePushResult result;
      try {
        result = await _api.pushState(
          serverId: serverId,
          episodes: states,
          queue: queue,
          timeout: remaining,
        );
      } on ApiException catch (error) {
        if (error.statusCode != 409 ||
            error.serverId == null ||
            error.serverId == serverId) {
          rethrow;
        }
        await _rememberServer(session, error.serverId!);
        return;
      }
      if (!await _rememberServer(session, result.serverId!) ||
          !_inSession(session)) {
        return;
      }
      final now = _clock();
      final newClockWarning =
          result.future.isNotEmpty && !_library.hasClockRejections;
      final missing = await _library.applyPushResult(
        states,
        queue,
        result,
        now,
      );
      if (!_inSession(session)) return;
      if (!sendOnly && (_send.error != null || missing || newClockWarning)) {
        _pullWanted = true;
      }
      includeRejected = false;
    }
  }

  @override
  Future<void> sendPending({Duration? timeout}) async {
    final watch = Stopwatch()..start();
    // A send already running may fail or stop at its own deadline before it
    // carries this change, so one own attempt follows it.
    for (var round = 0; round < 2; round++) {
      final remaining = timeout == null ? null : timeout - watch.elapsed;
      if (!isLoggedIn ||
          (!_library.hasPending && _send.running == null) ||
          (remaining != null && remaining <= Duration.zero)) {
        return;
      }
      final joined = _send.running != null;
      final sending = _sendPending(timeout: remaining, sendOnly: true);
      _updateStatus();
      if (remaining == null) {
        await sending;
      } else {
        await sending.timeout(remaining, onTimeout: () {});
      }
      if (!joined) return;
    }
  }

  Future<List<EpisodeState>?> _refreshStatesAndQueue() async {
    if (!isLoggedIn || _loggingOut) return null;
    final session = _session;
    final watch = Stopwatch()..start();
    try {
      await sendPending(timeout: queueRefreshTimeout);
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
      if (_send.running != null || _hasSendablePending) {
        await _sendPending();
        if (!isCurrent()) return;
      }
      try {
        await _library.refreshEpisodes(podcast, isCurrent: isCurrent);
      } on OfflineException catch (error) {
        listError = error;
      }
    }
    if (listError != null) throw listError;
    if (isCurrent()) await _store.writeStates(const [], lastSync: _clock());
  }

  Future<({List<EpisodeState> episodes, bool missing})?> _pullState(
    int session, {
    Duration? timeout,
  }) async {
    final fetched = await _api.fetchState(
      ifNoneMatch: _store.meta(MetaKey.stateEtag),
      timeout: timeout,
    );
    if (fetched != null &&
        !await _rememberServer(session, fetched.value.serverId!)) {
      return null;
    }
    if (!_inSession(session)) return null;
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

  void _checkClock(DateTime serverTime) {
    final skew = _clock().difference(serverTime);
    final warning = skew.abs() > const Duration(minutes: 5) ? skew : null;
    if (warning == _clockSkewWarning) return;
    if (warning != null &&
        warning.isNegative != _clockSkewWarning?.isNegative) {
      debugPrint('EasyPodcast device time differs from server time by $skew.');
    }
    _clockSkewWarning = warning;
    _updateStatus();
  }

  void _scheduleRetry(_SyncOperation operation) {
    final next = operation.backoff == null
        ? initialBackoff
        : operation.backoff! * 2;
    operation.backoff = next > maxBackoff ? maxBackoff : next;
    operation.retry?.cancel();
    operation.retry = Timer(operation.backoff!, _kick);
  }

  void _startPullTimer() {
    _pullTimer?.cancel();
    if (!_foreground) return;
    _pullTimer = Timer.periodic(pullInterval, (_) => _request(pull: true));
  }

  void _cancelTimers() {
    _send.retry?.cancel();
    _catalogue.retry?.cancel();
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
    _clockSkewWarning = null;
  }

  void _updateStatus() {
    final problem =
        _lastFailure?.error ??
        _send.error ??
        _catalogue.error ??
        (_library.hasClockRejections
            ? 'updated_at is more than 24 hours ahead of server time'
            : null);
    final phase = !isLoggedIn
        ? SyncPhase.loggedOut
        : problem is OfflineException
        ? SyncPhase.offline
        : problem != null
        ? SyncPhase.error
        : SyncPhase.idle;
    final error = phase == SyncPhase.error
        ? (problem is ApiException ? problem.message : '$problem')
        : null;
    final syncing = _send.running != null || _catalogue.running != null;
    final old = _status.value;
    final pending = _library.pendingCount;
    final lastSuccess = _lastSuccess;
    if (old.phase == phase &&
        old.syncing == syncing &&
        old.error == error &&
        old.clockSkewWarning == _clockSkewWarning &&
        old.pending == pending &&
        old.lastSuccess == lastSuccess) {
      return;
    }
    _status.value = SyncStatus(
      phase: phase,
      syncing: syncing,
      lastSuccess: lastSuccess,
      pending: pending,
      error: error,
      clockSkewWarning: _clockSkewWarning,
    );
  }

  void dispose() {
    unawaited(_networkSub?.cancel());
    _networkSub = null;
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
