import 'dart:async';

import 'package:easypodcast/core/downloads.dart';
import 'package:easypodcast/core/library.dart';
import 'package:easypodcast/core/models.dart';
import 'package:easypodcast/core/settings.dart';
import 'package:easypodcast/core/sync.dart';
import 'package:easypodcast/player/player.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _first = Episode(
  id: 1,
  podcastId: 1,
  guid: 'one',
  title: 'Morning Field Notes',
  enclosureUrl: 'http://example.test/one.mp3',
  durationS: 60,
);
const _second = Episode(
  id: 2,
  podcastId: 1,
  guid: 'two',
  title: 'Evening Field Notes',
  enclosureUrl: 'https://example.test/two.mp3',
  durationS: 120,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Settings settings;
  late _Library library;
  late _Sync sync;
  late _Engine engine;
  late EpisodePlayer player;
  late List<String> calls;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = await Settings.load();
  });

  void openPlayer() {
    calls = [];
    library = _Library(calls);
    sync = _Sync(calls);
    engine = _Engine();
    player = EpisodePlayer(
      library: library,
      sync: sync,
      downloads: _Downloads(),
      settings: settings,
      engine: engine,
    );
    addTearDown(() {
      player.dispose();
      library.dispose();
      settings.dispose();
    });
  }

  testWidgets('refresh, prepare and identify each playback to sync', (_) async {
    openPlayer();
    await player.play(_first.id);

    expect(calls, ['refresh:1', 'prepare:1', 'playing:1']);
    expect(engine.uri, Uri.file('/downloads/episode.mp3'));
    expect(engine.position, const Duration(seconds: 10));

    engine.position = const Duration(seconds: 12);
    await player.pause();
    expect(calls, containsAllInOrder(['record:1:12000', 'playing:null']));

    await player.resume();
    expect(calls.sublist(calls.length - 3), [
      'refresh:1',
      'prepare:1',
      'playing:1',
    ]);
    expect(engine.position, const Duration(seconds: 12));
  });

  testWidgets(
    'pause, interruption, seek, periodic, background and stop report',
    (tester) async {
      openPlayer();
      await player.play(_first.id);
      var mainNotifications = 0;
      player.addListener(() => mainNotifications++);

      engine.position = const Duration(seconds: 17);
      await tester.pump(const Duration(seconds: 1));
      expect(player.position.value, const Duration(seconds: 17));
      expect(mainNotifications, 0);

      await tester.pump(const Duration(seconds: 29));
      expect(calls.last, 'record:1:17000');

      await player.seekTo(const Duration(seconds: 55));
      expect(calls.last, 'record:1:55000');
      expect(library.completed, isEmpty);

      await player.reportBeforeBackground();
      expect(calls.where((call) => call == 'record:1:55000'), hasLength(2));

      engine.position = const Duration(seconds: 60);
      engine.interruptions.add(null);
      await tester.pump();
      expect(player.isPlaying, isFalse);
      expect(calls, containsAllInOrder(['record:1:60000', 'playing:null']));

      await player.seekBy(const Duration(seconds: -15));
      expect(player.isPlaying, isFalse);
      expect(calls.last, 'record:1:45000');

      await player.stop();
      expect(calls.where((call) => call == 'record:1:45000'), hasLength(2));
      expect(player.current, isNull);
    },
  );

  testWidgets('reports a pause initiated by the playback engine', (
    tester,
  ) async {
    openPlayer();
    await player.play(_first.id);

    engine.position = const Duration(seconds: 42);
    engine.playing = false;
    engine.events.add(null);
    await tester.pump();

    expect(calls.sublist(calls.length - 2), ['record:1:42000', 'playing:null']);
    expect(player.isPlaying, isFalse);
  });

  testWidgets('completes at 30 seconds from real duration and advances', (
    _,
  ) async {
    openPlayer();
    await player.play(_first.id);

    await player.seekTo(const Duration(seconds: 569));
    expect(calls.last, 'record:1:569000');
    expect(library.completed, isEmpty);
    await player.seekBy(const Duration(seconds: 1));

    expect(library.completed, [1]);
    expect(library.queue.map((episode) => episode.id), [2]);
    expect(
      calls,
      containsAllInOrder([
        'playing:null',
        'completed:1',
        'refresh:2',
        'prepare:2',
        'playing:2',
      ]),
    );
    expect(player.current?.id, 2);
    expect(engine.uri, Uri.parse(_second.enclosureUrl));
  });

  testWidgets('completion event handles unknown duration and autoplay off', (
    tester,
  ) async {
    openPlayer();
    settings.autoplayQueue = false;
    await player.play(_first.id);
    engine.duration = null;
    expect(player.duration, const Duration(seconds: 60));

    await player.seekTo(const Duration(seconds: 60));
    expect(library.completed, isEmpty);

    engine.processingState = ProcessingState.completed;
    engine.events.add(null);
    await tester.pump();

    expect(library.completed, [1]);
    expect(calls, isNot(contains('refresh:2')));
    expect(player.isPlaying, isFalse);
    expect(player.current, isNull);
  });

  testWidgets('sleep expiry completes without starting another episode', (
    tester,
  ) async {
    openPlayer();
    await player.play(_first.id);
    await player.setSpeed(1.4);
    expect(settings.speed, 1.4);
    await player.setSleepTimer(const Duration(seconds: 2));
    expect(player.sleepRemaining, isNotNull);
    engine.position = const Duration(seconds: 590);
    await tester.pump(const Duration(seconds: 2));

    expect(library.completed, [1]);
    expect(calls, isNot(contains('refresh:2')));
    expect(player.sleepRemaining, isNull);
    expect(player.isPlaying, isFalse);
  });
}

class _Engine implements PlaybackEngine {
  final events = StreamController<void>.broadcast();
  final interruptions = StreamController<void>.broadcast();
  Uri? uri;
  @override
  bool playing = false;
  @override
  Duration position = Duration.zero;
  @override
  Duration? duration = const Duration(minutes: 10);
  @override
  ProcessingState processingState = ProcessingState.idle;

  @override
  Duration get bufferedPosition => position;
  @override
  Stream<void> get changes => events.stream;
  @override
  Stream<void> get pauseRequests => interruptions.stream;

  @override
  Future<void> load(Uri uri, Duration position) async {
    this.uri = uri;
    this.position = position;
    processingState = ProcessingState.ready;
  }

  @override
  Future<void> pause() async => playing = false;

  @override
  Future<void> play() async => playing = true;

  @override
  Future<void> seek(Duration position) async => this.position = position;

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> stop() async {
    playing = false;
    processingState = ProcessingState.idle;
  }

  @override
  Future<void> dispose() async {
    await events.close();
    await interruptions.close();
  }
}

class _Library extends Library {
  _Library(this.calls);
  final List<String> calls;
  final completed = <int>[];
  final _positions = <int, Duration>{1: const Duration(seconds: 10)};

  @override
  final queue = [_first, _second];

  @override
  Episode? episode(int id) => switch (id) {
    1 => _first,
    2 => _second,
    _ => null,
  };

  @override
  EpisodeState stateOf(int id) => EpisodeState.initial(id);

  @override
  Future<Duration> prepareForPlayback(int id) async {
    calls.add('prepare:$id');
    return _positions[id] ?? Duration.zero;
  }

  @override
  Future<void> recordPosition(
    int id,
    Duration position, {
    Duration? duration,
  }) async {
    calls.add('record:$id:${position.inMilliseconds}');
    _positions[id] = position;
  }

  @override
  Future<void> markCompleted(int id) async {
    completed.add(id);
    calls.add('completed:$id');
    queue.removeWhere((episode) => episode.id == id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Sync implements SyncService {
  _Sync(this.calls);
  final List<String> calls;

  @override
  Future<void> freshStateBeforePlay(int id) async => calls.add('refresh:$id');

  @override
  void setPlayingEpisode(int? id) => calls.add('playing:$id');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Downloads extends DownloadService {
  @override
  String? localFileOf(int id) =>
      id == _first.id ? '/downloads/episode.mp3' : null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
