import 'dart:async';

import 'package:easypodcast/player/player.dart';
import 'package:just_audio/just_audio.dart';

class FakePlaybackEngine implements PlaybackEngine {
  FakePlaybackEngine(this.now);

  final DateTime Function() now;
  final _changes = StreamController<void>.broadcast(sync: true);
  DateTime? _startedAt;
  Duration _position = Duration.zero;
  double _speed = 1;
  Object? loadError;
  Object? seekError;
  bool focusAvailable = true;
  void Function(Object, StackTrace)? _onError;
  int loadCalls = 0;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Stream<PlaybackInterruption> get interruptions => const Stream.empty();

  @override
  bool get playing => _startedAt != null;

  @override
  ProcessingState processingState = ProcessingState.idle;

  @override
  Duration get position {
    final startedAt = _startedAt;
    return startedAt == null
        ? _position
        : _position +
              Duration(seconds: now().difference(startedAt).inSeconds) * _speed;
  }

  @override
  Duration get bufferedPosition => position;

  @override
  Duration? get duration => null;

  @override
  Future<void> prepareToPlay() async {}

  @override
  Future<void> load(Uri uri, Duration position) async {
    loadCalls++;
    if (loadError case final error?) throw error;
    processingState = ProcessingState.ready;
    _position = position;
  }

  @override
  Future<void> play({
    required void Function(Object, StackTrace) onError,
  }) async {
    if (!focusAvailable) return;
    _onError = onError;
    _startedAt = now();
  }

  @override
  Future<void> pause() async {
    _position = position;
    _startedAt = null;
  }

  @override
  Future<void> releaseFocus() async {}

  @override
  Future<void> seek(Duration position) async {
    if (seekError case final error?) throw error;
    _position = position;
    if (playing) _startedAt = now();
  }

  @override
  Future<void> setSpeed(double speed) async {
    await seek(position);
    _speed = speed;
  }

  @override
  Future<void> stop() async {
    await pause();
    processingState = ProcessingState.idle;
  }

  void buffer() {
    processingState = ProcessingState.buffering;
    _changes.add(null);
  }

  void complete(Duration end) {
    _position = end;
    _startedAt = null;
    processingState = ProcessingState.completed;
    _changes.add(null);
  }

  void failStream() =>
      _onError!(StateError('stream failed'), StackTrace.current);

  @override
  Future<void> dispose() => _changes.close();
}
