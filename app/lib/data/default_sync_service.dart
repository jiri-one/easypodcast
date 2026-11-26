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
    library.onLocalChange = _onLocalChange;
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

  late final ValueNotifier<SyncStatus> _status;
  DateTime? _lastSuccess;

  bool _started = false;
  bool _observing = false;
  bool _foreground = true;
  bool _pushWanted = false;
  bool _pullWanted = false;
  bool _failedSinceSuccess = false;
  Future<void>? _running;
  Timer? _retryTimer;
  Timer? _pullTimer;
  Duration? _backoff;

  @override
  ValueListenable<SyncStatus> get status => _status;

  @override
  bool get isLoggedIn => _store.meta(MetaKey.token) != null;

  @visibleForTesting
  Duration? get currentBackoff => _backoff;

  @visibleForTesting
  bool get retryScheduled => _retryTimer?.isActive ?? false;

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
    _backoff = null;
    _failedSinceSuccess = false;
    _setStatus(SyncPhase.idle);
    if (_started) {
      _startPullTimer();
      _request(push: true, pull: true, force: true);
    }
  }

  @override
  Future<void> logout() async {
    _cancelTimers();
    await whenIdle();
    try {
      await _api.logout();
    } on Object {
      // The local session ends even if the server cannot be told.
    }
    await _store.setMeta(MetaKey.token, null);
    _setStatus(SyncPhase.loggedOut);
  }

  /// The server rejected the token: the user has to log in again, local changes stay.
  void handleUnauthorized() {
    _cancelTimers();
    _pushWanted = false;
    _pullWanted = false;
    unawaited(_store.setMeta(MetaKey.token, null));
    _setStatus(SyncPhase.loggedOut);
  }

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;
    if (observeLifecycle && !_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
    if (!isLoggedIn) {
      _setStatus(SyncPhase.loggedOut);
      return;
    }
    _startPullTimer();
    // Not awaited: an offline start must not hold up the first frame.
    _request(push: true, pull: true, force: true);
  }

  @override
  Future<void> stop() async {
    if (!_started) return;
    _cancelTimers();
    if (isLoggedIn && _library.hasPending) _request(push: true, force: true);
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
    _request(push: true, pull: true, force: true);
    await whenIdle();
  }

  @override
  Future<void> freshStateBeforePlay(int episodeId) async {
    if (!isLoggedIn) return;
    try {
      final remote = await _api
          .episodeState(episodeId, timeout: freshStateTimeout)
          .timeout(freshStateTimeout);
      if (remote != null && remote.episodeId == episodeId) {
        await _library.applyRemote([remote], null);
      }
    } on ApiException catch (e) {
      if (e.statusCode == 401) handleUnauthorized();
    } on Object {
      // Offline or slow: playback starts from the local state.
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
        _backoff = null;
        _request(push: true, pull: true, force: true);
      case AppLifecycleState.paused ||
          AppLifecycleState.hidden ||
          AppLifecycleState.detached:
        _foreground = false;
        _pullTimer?.cancel();
        _pullTimer = null;
        if (_started && isLoggedIn && _library.hasPending) {
          _request(push: true, force: true);
        }
      case AppLifecycleState.inactive:
        break;
    }
  }

  @visibleForTesting
  Future<void> whenIdle() async {
    while (_running != null) {
      await _running;
    }
  }

  void _onLocalChange() {
    _setStatus(_status.value.phase, error: _status.value.error);
    _request(push: true);
  }

  /// [force] skips the backoff wait, for the user's and the lifecycle's explicit triggers.
  void _request({bool push = false, bool pull = false, bool force = false}) {
    _pushWanted |= push;
    _pullWanted |= pull;
    if (force) {
      _retryTimer?.cancel();
      _retryTimer = null;
    }
    _kick();
  }

  void _kick() {
    if (!_started || !isLoggedIn || _running != null) return;
    if (_retryTimer?.isActive ?? false) return;
    if (!_pushWanted && !_pullWanted && !_library.hasPending) return;
    _running = _run().whenComplete(() {
      _running = null;
      _kick();
    });
  }

  Future<void> _run() async {
    while (_started && isLoggedIn) {
      if (_library.hasPending) {
        _pushWanted = false;
        _setStatus(SyncPhase.syncing);
        try {
          await _push();
        } on Object catch (e) {
          _fail(e);
          return;
        }
        continue;
      }
      _pushWanted = false;
      if (_pullWanted) {
        _pullWanted = false;
        _setStatus(SyncPhase.syncing);
        try {
          await _pull();
        } on Object catch (e) {
          _pullWanted = true;
          _fail(e);
          return;
        }
        continue;
      }
      _setStatus(SyncPhase.idle);
      return;
    }
  }

  Future<void> _push() async {
    final changes = _library.pendingChanges();
    final result = await _api.pushState(
      episodes: changes.states,
      queue: changes.queue,
    );
    await _library.applyPushResult(changes.states, changes.queue, result);
    if (_failedSinceSuccess) _pullWanted = true;
    await _succeeded();
  }

  Future<void> _pull() async {
    final fetched = await _api.podcasts(
      ifNoneMatch: _store.meta(MetaKey.podcastsEtag),
    );
    if (fetched != null) {
      await _library.replacePodcasts(fetched.value);
      await _store.setMeta(MetaKey.podcastsEtag, fetched.etag);
    }
    for (final podcast in _library.knownPodcasts.toList()) {
      await _library.refreshEpisodes(podcast);
    }
    final snapshot = await _api.state();
    await _library.applyRemote(snapshot.episodes, snapshot.queue);
    await _succeeded();
  }

  Future<void> _succeeded() async {
    _backoff = null;
    _failedSinceSuccess = false;
    _lastSuccess = _clock();
    await _store.setMeta(MetaKey.lastSync, formatTime(_lastSuccess!));
  }

  void _fail(Object error) {
    if (error is ApiException && error.statusCode == 401) {
      handleUnauthorized();
      return;
    }
    _failedSinceSuccess = true;
    if (error is OfflineException) {
      _setStatus(SyncPhase.offline);
    } else {
      _setStatus(
        SyncPhase.error,
        error: error is ApiException ? error.message : '$error',
      );
    }
    final backoff = _backoff == null ? initialBackoff : _backoff! * 2;
    _backoff = backoff > maxBackoff ? maxBackoff : backoff;
    _retryTimer?.cancel();
    _retryTimer = Timer(_backoff!, () {
      _retryTimer = null;
      _kick();
    });
  }

  void _startPullTimer() {
    _pullTimer?.cancel();
    _pullTimer = Timer.periodic(pullInterval, (_) {
      if (_foreground) _request(pull: true);
    });
  }

  void _cancelTimers() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _pullTimer?.cancel();
    _pullTimer = null;
  }

  void _setStatus(SyncPhase phase, {String? error}) {
    final old = _status.value;
    final pending = _library.pendingCount;
    if (old.phase == phase &&
        old.error == error &&
        old.pending == pending &&
        old.lastSuccess == _lastSuccess) {
      return;
    }
    _status.value = SyncStatus(
      phase: phase,
      lastSuccess: _lastSuccess,
      pending: pending,
      error: error,
    );
  }

  void dispose() {
    _cancelTimers();
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
    _status.dispose();
  }
}
