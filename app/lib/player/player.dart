import 'dart:async';
import 'dart:io';

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
    _pauseRequests = _engine.pauseRequests.listen((_) {
      if (isPlaying) _background(pause());
    });
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
  late final StreamSubscription<void> _pauseRequests;
  Future<void> _commands = Future.value();
  Episode? _current;
  DateTime? _pausedAt;
  DateTime? _endObservedAt;
  bool _finishedSinceStart = false;
  bool _loaded = false;
  bool _disposed = false;
  int? _syncEpisode;
  double _speed;
  Timer? _positionTimer;
  Timer? _reportTimer;
  Timer? _sleepTimer;
  Stopwatch? _sleepElapsed;
  Duration? _sleepDuration;
  Object? _playAttempt;
  (Episode?, bool, bool, double, Timer?)? _visibleState;

  @override
  Episode? get current => _current;

  @override
  bool get isPlaying => _loaded && _engine.playing;

  @override
  bool get isBuffering =>
      _current != null &&
      (!_loaded ||
          _engine.processingState == ProcessingState.loading ||
          _engine.processingState == ProcessingState.buffering);

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
  Future<void> play(int episodeId) => _run(() async {
    final episode = _library.episode(episodeId);
    if (episode == null) return;
    if (_current?.id == episodeId &&
        isPlaying &&
        !_finishedSinceStart &&
        _library.stateOf(episodeId).status == EpisodeStatus.none) {
      return;
    }

    if (_loaded && (_current?.id != episodeId || isPlaying)) {
      await _pause();
    }
    await _loadEpisode(episode);
  });

  Future<void> _advanceQueue() async {
    while (!_disposed && _settings.autoplayQueue) {
      final id = _library.queueHeadId;
      if (id == null) return;
      final next = await _library.resolveQueueEpisode(id);
      if (_library.queueHeadId != id) continue;
      if (next == null || _disposed || !_settings.autoplayQueue) return;
      await _sync.freshStateBeforePlay(id);
      if (_library.queueHeadId != id) continue;
      if (_disposed || !_settings.autoplayQueue) return;
      if (await _loadEpisode(next, automatic: true)) return;
    }
  }

  Future<bool> _loadEpisode(Episode episode, {bool automatic = false}) async {
    final episodeId = episode.id;
    _current = episode;
    _loaded = false;
    _pausedAt = null;
    _playAttempt = null;
    _position.value = Duration.zero;
    _publish();
    try {
      if (!automatic) await _sync.freshStateBeforePlay(episodeId);
      if (_disposed) return false;
      var applied = _startPosition(_library.stateOf(episodeId));
      final file = _downloads.localFileOf(episodeId);
      final uri = file == null
          ? Uri.parse(episode.enclosureUrl)
          : Uri.file(file);
      _position.value = applied;
      await _engine.load(uri, applied);
      await _engine.setSpeed(_speed);
      while (!_disposed) {
        if (automatic &&
            (!_settings.autoplayQueue || _library.queueHeadId != episodeId)) {
          await _clear();
          return false;
        }
        final state = _library.stateOf(episodeId);
        final target = _startPosition(state);
        if (target == applied) {
          _loaded = true;
          await _startEngine(state);
          return true;
        }
        await _engine.seek(target);
        applied = target;
      }
      return false;
    } catch (_) {
      if (_current != null) await _clear();
      rethrow;
    }
  }

  @override
  Future<void> resume() => _run(() async {
    if (!_loaded || isPlaying) return;
    await _preparePaused(resuming: true);
  });

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
    if (_disposed) return false;
    var applied = _finishedSinceStart
        ? null
        : Duration(milliseconds: _engine.position.inMilliseconds);
    while (!_disposed) {
      final state = _library.stateOf(id);
      if (!resuming &&
          (_finishedSinceStart || state.status != EpisodeStatus.none)) {
        return false;
      }
      final target = _startPosition(state);
      if (target == applied) {
        if (resuming) await _startEngine(state);
        return true;
      }
      await _engine.seek(target);
      applied = target;
    }
    return false;
  }

  Future<void> _startEngine(EpisodeState state) async {
    _pausedAt = null;
    _endObservedAt = null;
    _finishedSinceStart = false;
    final attempt = _playAttempt = Object();
    final id = state.episodeId;
    var startFailed = false;
    try {
      final starting = _engine.play(
        onError: (error, stack) {
          startFailed = true;
          _background(
            _run(() async {
              if (!identical(_playAttempt, attempt)) return;
              await _clear();
              Error.throwWithStackTrace(error, stack);
            }),
          );
        },
      );
      _setSyncEpisode(id);
      await starting;
    } catch (_) {
      await _clear();
      rethrow;
    }
    if (_disposed || startFailed) return;
    if (!isPlaying) {
      _pausedAt = _clock();
      _playAttempt = null;
      _setSyncEpisode(null);
    } else if (state.status != EpisodeStatus.none &&
        identical(_library.stateOf(id), state)) {
      _finishedSinceStart = false;
      await _library.prepareForPlayback(id);
    }
    _publish();
  }

  @override
  Future<void> pause() => _run(_pause);

  Future<void> _pause() async {
    if (!_loaded) return;
    if (_pausedAt != null) {
      _library.requestPendingSend();
      return;
    }
    await _engine.pause();
    _pausedAt = _clock();
    try {
      await _report(advance: false);
    } finally {
      _setSyncEpisode(null);
      _publish();
    }
  }

  @override
  Future<void> seekBy(Duration delta) =>
      _run(() => _seek(delta, relative: true));

  @override
  Future<void> seekTo(Duration position) => _run(() => _seek(position));

  Future<void> _seek(Duration position, {bool relative = false}) async {
    if (!_loaded) return;
    if (_pausedAt != null && !await _preparePaused(resuming: false)) return;
    final target = relative ? _engine.position + position : position;
    final end = _measuredDuration;
    final clamped = target.isNegative
        ? Duration.zero
        : end != null && target > end
        ? end
        : target;
    final issuedAt = _playbackEventTime();
    await _engine.seek(clamped);
    await _report(advance: isPlaying, position: clamped, updatedAt: issuedAt);
    _publish();
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
    if (duration != null) {
      _sleepDuration = duration;
      _sleepElapsed = Stopwatch()..start();
      _sleepTimer = Timer(duration, () {
        final timer = _sleepTimer;
        _background(
          _run(() async {
            if (timer != _sleepTimer) return;
            _cancelSleepTimer();
            await _pause();
            _publish();
          }),
        );
      });
    }
    _publish();
  });

  void _cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepElapsed = null;
    _sleepDuration = null;
  }

  @override
  Future<void> stop() => _run(() async {
    _cancelSleepTimer();
    try {
      await _pause();
    } finally {
      if (_current != null) await _clear();
    }
  });

  Future<void> _clear() async {
    _current = null;
    _loaded = false;
    _pausedAt = null;
    _endObservedAt = null;
    _playAttempt = null;
    _setSyncEpisode(null);
    try {
      await _engine.stop();
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
    if (_loaded &&
        _library.stateOf(_current!.id).status != EpisodeStatus.none) {
      _finishedSinceStart = true;
    }
  }

  void _onEngineChanged() {
    if (_disposed) return;
    _publish(updatePosition: !isPlaying, forceMediaUpdate: false);
    if (!_loaded) return;
    final completed = _engine.processingState == ProcessingState.completed;
    final endedAt = completed
        ? (_endObservedAt ??= _playbackEventTime())
        : null;
    if (!completed && (isPlaying || _syncEpisode == null)) return;
    final attempt = _playAttempt;
    _background(
      _run(() async {
        if (!identical(_playAttempt, attempt) || !_loaded) return;
        if (endedAt != null &&
            _engine.processingState == ProcessingState.completed) {
          await _complete(endedAt, advance: _syncEpisode != null);
        } else if (!isPlaying && _syncEpisode != null) {
          await _pause();
        }
      }),
    );
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

  Future<void> _complete(DateTime updatedAt, {required bool advance}) async {
    final id = _current!.id;
    _setSyncEpisode(null);
    try {
      if (!_finishedSinceStart) await _library.markCompletedAt(id, updatedAt);
    } finally {
      await _clear();
    }
    if (advance) await _advanceQueue();
  }

  Future<void> _report({
    required bool advance,
    Duration? position,
    DateTime? updatedAt,
  }) async {
    if (!_loaded) return;
    final id = _current!.id;
    final sample = position ?? _engine.position;
    final duration = _measuredDuration;
    final completed = _engine.processingState == ProcessingState.completed;
    if (completed ||
        (duration != null &&
            duration - sample <= const Duration(seconds: 30))) {
      await _complete(
        (completed ? _endObservedAt : null) ??
            updatedAt ??
            _playbackEventTime(),
        advance: advance,
      );
    } else if (!_finishedSinceStart) {
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
  }

  Future<void> reportBeforeBackground() => _run(() async {
    if (isPlaying && _pausedAt == null) {
      await _report(advance: true);
    } else {
      _library.requestPendingSend();
    }
  });

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        (Platform.isLinux && state == AppLifecycleState.hidden)) {
      _background(reportBeforeBackground());
    }
  }

  void _publish({bool updatePosition = true, bool forceMediaUpdate = true}) {
    if (_disposed) return;
    final state = (_current, isPlaying, isBuffering, _speed, _sleepTimer);
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
            if (isPlaying) await _report(advance: true);
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
    unawaited(_pauseRequests.cancel());
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
