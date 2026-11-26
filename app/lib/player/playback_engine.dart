part of 'player.dart';

enum PlaybackInterruption { transientLoss, regained, permanentLoss }

abstract interface class PlaybackEngine {
  Stream<void> get changes;
  Stream<PlaybackInterruption> get interruptions;
  bool get playing;
  ProcessingState get processingState;
  Duration get position;
  Duration get bufferedPosition;
  Duration? get duration;
  Future<void> prepareToPlay();
  Future<void> load(Uri uri, Duration position);
  Future<void> play({required void Function(Object, StackTrace) onError});
  Future<void> pause();
  Future<void> releaseFocus();
  Future<void> seek(Duration position);
  Future<void> setSpeed(double speed);
  Future<void> stop();
  Future<void> dispose();
}

class _JustAudioEngine implements PlaybackEngine {
  _JustAudioEngine(this._session, {AudioPlayer? audio})
    : _audio =
          audio ??
          AudioPlayer(
            handleInterruptions: false,
            handleAudioSessionActivation: false,
            androidApplyAudioAttributes: _session != null,
          ) {
    _audioEvents = _audio.playerEventStream.listen((event) {
      final sample = event.playbackEvent;
      if (sample.updatePosition > _lastPosition) {
        _lastPosition = sample.updatePosition;
      }
      // A truncated stream can report a shorter duration.
      if (sample.duration case final duration?
          when duration > (_knownDuration ?? Duration.zero)) {
        _knownDuration = duration;
      }
      _changes.add(null);
    });
    if (_session case final session?) {
      _sessionEvents.add(
        session.becomingNoisyEventStream.listen((_) {
          _interruptions.add(PlaybackInterruption.permanentLoss);
        }),
      );
      _sessionEvents.add(
        session.interruptionEventStream.listen((event) {
          final interruption = switch ((event.begin, event.type)) {
            (true, AudioInterruptionType.pause) =>
              PlaybackInterruption.transientLoss,
            (false, AudioInterruptionType.pause) =>
              PlaybackInterruption.regained,
            (true, AudioInterruptionType.unknown) =>
              PlaybackInterruption.permanentLoss,
            _ => null,
          };
          if (interruption != null) _interruptions.add(interruption);
        }),
      );
    }
  }

  static Future<_JustAudioEngine> open() async {
    final session = Platform.isAndroid ? await AudioSession.instance : null;
    // speech() asks Android to pause instead of ducking, so every
    // notification sound paused the podcast.
    await session?.configure(const AudioSessionConfiguration.music());
    return _JustAudioEngine(session);
  }

  final AudioPlayer _audio;
  final AudioSession? _session;
  final _changes = StreamController<void>.broadcast(sync: true);
  final _interruptions = StreamController<PlaybackInterruption>.broadcast();
  final _sessionEvents = <StreamSubscription<void>>[];
  late final StreamSubscription<PlayerEvent> _audioEvents;
  Duration _lastPosition = Duration.zero;
  Duration? _knownDuration;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Stream<PlaybackInterruption> get interruptions => _interruptions.stream;

  @override
  bool get playing => _audio.playing;

  @override
  ProcessingState get processingState => _audio.processingState;

  bool get _terminal =>
      processingState == ProcessingState.completed ||
      processingState == ProcessingState.idle;

  @override
  Duration get position {
    final position = _audio.position;
    if (position > _lastPosition) _lastPosition = position;
    return _terminal ? _lastPosition : position;
  }

  @override
  Duration get bufferedPosition => _audio.bufferedPosition;

  @override
  Duration? get duration =>
      _terminal ? _knownDuration ?? _audio.duration : _audio.duration;

  @override
  Future<void> prepareToPlay() async {
    if (_session == null) return;
    final foreground = await androidPlatform.invokeMethod<bool>(
      'startForeground',
    );
    if (foreground != true) throw const _AudioFocusUnavailable();
  }

  @override
  Future<void> load(Uri uri, Duration position) async {
    await _audio.setAudioSource(
      AudioSource.uri(uri),
      initialPosition: _session == null ? null : position,
    );
    _lastPosition = _audio.position;
    _knownDuration = _audio.duration;
    if (_session == null && position > Duration.zero) {
      await seek(position).timeout(const Duration(seconds: 5));
    }
  }

  @override
  Future<void> play({
    required void Function(Object, StackTrace) onError,
  }) async {
    if (_session case final session?) {
      if (!await activatePlaybackFocus((active) => session.setActive(active))) {
        throw const _AudioFocusUnavailable();
      }
      // Android resolves this future when playback ends or pauses.
      unawaited(_audio.play().catchError(onError));
    } else {
      await _audio.play();
    }
  }

  @override
  Future<void> pause() => _audio.pause();

  @override
  Future<void> releaseFocus() async {
    await _session?.setActive(false);
  }

  @override
  Future<void> seek(Duration position) async {
    if (_session == null &&
        position > Duration.zero &&
        (_audio.duration?.inSeconds ?? 0) == 0) {
      // MediaKit defers seeks until it knows the duration.
      await _audio.durationStream
          .where((duration) => (duration?.inSeconds ?? 0) > 0)
          .timeout(const Duration(seconds: 4))
          .first;
    }
    await _audio.seek(_positionBeforeEnd(position, _audio.duration));
    _lastPosition = _audio.position;
  }

  @override
  Future<void> setSpeed(double speed) => _audio.setSpeed(speed);

  @override
  Future<void> stop() => _audio.stop();

  @override
  Future<void> dispose() async {
    await _audioEvents.cancel();
    await _changes.close();
    for (final subscription in _sessionEvents) {
      await subscription.cancel();
    }
    await _interruptions.close();
    await releaseFocus();
    await _audio.dispose();
  }
}

Duration _positionBeforeEnd(Duration target, Duration? end) {
  if (target.isNegative) return Duration.zero;
  if (end == null || end <= Duration.zero || target < end) return target;
  // Seeking exactly to EOF can complete without decoding another sample.
  return end > const Duration(milliseconds: 1)
      ? end - const Duration(milliseconds: 1)
      : Duration.zero;
}

@visibleForTesting
PlaybackEngine justAudioEngineForTest(AudioPlayer audio) =>
    _JustAudioEngine(null, audio: audio);

class _AudioFocusUnavailable implements Exception {
  const _AudioFocusUnavailable();
}

@visibleForTesting
Future<bool> activatePlaybackFocus(
  Future<bool> Function(bool) setActive,
) async {
  final granted = await setActive(true);
  if (!granted) await setActive(false);
  return granted;
}
