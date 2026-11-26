import 'dart:async';

import 'package:easypodcast/player/player.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

void main() {
  final uri = Uri.parse('https://example.test/episode.mp3');
  const length = Duration(minutes: 10);
  late _Audio audio;
  late PlaybackEngine engine;

  setUp(() {
    audio = _Audio();
    engine = justAudioEngineForTest(audio);
  });
  tearDown(() => engine.dispose());

  testWidgets('Linux load waits for the duration and the resume seek', (
    tester,
  ) async {
    const saved = Duration(minutes: 3);
    audio.seekResult = Completer<void>();
    var loaded = false;
    final loading = engine.load(uri, saved).then((_) => loaded = true);
    await tester.pump();
    expect(audio.seeks, isEmpty);
    expect(loaded, isFalse);

    audio.emit(duration: length);
    await tester.pump();
    expect(audio.seeks, [saved]);
    expect(loaded, isFalse);
    expect(engine.position, Duration.zero);

    audio.seekResult!.complete();
    await loading;
    expect(engine.position, saved);
  });

  test('keeps the playback sample across completion and idle resets', () async {
    const played = Duration(minutes: 4);
    await engine.load(uri, Duration.zero);
    audio.emit(position: played, duration: length);
    audio.emit(position: played, duration: played);
    audio.emit(state: ProcessingState.completed, duration: played);
    expect(engine.position, played);
    expect(engine.duration, length);

    audio.emit(state: ProcessingState.idle);
    expect(engine.position, played);
    expect(engine.duration, length);

    await engine.load(uri, Duration.zero);
    audio.emit(state: ProcessingState.idle);
    expect(engine.position, Duration.zero);
    expect(engine.duration, isNull);
  });

  test('a backward seek replaces the last position', () async {
    const target = Duration(minutes: 2);
    await engine.load(uri, Duration.zero);
    audio.emit(position: const Duration(minutes: 5), duration: length);
    await engine.seek(target);
    audio.emit(state: ProcessingState.idle);
    expect(engine.position, target);
  });
}

class _Audio extends Fake implements AudioPlayer {
  final _events = StreamController<PlayerEvent>.broadcast(sync: true);
  PlaybackEvent _event = PlaybackEvent();
  final seeks = <Duration?>[];
  Completer<void>? seekResult;

  @override
  Stream<PlayerEvent> get playerEventStream => _events.stream;

  @override
  Stream<Duration?> get durationStream =>
      _events.stream.map((event) => event.playbackEvent.duration);

  @override
  ProcessingState get processingState => _event.processingState;

  @override
  Duration get position => _event.updatePosition;

  @override
  Duration? get duration => _event.duration;

  @override
  Future<Duration?> setAudioSource(
    AudioSource audioSource, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    expect(initialPosition, isNull);
    emit();
    return duration;
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    seeks.add(position);
    await seekResult?.future;
    emit(position: position!, duration: duration);
  }

  void emit({
    Duration position = Duration.zero,
    Duration? duration,
    ProcessingState state = ProcessingState.ready,
  }) {
    _event = PlaybackEvent(
      processingState: state,
      updatePosition: position,
      duration: duration,
    );
    _events.add(PlayerEvent(playbackEvent: _event));
  }

  @override
  Future<void> dispose() => _events.close();
}
