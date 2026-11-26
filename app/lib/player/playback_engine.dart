part of 'player.dart';

abstract interface class PlaybackEngine {
  Stream<void> get changes;
  Stream<void> get pauseRequests;
  bool get playing;
  ProcessingState get processingState;
  Duration get position;
  Duration get bufferedPosition;
  Duration? get duration;
  Future<void> load(Uri uri, Duration position);
  Future<void> play({required void Function(Object, StackTrace) onError});
  Future<void> pause();
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
          _pauseRequests.add(null);
        }),
      );
      _sessionEvents.add(
        session.interruptionEventStream.listen((event) {
          if (event.begin) _pauseRequests.add(null);
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
  final _pauseRequests = StreamController<void>.broadcast();
  final _sessionEvents = <StreamSubscription<void>>[];

  @override
  Stream<void> get changes => _audio.playerEventStream.map((_) {});

  @override
  Stream<void> get pauseRequests => _pauseRequests.stream;

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
  Future<void> load(Uri uri, Duration position) async {
    await _audio.setAudioSource(
      AudioSource.uri(uri),
      initialPosition: position,
    );
  }

  @override
  Future<void> play({
    required void Function(Object, StackTrace) onError,
  }) async {
    if (_session case final session?) {
      if (!await session.setActive(true)) return;
      // Android resolves this future when playback ends or pauses.
      unawaited(_audio.play().catchError(onError));
    } else {
      await _audio.play();
    }
  }

  @override
  Future<void> pause() => _audio.pause();

  @override
  Future<void> seek(Duration position) => _audio.seek(position);

  @override
  Future<void> setSpeed(double speed) => _audio.setSpeed(speed);

  @override
  Future<void> stop() => _audio.stop();

  @override
  Future<void> dispose() async {
    for (final subscription in _sessionEvents) {
      await subscription.cancel();
    }
    await _pauseRequests.close();
    await _audio.dispose();
  }
}
