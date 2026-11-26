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
  _JustAudioEngine(this._session)
    : _audio = AudioPlayer(
        handleInterruptions: false,
        handleAudioSessionActivation: false,
        androidApplyAudioAttributes: _session != null,
      ) {
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
    await session?.configure(const AudioSessionConfiguration.speech());
    return _JustAudioEngine(session);
  }

  final AudioPlayer _audio;
  final AudioSession? _session;
  final _interruptions = StreamController<PlaybackInterruption>.broadcast();
  final _sessionEvents = <StreamSubscription<void>>[];

  @override
  Stream<void> get changes => _audio.playerEventStream.map((_) {});

  @override
  Stream<PlaybackInterruption> get interruptions => _interruptions.stream;

  @override
  bool get playing => _audio.playing;

  @override
  ProcessingState get processingState => _audio.processingState;

  @override
  Duration get position => _audio.position;

  @override
  Duration get bufferedPosition => _audio.bufferedPosition;

  @override
  Duration? get duration => _audio.duration;

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
    await _audio.seek(position);
  }

  @override
  Future<void> setSpeed(double speed) => _audio.setSpeed(speed);

  @override
  Future<void> stop() => _audio.stop();

  @override
  Future<void> dispose() async {
    for (final subscription in _sessionEvents) {
      await subscription.cancel();
    }
    await _interruptions.close();
    await releaseFocus();
    await _audio.dispose();
  }
}

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
