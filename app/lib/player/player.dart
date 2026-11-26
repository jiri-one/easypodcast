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
  late DateTime _pausedAt;
  EpisodeState? _pausedState;
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
      await _engine.pause();
      await _report(advance: false);
    }
    _setSyncEpisode(null);
    await _loadEpisode(episode, refresh: true);
  });

  Future<void> _advanceQueue() async {
    while (!_disposed && _settings.autoplayQueue) {
      final next = _library.queue.firstOrNull;
      if (next == null) return;
      await _sync.freshStateBeforePlay(next.id);
      // A refresh can hide a finished episode, and the listener can reorder the queue.
      if (_library.queue.firstOrNull?.id != next.id) continue;
      if (!_disposed && _settings.autoplayQueue) {
        await _loadEpisode(next, refresh: false);
      }
      return;
    }
  }

  Future<void> _loadEpisode(Episode episode, {required bool refresh}) async {
    final episodeId = episode.id;
    _current = episode;
    _loaded = false;
    _pausedState = null;
    _playAttempt = null;
    _position.value = Duration.zero;
    _publish();
    try {
      if (refresh) await _sync.freshStateBeforePlay(episodeId);
      if (_disposed) return;
      final start = await _library.prepareForPlayback(episodeId);
      final file = _downloads.localFileOf(episodeId);
      final uri = file == null
          ? Uri.parse(episode.enclosureUrl)
          : Uri.file(file);
      if (_disposed) return;
      _position.value = start;
      await _engine.load(uri, start);
      await _engine.setSpeed(_speed);
      if (_disposed) return;
      _loaded = true;
      _startEngine();
    } catch (_) {
      await _clear();
      rethrow;
    }
  }

  @override
  Future<void> resume() => _run(() async {
    if (!_loaded || isPlaying) return;
    if (await _preparePaused(resuming: true)) _startEngine();
  });

  Future<bool> _preparePaused({required bool resuming}) async {
    final id = _current!.id;
    final paused = _pausedState;
    if (paused != null &&
        _clock().difference(_pausedAt) > const Duration(seconds: 30)) {
      await _sync.freshStateBeforePlay(id);
    }
    if (_disposed) return false;
    var applied = _finishedSinceStart ? null : paused ?? _library.stateOf(id);
    // Another device can update the episode while a stream seek is pending.
    while (!_disposed) {
      final state = _library.stateOf(id);
      if (!resuming &&
          (_finishedSinceStart || state.status != EpisodeStatus.none)) {
        return false;
      }
      if (state.status != EpisodeStatus.none) {
        await _library.prepareForPlayback(id);
        applied = null;
      } else if (applied == null || state.isNewerThan(applied)) {
        await _engine.seek(Duration(milliseconds: state.positionMs));
        applied = state;
      } else {
        _pausedState = state;
        return true;
      }
    }
    return false;
  }

  void _startEngine() {
    _pausedState = null;
    _finishedSinceStart = false;
    final attempt = _playAttempt = Object();
    // just_audio's play future lasts until playback pauses, stops or ends.
    _background(
      _engine.play().catchError((Object error, StackTrace stack) async {
        await _run(() async {
          if (identical(_playAttempt, attempt)) await _clear();
        });
        Error.throwWithStackTrace(error, stack);
      }),
    );
    _setSyncEpisode(_current!.id);
    _publish();
  }

  @override
  Future<void> pause() => _run(_pause);

  Future<void> _pause() async {
    if (!_loaded || _pausedState != null) return;
    await _engine.pause();
    _pausedAt = _clock();
    try {
      await _report(advance: false);
    } finally {
      if (_loaded) _pausedState = _library.stateOf(_current!.id);
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
    if (_pausedState != null && !await _preparePaused(resuming: false)) return;
    final target = relative ? _engine.position + position : position;
    final end = _measuredDuration;
    final clamped = target.isNegative
        ? Duration.zero
        : end != null && target > end
        ? end
        : target;
    await _engine.seek(clamped);
    await _report(advance: isPlaying);
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
      if (_loaded) {
        await _engine.pause();
        await _report(advance: false);
      }
    } finally {
      await _clear();
    }
  });

  Future<void> _clear() async {
    _current = null;
    _loaded = false;
    _pausedState = null;
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
    if (!completed && (isPlaying || _syncEpisode == null)) return;
    final attempt = _playAttempt;
    _background(
      _run(() async {
        if (!identical(_playAttempt, attempt) || !_loaded) return;
        if (_engine.processingState == ProcessingState.completed) {
          await _report(advance: _syncEpisode != null);
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

  Future<void> _report({required bool advance}) async {
    if (!_loaded) return;
    final id = _current!.id;
    final position = _engine.position;
    final duration = _measuredDuration;
    final state = _library.stateOf(id);
    final paused = _pausedState;
    if (paused != null && state.isNewerThan(paused)) return;
    final finished = _finishedSinceStart || state.status != EpisodeStatus.none;
    if (_engine.processingState == ProcessingState.completed ||
        (duration != null &&
            duration - position <= const Duration(seconds: 30))) {
      await _clear();
      if (!finished) await _library.markCompleted(id);
      if (advance) await _advanceQueue();
    } else if (!finished) {
      await _library.recordPosition(id, position, duration: duration);
      if (paused != null) {
        final saved = _library.stateOf(id);
        if (saved.positionMs == position.inMilliseconds) _pausedState = saved;
      }
    }
  }

  Future<void> reportBeforeBackground() =>
      _run(() => _report(advance: isPlaying));

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
