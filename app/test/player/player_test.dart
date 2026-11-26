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
const _third = Episode(
  id: 3,
  podcastId: 1,
  guid: 'three',
  title: 'Midnight Field Notes',
  enclosureUrl: 'https://example.test/three.mp3',
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
    engine = _Engine(calls);
    player = EpisodePlayer(
      library: library,
      sync: sync,
      downloads: _Downloads(),
      settings: settings,
      engine: engine,
      clock: TestWidgetsFlutterBinding.instance.clock.now,
    );
    addTearDown(() {
      player.dispose();
      library.dispose();
      settings.dispose();
    });
  }

  testWidgets('a 10-second pause resumes the loaded source', (tester) async {
    openPlayer();
    await player.play(_first.id);

    expect(calls, ['refresh:1', 'prepare:1', 'load', 'play', 'playing:1']);
    expect(engine.uri, Uri.file('/downloads/episode.mp3'));
    expect(engine.position, const Duration(seconds: 10));

    engine.position = const Duration(seconds: 12);
    await player.pause();
    expect(calls, containsAllInOrder(['record:1:12000', 'playing:null']));

    await tester.pump(const Duration(seconds: 10));
    calls.clear();
    await player.resume();
    expect(calls, ['play', 'playing:1']);
    expect(engine.position, const Duration(seconds: 12));
  });

  testWidgets('a 31-second pause adopts a newer cached rewind', (tester) async {
    openPlayer();
    await player.play(_second.id);
    engine.position = const Duration(seconds: 90);
    await player.pause();
    library.change(_second.id, position: const Duration(seconds: 40));
    calls.clear();
    await player.reportBeforeBackground();
    await tester.pump(const Duration(seconds: 31));
    await player.resume();

    expect(calls, ['refresh:2', 'seek:40000', 'play', 'playing:2']);
    expect(player.position.value, const Duration(seconds: 40));
    expect(engine.uri, Uri.parse(_second.enclosureUrl));
  });

  testWidgets('only pauses longer than 30 seconds need a refresh', (
    tester,
  ) async {
    openPlayer();
    await player.play(_second.id);
    await player.pause();
    await tester.pump(const Duration(seconds: 30));
    calls.clear();
    await player.resume();
    expect(calls, ['play', 'playing:2']);

    await player.pause();
    await tester.pump(const Duration(seconds: 31));
    calls.clear();
    await player.resume();
    expect(calls, ['refresh:2', 'play', 'playing:2']);
  });

  testWidgets('resume restarts an episode dismissed remotely during a pause', (
    tester,
  ) async {
    openPlayer();
    await player.play(_first.id);
    await player.pause();
    await tester.pump(const Duration(seconds: 31));
    sync.onRefresh = (id) =>
        library.change(id, status: EpisodeStatus.dismissed);
    calls.clear();
    await player.resume();

    expect(calls, ['refresh:1', 'prepare:1', 'seek:0', 'play', 'playing:1']);
    expect(engine.position, Duration.zero);
    expect(library.stateOf(_first.id).status, EpisodeStatus.none);
    await player.reportBeforeBackground();
    expect(calls.last, 'record:1:0');
  });

  testWidgets('resume observes a dismissal that arrives during a stream seek', (
    tester,
  ) async {
    openPlayer();
    await player.play(_second.id);
    await player.pause();
    await tester.pump(const Duration(seconds: 31));
    sync.onRefresh = (id) =>
        library.change(id, position: const Duration(seconds: 45));
    engine.onSeek = (position) {
      if (position == const Duration(seconds: 45)) {
        library.change(_second.id, status: EpisodeStatus.dismissed);
      }
    };
    calls.clear();
    await player.resume();
    expect(calls, [
      'refresh:2',
      'seek:45000',
      'prepare:2',
      'seek:0',
      'play',
      'playing:2',
    ]);
    expect(engine.position, Duration.zero);
  });

  testWidgets('paused skips and seeks refresh before applying the control', (
    tester,
  ) async {
    openPlayer();
    await player.play(_first.id);
    await player.pause();
    await tester.pump(const Duration(seconds: 31));
    sync.onRefresh = (id) =>
        library.change(id, position: const Duration(seconds: 100));
    calls.clear();
    await player.seekBy(const Duration(seconds: -15));
    expect(calls, ['refresh:1', 'seek:100000', 'seek:85000', 'record:1:85000']);
    expect(player.isPlaying, isFalse);

    calls.clear();
    await player.seekTo(const Duration(seconds: 20));
    expect(calls, ['refresh:1', 'seek:100000', 'seek:20000', 'record:1:20000']);
    expect(player.isPlaying, isFalse);

    sync.onRefresh = null;
    calls.clear();
    await player.resume();
    expect(calls, ['refresh:1', 'play', 'playing:1']);
  });

  testWidgets('position reports carry only a positive engine duration', (
    _,
  ) async {
    openPlayer();
    await player.play(_first.id);
    for (final duration in [
      const Duration(minutes: 10),
      null,
      Duration.zero,
      const Duration(seconds: -1),
    ]) {
      engine.duration = duration;
      await player.seekTo(const Duration(seconds: 55));
    }

    expect(library.reportedDurations, [
      const Duration(minutes: 10),
      null,
      null,
      null,
    ]);
    expect(library.completed, isEmpty);
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

  for (final status in [EpisodeStatus.played, EpisodeStatus.dismissed]) {
    testWidgets('autoplay skips a remotely ${status.name} queue item', (
      _,
    ) async {
      openPlayer();
      library.queued.add(_third);
      await player.play(_first.id);
      sync.onRefresh = (id) {
        if (id == _second.id) library.change(id, status: status);
      };
      calls.clear();
      await player.seekTo(const Duration(seconds: 570));

      expect(calls, [
        'seek:570000',
        'playing:null',
        'completed:1',
        'refresh:2',
        'refresh:3',
        'prepare:3',
        'load',
        'play',
        'playing:3',
      ]);
      expect(library.stateOf(_second.id).status, status);
      expect(library.queued, [_first, _second, _third]);
      expect(engine.uri, Uri.parse(_third.enclosureUrl));

      await player.play(_second.id);
      expect(library.stateOf(_second.id).status, EpisodeStatus.none);
      expect(engine.position, Duration.zero);
    });
  }

  testWidgets('autoplay stops when refresh exhausts the queue', (_) async {
    openPlayer();
    await player.play(_first.id);
    sync.onRefresh = (id) => library.change(id, status: EpisodeStatus.played);
    calls.clear();
    await player.seekTo(const Duration(seconds: 570));
    await player.reportBeforeBackground();

    expect(calls, ['seek:570000', 'playing:null', 'completed:1', 'refresh:2']);
    expect(player.current, isNull);
    expect(player.isPlaying, isFalse);
    expect(library.queue, isEmpty);
  });

  testWidgets('a marked episode sends no more positions until restarted', (
    tester,
  ) async {
    openPlayer();
    await player.play(_first.id);
    library.change(_first.id, status: EpisodeStatus.played);
    calls.clear();
    await player.seekBy(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 30));
    await player.pause();
    await tester.pump(const Duration(seconds: 31));
    await player.seekTo(const Duration(seconds: 90));
    await player.reportBeforeBackground();
    expect(library.stateOf(_first.id).status, EpisodeStatus.played);
    library.change(_first.id);
    await player.reportBeforeBackground();
    expect(calls.where((c) => c.startsWith('record:')), isEmpty);

    await player.resume();
    await player.reportBeforeBackground();
    expect(calls.last, 'record:1:0');
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
  _Engine(this.calls);
  final List<String> calls;
  void Function(Duration)? onSeek;
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
    calls.add('load');
    this.uri = uri;
    this.position = position;
    processingState = ProcessingState.ready;
  }

  @override
  Future<void> pause() async => playing = false;

  @override
  Future<void> play() async {
    calls.add('play');
    playing = true;
  }

  @override
  Future<void> seek(Duration position) async {
    calls.add('seek:${position.inMilliseconds}');
    this.position = position;
    onSeek?.call(position);
  }

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
  _Library(this.calls) {
    change(_first.id, position: const Duration(seconds: 10));
  }
  final List<String> calls;
  final completed = <int>[];
  final reportedDurations = <Duration?>[];
  final _states = <int, EpisodeState>{};
  final queued = [_first, _second];

  @override
  List<Episode> get queue => [
    for (final episode in queued)
      if (stateOf(episode.id).status == EpisodeStatus.none) episode,
  ];

  @override
  Episode? episode(int id) => switch (id) {
    1 => _first,
    2 => _second,
    3 => _third,
    _ => null,
  };

  @override
  EpisodeState stateOf(int id) => _states[id] ?? EpisodeState.initial(id);

  void change(
    int id, {
    Duration position = Duration.zero,
    EpisodeStatus status = EpisodeStatus.none,
  }) {
    _states[id] = EpisodeState(
      episodeId: id,
      positionMs: position.inMilliseconds,
      status: status,
      updatedAt: stateOf(id).updatedAt.add(const Duration(milliseconds: 1)),
    );
    notifyListeners();
  }

  @override
  Future<Duration> prepareForPlayback(int id) async {
    calls.add('prepare:$id');
    if (stateOf(id).status != EpisodeStatus.none) change(id);
    return Duration(milliseconds: stateOf(id).positionMs);
  }

  @override
  Future<void> recordPosition(
    int id,
    Duration position, {
    Duration? duration,
  }) async {
    calls.add('record:$id:${position.inMilliseconds}');
    reportedDurations.add(duration);
    if (stateOf(id).status == EpisodeStatus.none) {
      change(id, position: position);
    }
  }

  @override
  Future<void> markCompleted(int id) async {
    completed.add(id);
    calls.add('completed:$id');
    change(id, status: EpisodeStatus.played);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Sync implements SyncService {
  _Sync(this.calls);
  final List<String> calls;
  void Function(int)? onRefresh;

  @override
  Future<void> freshStateBeforePlay(int id) async {
    calls.add('refresh:$id');
    onRefresh?.call(id);
  }

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
