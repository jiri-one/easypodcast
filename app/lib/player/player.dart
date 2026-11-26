import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:audio_service/audio_service.dart';
import 'package:audio_service_mpris/audio_service_mpris.dart';
// ignore: depend_on_referenced_packages
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

import '../core/downloads.dart';
import '../core/library.dart';
import '../core/models.dart';
import '../core/player.dart';
import '../core/settings.dart';
import '../core/sync.dart';
import '../platform/android_platform.dart';

part 'android_audio.dart';
part 'linux_audio.dart';
part 'playback_engine.dart';

Future<PlayerController> openPlayer({
  required Library library,
  required SyncService sync,
  required DownloadService downloads,
  required Settings settings,
}) async {
  if (Platform.isLinux) {
    JustAudioMediaKit.ensureInitialized();
  }
  final engine = await _JustAudioEngine.open();
  final controller = EpisodePlayer(
    library: library,
    sync: sync,
    downloads: downloads,
    settings: settings,
    engine: engine,
  );
  try {
    if (Platform.isAndroid) {
      await _openAndroidAudio(controller, library, downloads, settings);
    } else if (Platform.isLinux) {
      await connectMpris(controller);
    }
    WidgetsBinding.instance.addObserver(controller);
    return controller;
  } catch (_) {
    controller.dispose();
    rethrow;
  }
}

class EpisodePlayer extends PlayerController with WidgetsBindingObserver {
  EpisodePlayer({
    required this._library,
    required this._sync,
    required this._downloads,
    required Settings settings,
    required this._engine,
    this._clock = nowUtc,
  }) : _settings = settings,
       _speed = settings.speed {
    _library.addListener(_onLibraryChanged);
    _engineEvents = _engine.changes.listen((_) => _onEngineChanged());
    _interruptions = _engine.interruptions.listen(_onInterruption);
  }

  final Library _library;
  final SyncService _sync;
  final DownloadService _downloads;
  final Settings _settings;
  final PlaybackEngine _engine;
  final DateTime Function() _clock;
  final _position = ValueNotifier(Duration.zero);
  final _mediaChanges = StreamController<bool>.broadcast(sync: true);
  late final StreamSubscription<void> _engineEvents;
  late final StreamSubscription<PlaybackInterruption> _interruptions;
  Future<void> _commands = Future.value();
  Episode? _current;
  DateTime? _pausedAt;
  DateTime? _endObservedAt;
  PlaybackError? _lastPlaybackError;
  bool _finishedSinceStart = false;
  bool _loaded = false;
  bool _loading = false;
  bool _advancing = false;
  bool _seeking = false;
  bool _disposed = false;
  bool _exiting = false;
  int? _syncEpisode;
  int _focusRevision = 0;
  bool _resumeOnFocus = false;
  double _speed;
  Timer? _positionTimer;
  Timer? _reportTimer;
  Timer? _sleepTimer;
  Stopwatch? _sleepElapsed;
  Duration? _sleepDuration;
  bool _sleepAtEndOfEpisode = false;
  bool _sleepExpired = false;
  Object? _playAttempt;
  Object? _failureAttempt;
  (Episode?, bool, bool, double, Timer?, bool, PlaybackError?)? _visibleState;

  @override
  Episode? get current => _current;

  @override
  bool get isPlaying =>
      _loaded &&
      _failureAttempt == null &&
      _endObservedAt == null &&
      _engine.processingState != ProcessingState.idle &&
      _engine.processingState != ProcessingState.completed &&
      _engine.playing;

  bool get _mediaPlaying =>
      isPlaying || _advancing || (_endObservedAt != null && _mayAdvance);

  bool get _mayAdvance =>
      _syncEpisode != null &&
      _pausedAt == null &&
      !_exiting &&
      !_sleepExpired &&
      !_sleepAtEndOfEpisode &&
      _settings.autoplayQueue;

  @override
  bool get isBuffering =>
      _loading ||
      (_loaded &&
          (_engine.processingState == ProcessingState.loading ||
              _engine.processingState == ProcessingState.buffering));

  @override
  ValueListenable<Duration> get position => _position;

  @override
  Duration? get duration {
    final realDuration = _loaded ? _measuredDuration : null;
    final feedDuration = _current?.durationS;
    return realDuration ??
        (feedDuration == null ? null : Duration(seconds: feedDuration));
  }

  @override
  double get speed => _speed;

  @override
  Duration? get sleepRemaining {
    final duration = _sleepDuration;
    if (duration == null) return null;
    final remaining = duration - _sleepElapsed!.elapsed;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  @override
  bool get sleepAtEndOfEpisode => _sleepAtEndOfEpisode;

  @override
  PlaybackError? get lastPlaybackError => _lastPlaybackError;

  @override
  Future<void> play(int episodeId) {
    _cancelFocusResume();
    return _run(() async {
      final episode = _library.episode(episodeId);
      if (episode == null) return;
      if (_current?.id == episodeId &&
          isPlaying &&
          !_finishedSinceStart &&
          _isUnfinished(episodeId)) {
        return;
      }
      if (_loaded && (_current?.id != episodeId || isPlaying)) {
        await _pause();
      }
      await _loadEpisode(episode, propagateError: true);
    });
  }

  @override
  Future<void> resume({int? preferredEpisodeId}) {
    _cancelFocusResume();
    return _run(() async {
      if (isPlaying) return;
      final episode = _current;
      if (episode != null) {
        if (_loaded &&
            _failureAttempt == null &&
            _engine.processingState != ProcessingState.idle) {
          await _resumeLoaded();
        } else {
          await _loadEpisode(episode, propagateError: true);
        }
        return;
      }
      final preferred = preferredEpisodeId == null
          ? null
          : _library.episode(preferredEpisodeId);
      if (preferred != null &&
          _isUnfinished(preferred.id) &&
          await _loadEpisode(
            preferred,
            eligible: () => _isUnfinished(preferred.id),
          )) {
        return;
      }
      var checkedId = preferred?.id;
      while (!_disposed && !_exiting) {
        final recent = _library.recentUnfinishedEpisode;
        if (recent == null || recent.id == checkedId) break;
        if (await _loadEpisode(
          recent,
          eligible: () => _isUnfinished(recent.id),
        )) {
          return;
        }
        checkedId = recent.id;
      }
      if (!await _playQueue(autoplay: false) && _current != null) {
        await _clear();
      }
    });
  }

  Future<void> playFromPodcast(int podcastId) {
    _cancelFocusResume();
    return _run(() async {
      final rejected = <int>{};
      while (!_disposed && !_exiting) {
        final episodes = _library
            .episodesOf(podcastId)
            .where((episode) => !rejected.contains(episode.id));
        final candidate =
            episodes.where((episode) {
              final state = _library.stateOf(episode.id);
              return state.status == EpisodeStatus.none && state.positionMs > 0;
            }).firstOrNull ??
            episodes.where((episode) {
              return !episode.removedFromFeed && _isUnfinished(episode.id);
            }).firstOrNull;
        if (candidate == null) {
          if (rejected.isNotEmpty) await _clear();
          return;
        }
        if (isPlaying && _current?.id == candidate.id) return;
        if (_loaded) await _pause();
        if (await _loadEpisode(
          candidate,
          eligible: () => _isUnfinished(candidate.id),
        )) {
          return;
        }
        rejected.add(candidate.id);
      }
    });
  }

  bool _isUnfinished(int id) =>
      _library.stateOf(id).status == EpisodeStatus.none;

  Future<bool> _playQueue({required bool autoplay}) async {
    while (!_disposed &&
        !_exiting &&
        !_sleepExpired &&
        (!autoplay || _settings.autoplayQueue)) {
      final id = _library.queueHeadId;
      if (id == null) return false;
      bool eligible() =>
          _library.queueHeadId == id && (!autoplay || _settings.autoplayQueue);
      final next = await _library.resolveQueueEpisode(id);
      if (!eligible()) continue;
      if (next == null) return false;
      if (await _loadEpisode(next, eligible: eligible)) return true;
    }
    return false;
  }

  Future<bool> _loadEpisode(
    Episode episode, {
    bool Function()? eligible,
    bool propagateError = false,
  }) async {
    final id = episode.id;
    await _sync.freshStateBeforePlay(id);
    if (_disposed || _exiting || eligible?.call() == false) return false;

    _current = episode;
    _loading = true;
    _loaded = false;
    _pausedAt = null;
    _endObservedAt = null;
    _lastPlaybackError = null;
    _playAttempt = null;
    _failureAttempt = null;
    _finishedSinceStart = false;
    var applied = _startPosition(_library.stateOf(id));
    _position.value = applied;
    _publish();
    var reason = PlaybackErrorReason.loadFailed;
    try {
      await _engine.prepareToPlay();
      final file = _downloads.localFileOf(id);
      final uri = file == null
          ? Uri.parse(episode.enclosureUrl)
          : Uri.file(file);
      await _engine.load(uri, applied).timeout(const Duration(seconds: 30));
      await _engine.setSpeed(_speed);
      while (!_disposed && !_exiting) {
        if (eligible?.call() == false) {
          await _engine.stop();
          return false;
        }
        final state = _library.stateOf(id);
        final target = _seekPosition(_startPosition(state));
        if (target == applied) {
          _loading = false;
          _loaded = true;
          if (_sleepExpired) {
            _pausedAt = _clock();
          } else {
            reason = PlaybackErrorReason.streamFailed;
            await _startEngine(state);
          }
          _publish();
          return true;
        }
        await _seekEngine(target);
        applied = target;
      }
      return false;
    } on _AudioFocusUnavailable {
      await _fail(PlaybackErrorReason.audioFocusUnavailable);
      return true;
    } on Object {
      await _fail(reason);
      if (propagateError) rethrow;
      return true;
    }
  }

  Duration _startPosition(EpisodeState state) =>
      state.status == EpisodeStatus.none
      ? Duration(milliseconds: state.positionMs)
      : Duration.zero;

  Future<bool> _preparePaused({required bool resuming}) async {
    final id = _current!.id;
    final paused = _pausedAt;
    if (paused != null &&
        _clock().difference(paused) > const Duration(seconds: 30)) {
      await _sync.freshStateBeforePlay(id);
    }
    var applied =
        _finishedSinceStart ||
            _engine.processingState == ProcessingState.completed
        ? null
        : Duration(milliseconds: _engine.position.inMilliseconds);
    while (!_disposed && !_exiting) {
      final state = _library.stateOf(id);
      if (!resuming &&
          (_finishedSinceStart || state.status != EpisodeStatus.none)) {
        return false;
      }
      final target = _seekPosition(_startPosition(state));
      if (target == applied) return true;
      await _seekEngine(target);
      applied = target;
    }
    return false;
  }

  Future<void> _resumeLoaded({int? focusRevision}) async {
    try {
      await _engine.prepareToPlay();
      if (!await _preparePaused(resuming: focusRevision == null) ||
          _sleepExpired) {
        await _engine.releaseFocus();
        return;
      }
      final state = _library.stateOf(_current!.id);
      if (focusRevision != null &&
          (focusRevision != _focusRevision ||
              _finishedSinceStart ||
              state.status != EpisodeStatus.none)) {
        if (!_resumeOnFocus) await _engine.releaseFocus();
        return;
      }
      await _startEngine(state);
    } on _AudioFocusUnavailable {
      await _fail(PlaybackErrorReason.audioFocusUnavailable);
    } on Object {
      await _fail(PlaybackErrorReason.streamFailed);
    }
  }

  Future<void> _startEngine(EpisodeState state) async {
    _pausedAt = null;
    _endObservedAt = null;
    _finishedSinceStart = false;
    final attempt = _playAttempt = Object();
    final id = state.episodeId;
    final starting = _engine.play(
      onError: (_, _) => _observeStreamFailure(attempt),
    );
    _setSyncEpisode(id);
    await starting;
    if (_disposed || _failureAttempt != null) return;
    if (!_engine.playing && _endObservedAt == null) {
      throw const _AudioFocusUnavailable();
    }
    if (state.status != EpisodeStatus.none &&
        identical(_library.stateOf(id), state)) {
      await _library.prepareForPlayback(id);
    }
    _publish();
  }

  @override
  Future<void> pause() {
    _cancelFocusResume();
    return _run(_pause);
  }

  void _cancelFocusResume() {
    _focusRevision++;
    _resumeOnFocus = false;
  }

  void _onInterruption(PlaybackInterruption interruption) {
    final revision = _focusRevision;
    switch (interruption) {
      case PlaybackInterruption.transientLoss:
        _background(
          _run(() async {
            if (!isPlaying) return;
            _resumeOnFocus = revision == _focusRevision;
            await _pause(keepFocus: _resumeOnFocus);
          }),
        );
      case PlaybackInterruption.regained:
        _background(
          _run(() async {
            if (!_resumeOnFocus || revision != _focusRevision) return;
            _resumeOnFocus = false;
            if (_loaded && !_exiting) {
              await _resumeLoaded(focusRevision: revision);
            }
          }),
        );
      case PlaybackInterruption.permanentLoss:
        _background(pause());
    }
  }

  Future<void> _pause({bool keepFocus = false}) async {
    try {
      if (!_loaded || _pausedAt != null) return;
      _pausedAt = _clock();
      await _engine.pause().timeout(const Duration(seconds: 5));
      await _report();
    } finally {
      _library.requestPendingSend();
      _setSyncEpisode(null);
      _publish();
      if (!keepFocus) await _engine.releaseFocus();
    }
  }

  @override
  Future<void> seekBy(Duration delta) =>
      _run(() => _seek(delta, relative: true));

  @override
  Future<void> seekTo(Duration position) => _run(() => _seek(position));

  Duration _seekPosition(Duration target) {
    if (target.isNegative) return Duration.zero;
    final end = _measuredDuration;
    if (end == null || target < end) return target;
    // Seeking exactly to EOF can complete without decoding another sample.
    return end > const Duration(milliseconds: 1)
        ? end - const Duration(milliseconds: 1)
        : Duration.zero;
  }

  Future<void> _seekEngine(Duration target) async {
    _seeking = true;
    try {
      await _engine.seek(target).timeout(const Duration(seconds: 5));
    } finally {
      _seeking = false;
    }
  }

  Future<void> _seek(Duration position, {bool relative = false}) async {
    if (!_loaded) return;
    try {
      if (_pausedAt != null && !await _preparePaused(resuming: false)) return;
      final target = _seekPosition(
        relative ? _engine.position + position : position,
      );
      final issuedAt = _playbackEventTime();
      await _seekEngine(target);
      await _report(position: target, updatedAt: issuedAt);
      _library.requestPendingSend();
      _publish();
    } on Object {
      if (_endObservedAt == null && _failureAttempt == null) {
        await _fail(PlaybackErrorReason.seekFailed);
      }
    }
  }

  @override
  Future<void> setSpeed(double speed) => _run(() async {
    await _engine.setSpeed(speed);
    _speed = speed;
    _settings.speed = speed;
    _publish();
  });

  @override
  Future<void> setSleepTimer(Duration? duration) => _run(() async {
    _cancelSleepTimer();
    _sleepAtEndOfEpisode = false;
    if (duration != null) {
      _sleepDuration = duration;
      _sleepElapsed = Stopwatch()..start();
      _sleepTimer = Timer(duration, () {
        final timer = _sleepTimer;
        _sleepExpired = true;
        _cancelFocusResume();
        _background(
          _run(() async {
            if (timer != _sleepTimer) return;
            _cancelSleepTimer();
            await _pause();
          }),
        );
      });
    }
    _publish();
  });

  @override
  Future<void> setSleepAtEndOfEpisode(bool on) => _run(() async {
    if (on) _cancelSleepTimer();
    _sleepAtEndOfEpisode = on;
    _publish();
  });

  void _cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepElapsed = null;
    _sleepDuration = null;
    _sleepExpired = false;
  }

  @override
  Future<void> stop() {
    _cancelFocusResume();
    return _run(() async {
      _cancelSleepTimer();
      _sleepAtEndOfEpisode = false;
      try {
        await _pause();
      } finally {
        if (_current != null) await _clear();
      }
    });
  }

  Future<void> _clear({bool stopEngine = true}) async {
    _current = null;
    _loaded = false;
    _loading = false;
    _advancing = false;
    _pausedAt = null;
    _endObservedAt = null;
    _playAttempt = null;
    _failureAttempt = null;
    _lastPlaybackError = null;
    _setSyncEpisode(null);
    try {
      if (stopEngine) await _engine.stop();
      await _engine.releaseFocus();
    } finally {
      _publish();
    }
  }

  void _setSyncEpisode(int? id) {
    if (_syncEpisode == id) return;
    _syncEpisode = id;
    _sync.setPlayingEpisode(id);
  }

  void _onLibraryChanged() {
    if (_loaded && !_isUnfinished(_current!.id)) {
      _finishedSinceStart = true;
    }
  }

  void _onEngineChanged() {
    if (_disposed) return;
    final attempt = _playAttempt;
    if (_loaded && _syncEpisode != null && attempt != null) {
      switch (_engine.processingState) {
        case ProcessingState.completed when _failureAttempt == null:
          if (_endObservedAt == null) {
            final endedAt = _endObservedAt = _playbackEventTime();
            _background(
              _run(() async {
                if (_endObservedAt == endedAt &&
                    identical(_playAttempt, attempt)) {
                  await _complete(endedAt);
                }
              }),
            );
          }
        case ProcessingState.idle:
          _observeStreamFailure(attempt);
        default:
          if (!_engine.playing && _pausedAt == null) {
            _background(
              _run(() async {
                if (identical(_playAttempt, attempt) &&
                    _syncEpisode != null &&
                    !_engine.playing) {
                  await _pause();
                }
              }),
            );
          }
      }
    }
    _publish(updatePosition: !isPlaying && !_seeking, forceMediaUpdate: false);
  }

  void _observeStreamFailure(Object attempt) {
    if (_disposed ||
        !identical(_playAttempt, attempt) ||
        _failureAttempt != null ||
        _endObservedAt != null) {
      return;
    }
    _failureAttempt = attempt;
    final observedAt = _playbackEventTime();
    final sample = _seeking ? null : _engine.position;
    _publish(updatePosition: false);
    _background(
      _run(() async {
        if (identical(_playAttempt, attempt)) {
          await _fail(
            PlaybackErrorReason.streamFailed,
            sample: sample,
            observedAt: observedAt,
          );
        }
      }),
    );
  }

  Future<void> _fail(
    PlaybackErrorReason reason, {
    Duration? sample,
    DateTime? observedAt,
  }) async {
    final episode = _current!;
    final duration = _measuredDuration;
    _cancelFocusResume();
    _lastPlaybackError = PlaybackError(episode, reason);
    _loading = false;
    _loaded = false;
    _advancing = false;
    _pausedAt = _clock();
    _endObservedAt = null;
    _playAttempt = null;
    _failureAttempt = null;
    _setSyncEpisode(null);
    final state = _library.stateOf(episode.id);
    if (sample != null &&
        sample > Duration.zero &&
        sample.inMilliseconds != state.positionMs &&
        !_finishedSinceStart) {
      _position.value = sample;
      await _library.recordPositionAt(
        episode.id,
        sample,
        duration: duration,
        updatedAt: observedAt!,
      );
    }
    _library.requestPendingSend();
    _publish(updatePosition: false);
    try {
      await _engine.stop();
    } finally {
      await _engine.releaseFocus();
    }
  }

  Duration? get _measuredDuration {
    final duration = _engine.duration;
    return duration != null && duration > Duration.zero ? duration : null;
  }

  DateTime _playbackEventTime() {
    final now = _clock();
    final previous = _library.stateOf(_current!.id).updatedAt;
    return now.isAfter(previous)
        ? now
        : previous.add(const Duration(milliseconds: 1));
  }

  Future<void> _complete(DateTime updatedAt) async {
    final id = _current!.id;
    final shouldMark = !_finishedSinceStart;
    _advancing = _mayAdvance;
    _sleepAtEndOfEpisode = false;
    _loaded = false;
    _endObservedAt = null;
    _playAttempt = null;
    _setSyncEpisode(null);
    _publish();
    try {
      if (shouldMark) {
        await _library.markCompletedAt(id, updatedAt);
      } else {
        _library.requestPendingSend();
      }
      await _engine.stop();
      if (_advancing && await _playQueue(autoplay: true)) {
        _advancing = false;
        _publish();
        return;
      }
    } on Object {
      await _clear();
      rethrow;
    }
    await _clear(stopEngine: false);
  }

  Future<void> _report({
    Duration? position,
    DateTime? updatedAt,
    bool onlyIfChanged = false,
  }) async {
    if (!_loaded ||
        _finishedSinceStart ||
        _failureAttempt != null ||
        _endObservedAt != null) {
      return;
    }
    final id = _current!.id;
    final sample = position ?? _engine.position;
    if (onlyIfChanged &&
        sample.inMilliseconds == _library.stateOf(id).positionMs) {
      return;
    }
    final duration = _measuredDuration;
    if (updatedAt == null) {
      await _library.recordPosition(id, sample, duration: duration);
    } else {
      await _library.recordPositionAt(
        id,
        sample,
        duration: duration,
        updatedAt: updatedAt,
      );
    }
  }

  Future<void> reportBeforeBackground() => _run(() async {
    if (isPlaying && _pausedAt == null) {
      await _report();
    }
    _library.requestPendingSend();
  });

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _background(reportBeforeBackground());
    }
  }

  @override
  void didChangeLocales(List<Locale>? locales) => _publish();

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    _exiting = true;
    await pause();
    await _sync.syncNow().timeout(const Duration(seconds: 2), onTimeout: () {});
    return AppExitResponse.exit;
  }

  void _publish({bool updatePosition = true, bool forceMediaUpdate = true}) {
    if (_disposed) return;
    final state = (
      _current,
      isPlaying,
      isBuffering,
      _speed,
      _sleepTimer,
      _sleepAtEndOfEpisode,
      _lastPlaybackError,
    );
    if (state != _visibleState) {
      _visibleState = state;
      notifyListeners();
    }
    if (isPlaying) {
      _positionTimer ??= Timer.periodic(
        const Duration(seconds: 1),
        (_) => _position.value = _engine.position,
      );
      _reportTimer ??= Timer.periodic(
        const Duration(seconds: 30),
        (_) => _background(
          _run(() async {
            if (isPlaying) await _report(onlyIfChanged: true);
          }),
        ),
      );
    } else {
      _stopTimers();
    }
    if (updatePosition && (_loaded || _current == null)) {
      _position.value = _loaded ? _engine.position : Duration.zero;
    }
    _mediaChanges.add(forceMediaUpdate);
  }

  void _stopTimers() {
    _positionTimer?.cancel();
    _positionTimer = null;
    _reportTimer?.cancel();
    _reportTimer = null;
  }

  Future<void> _run(Future<void> Function() command) {
    final result = _commands.then((_) async {
      if (!_disposed) await command();
    });
    _commands = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  @override
  void dispose() {
    _disposed = true;
    _library.removeListener(_onLibraryChanged);
    WidgetsBinding.instance.removeObserver(this);
    _setSyncEpisode(null);
    _stopTimers();
    _cancelSleepTimer();
    unawaited(_engineEvents.cancel());
    unawaited(_interruptions.cancel());
    unawaited(_mediaChanges.close());
    unawaited(_commands.whenComplete(_engine.dispose));
    _position.dispose();
    super.dispose();
  }
}

void _background(Future<void> work) {
  unawaited(
    work.catchError((Object error, StackTrace stack) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stack),
      );
    }),
  );
}
