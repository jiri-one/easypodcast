import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:audio_service/audio_service.dart';
import 'package:audio_service_mpris/audio_service_mpris.dart';
// ignore: depend_on_referenced_packages
import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:easypodcast/core/api.dart';
import 'package:easypodcast/core/downloads.dart';
import 'package:easypodcast/core/library.dart';
import 'package:easypodcast/core/models.dart';
import 'package:easypodcast/core/player.dart';
import 'package:easypodcast/core/settings.dart';
import 'package:easypodcast/core/sync.dart';
import 'package:easypodcast/platform/android_platform.dart';
import 'package:easypodcast/player/player.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../data/fake_server.dart';

const _first = Episode(
  id: 1,
  podcastId: 1,
  title: 'Morning Field Notes',
  enclosureUrl: 'http://example.test/one.mp3',
  durationS: 60,
);
const _second = Episode(
  id: 2,
  podcastId: 1,
  title: 'Evening Field Notes',
  enclosureUrl: 'https://example.test/two.mp3',
  durationS: 120,
);
const _third = Episode(
  id: 3,
  podcastId: 1,
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
  late List<String> platformCalls;
  late EpisodeAudioHandler handler;
  late _Downloads downloads;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = await Settings.load();
  });

  void openPlayer({bool android = true, String languageCode = 'en'}) {
    calls = [];
    platformCalls = [];
    library = _Library(calls);
    sync = _Sync(calls);
    engine = _Engine(calls);
    downloads = _Downloads();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(androidPlatform, (call) async {
      platformCalls.add(call.method);
      return null;
    });
    player = EpisodePlayer(
      library: library,
      sync: sync,
      downloads: downloads,
      settings: settings,
      engine: engine,
      clock: TestWidgetsFlutterBinding.instance.clock.now,
    );
    handler = EpisodeAudioHandler(
      player,
      library,
      downloads,
      settings,
      android: android,
      languageCode: () => languageCode,
    );
    addTearDown(() {
      player.dispose();
      library.dispose();
      downloads.dispose();
      settings.dispose();
      messenger.setMockMethodCallHandler(androidPlatform, null);
    });
  }

  testWidgets('a 10-second pause resumes the loaded source', (tester) async {
    openPlayer();
    await player.play(_first.id);

    expect(calls, ['refresh:1', 'load', 'play', 'playing:1']);
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

  for (final (description, slow) in [
    ('a quick resume check never publishes the label', false),
    ('a slow resume check publishes the label after one second', true),
  ]) {
    testWidgets(description, (tester) async {
      openPlayer();
      await player.play(_second.id);
      await player.pause();
      await tester.pump(const Duration(seconds: 31));
      final check = Completer<void>();
      sync.onRefresh = (_) => check.future;
      final published = <int?>[];
      player.addListener(() => published.add(player.checkingPosition));

      final resuming = player.resume();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 999));
      expect(published, isEmpty);
      if (slow) {
        await tester.pump(const Duration(milliseconds: 1));
        expect(published, [_second.id]);
      }

      check.complete();
      await resuming;
      await tester.pump(const Duration(milliseconds: 1));
      expect(player.isPlaying, isTrue);
      expect(published.whereType<int>(), slow ? [_second.id] : isEmpty);
      expect(published.last, isNull);
    });
  }

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

    expect(calls, ['refresh:1', 'seek:0', 'play', 'playing:1', 'prepare:1']);
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
      'seek:0',
      'play',
      'playing:2',
      'prepare:2',
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
      engine.interruptionEvents.add(PlaybackInterruption.permanentLoss);
      await tester.pump();
      expect(player.isPlaying, isFalse);
      expect(calls, containsAllInOrder(['record:1:60000', 'playing:null']));

      await player.seekBy(const Duration(seconds: -15));
      expect(player.isPlaying, isFalse);
      expect(calls.last, 'record:1:45000');

      await player.stop();
      expect(calls.where((call) => call == 'record:1:45000'), hasLength(1));
      expect(player.current, isNull);
    },
  );

  testWidgets('reports a pause initiated by the playback engine', (
    tester,
  ) async {
    openPlayer();
    await player.play(_first.id);

    engine.position = const Duration(seconds: 42);
    calls.clear();
    engine.playing = false;
    engine.events.add(null);
    await tester.pump();

    expect(calls, ['record:1:42000', 'send:5000', 'playing:null']);
    expect(player.isPlaying, isFalse);
  });

  testWidgets('reports the outro until the stream completes', (tester) async {
    openPlayer();
    await player.play(_first.id);

    engine.position = const Duration(seconds: 575);
    await tester.pump(const Duration(seconds: 30));
    expect(calls.last, 'record:1:575000');
    engine.position = const Duration(seconds: 580);
    await player.reportBeforeBackground();
    expect(calls.last, 'record:1:580000');
    await player.pause();
    expect(library.stateOf(1).positionMs, 580000);
    await player.seekTo(const Duration(seconds: 600));
    expect(calls.last, 'record:1:599999');
    expect(library.completed, isEmpty);
    expect(player.current?.id, 1);
    await player.resume();
    engine.complete();
    await player.reportBeforeBackground();

    expect(library.completed, [1]);
    expect(library.queue.map((episode) => episode.id), [2]);
    expect(
      calls,
      containsAllInOrder([
        'playing:null',
        'completed:1',
        'refresh:2',
        'playing:2',
      ]),
    );
    expect(player.current?.id, 2);
    expect(engine.uri, Uri.parse(_second.enclosureUrl));
  });

  testWidgets(
    'premature EOF keeps the last position and retries the same episode',
    (tester) async {
      openPlayer();
      await player.play(1);
      const lastPosition = Duration(minutes: 4);
      engine.position = lastPosition;
      engine.complete(at: lastPosition);
      await player.reportBeforeBackground();

      expect(library.completed, isEmpty);
      expect(library.stateOf(1).positionMs, lastPosition.inMilliseconds);
      expect(library.reportedDurations.last, const Duration(minutes: 10));
      expect(player.position.value, lastPosition);
      expect(handler.playbackState.value.updatePosition, lastPosition);
      expect(
        player.lastPlaybackError?.reason,
        PlaybackErrorReason.streamFailed,
      );
      expect(player.current?.id, 1);
      expect(calls, isNot(contains('refresh:2')));

      engine.duration = const Duration(minutes: 10);
      await handler.play();
      expect(engine.position, lastPosition);
      expect(player.isPlaying, isTrue);
    },
  );

  for (final status in [EpisodeStatus.played, EpisodeStatus.dismissed]) {
    testWidgets('autoplay skips a remotely ${status.name} queue item', (
      tester,
    ) async {
      openPlayer();
      library.queued.add(_third);
      await player.play(_first.id);
      sync.onRefresh = (id) {
        if (id == _second.id) library.change(id, status: status);
      };
      calls.clear();
      engine.complete();
      await tester.pump();

      expect(calls, [
        'playing:null',
        'completed:1',
        'refresh:2',
        'refresh:3',
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
    engine.complete();
    await player.reportBeforeBackground();

    expect(calls, ['playing:null', 'completed:1', 'refresh:2']);
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
    engine.duration = null;
    await player.play(_third.id);
    expect(player.duration, isNull);

    await player.seekTo(const Duration(seconds: 60));
    expect(library.completed, isEmpty);

    engine.complete();
    await tester.pump();

    expect(library.completed, [3]);
    expect(calls, isNot(contains('refresh:2')));
    expect(player.isPlaying, isFalse);
    expect(player.current, isNull);
  });

  testWidgets('timed sleep saves the outro as a pause', (tester) async {
    openPlayer();
    await player.play(_first.id);
    await player.setSpeed(1.4);
    expect(settings.speed, 1.4);
    const duration = Duration(seconds: 2);
    final deadline = tester.binding.clock.now().add(duration);
    await player.setSleepTimer(duration);
    expect(player.sleepRemaining, isNotNull);
    expect(player.sleepDuration, duration);
    expect(player.sleepDeadline, deadline);
    engine.position = const Duration(seconds: 590);
    await tester.pump(const Duration(seconds: 2));

    expect(library.completed, isEmpty);
    expect(library.stateOf(1).positionMs, 590000);
    expect(calls, isNot(contains('refresh:2')));
    expect(player.sleepRemaining, isNull);
    expect(player.sleepDuration, isNull);
    expect(player.sleepDeadline, isNull);
    expect(player.isPlaying, isFalse);
  });

  testWidgets('sleep at the end stops before opening the next item', (_) async {
    openPlayer();
    await player.play(1);
    await player.setSleepTimer(const Duration(minutes: 5));
    await player.setSleepAtEndOfEpisode(true);
    expect(player.sleepRemaining, isNull);
    expect(player.sleepAtEndOfEpisode, isTrue);
    calls.clear();
    engine.complete();
    await player.reportBeforeBackground();

    expect(library.completed, [1]);
    expect(calls, ['playing:null', 'completed:1']);
    expect(handler.playbackState.value.playing, isFalse);
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.idle,
    );
    expect(player.sleepAtEndOfEpisode, isFalse);
  });

  testWidgets('the media session stays active while loading the next item', (
    tester,
  ) async {
    openPlayer();
    await handler.playFromMediaId('episode:1');
    final states = <PlaybackState>[];
    final items = <String?>[];
    final stateSubscription = handler.playbackState.listen(states.add);
    final itemSubscription = handler.mediaItem.listen(
      (item) => items.add(item?.id),
    );
    final load = Completer<void>();
    engine.onLoad = () => load.future;
    engine.complete();
    await tester.pump();
    expect(handler.mediaItem.value?.id, 'episode:2');
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.loading,
    );
    expect(handler.playbackState.value.playing, isTrue);
    load.complete();
    await player.reportBeforeBackground();
    expect(items.toSet(), {'episode:1', 'episode:2'});
    expect(
      states.every(
        (state) =>
            state.playing && state.processingState != AudioProcessingState.idle,
      ),
      isTrue,
    );
    unawaited(stateSubscription.cancel());
    unawaited(itemSubscription.cancel());
  });

  testWidgets('a stream failure does not overwrite a frozen position', (
    tester,
  ) async {
    openPlayer();
    await player.play(1);
    engine.position = const Duration(seconds: 95);
    await player.reportBeforeBackground();
    final lastState = library.stateOf(1);
    engine.processingState = ProcessingState.idle;
    engine.events.add(null);
    await player.reportBeforeBackground();
    await tester.pump(const Duration(minutes: 3));
    expect(library.stateOf(1), same(lastState));
    expect(player.isPlaying, isFalse);
    expect(player.isBuffering, isFalse);
    expect(player.lastPlaybackError?.episode, _first);
    expect(player.lastPlaybackError?.reason, PlaybackErrorReason.streamFailed);
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.error,
    );
    expect(handler.playbackState.value.errorMessage, isNotEmpty);

    await handler.play();
    expect(player.isPlaying, isTrue);
    expect(player.lastPlaybackError, isNull);
    expect(engine.position, const Duration(seconds: 95));
    expect(calls.where((call) => call == 'load'), hasLength(2));
  });

  testWidgets(
    'retry after a stream failure during a seek reports the requested position',
    (tester) async {
      openPlayer();
      const target = Duration(minutes: 2);
      library.change(2, position: const Duration(seconds: 64));
      await player.play(2);
      final checkpoint = library.stateOf(2);
      engine.onSeek = (_) {
        engine.processingState = ProcessingState.idle;
        engine.events.add(null);
        throw OfflineException();
      };

      await player.seekTo(target);
      await player.reportBeforeBackground();
      expect(
        player.lastPlaybackError?.reason,
        PlaybackErrorReason.streamFailed,
      );
      expect(player.position.value, target);
      expect(library.stateOf(2), same(checkpoint));

      engine.onSeek = null;
      final starting = Completer<void>();
      engine.onPlay = () => starting.future;
      final retry = player.resume();
      await tester.pump();
      expect(engine.position, target);
      expect(library.stateOf(2), same(checkpoint));
      starting.complete();
      await retry;
      expect(player.isPlaying, isTrue);
      expect(player.lastPlaybackError, isNull);
      expect(library.stateOf(2).resumePosition, target);
    },
  );

  testWidgets(
    'hung seek releases pause and later commands without saving its target',
    (tester) async {
      openPlayer();
      await player.play(1);
      final hung = Completer<void>();
      engine.onSeek = (_) => hung.future;
      final seek = player.seekTo(const Duration(minutes: 2));
      final pause = player.pause();
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      await seek;
      await pause;
      expect(library.stateOf(1).positionMs, 10000);
      expect(library.completed, isEmpty);
      expect(player.lastPlaybackError?.reason, PlaybackErrorReason.seekFailed);
      expect(player.isPlaying, isFalse);
      await player.stop();
      expect(player.current, isNull);
      hung.complete();
    },
  );

  testWidgets('a failed automatic load keeps its item and Play retries it', (
    _,
  ) async {
    openPlayer();
    library.queued.add(_third);
    await player.play(1);
    engine.onLoad = () => throw OfflineException();
    engine.complete();
    await player.reportBeforeBackground();
    expect(player.current, _second);
    expect(library.queue, [_second, _third]);
    expect(player.lastPlaybackError?.reason, PlaybackErrorReason.loadFailed);
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.error,
    );
    expect(calls, isNot(contains('refresh:3')));

    engine.onLoad = null;
    await handler.play();
    expect(player.current, _second);
    expect(player.isPlaying, isTrue);
    expect(player.lastPlaybackError, isNull);
  });

  testWidgets(
    'failed Android loads and denied focus publish a retryable error',
    (_) async {
      openPlayer();
      engine.onLoad = () => throw OfflineException();
      await handler.playFromMediaId('episode:1');
      expect(engine.foregroundStarts, 1);
      expect(platformCalls, ['stopForeground']);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.error,
      );
      expect(player.lastPlaybackError?.reason, PlaybackErrorReason.loadFailed);

      engine.onLoad = null;
      engine.focusAvailable = false;
      await handler.play();
      expect(engine.foregroundStarts, 2);
      expect(platformCalls, ['stopForeground', 'stopForeground']);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.error,
      );
      expect(
        player.lastPlaybackError?.reason,
        PlaybackErrorReason.audioFocusUnavailable,
      );
      expect(handler.playbackState.value.playing, isFalse);

      engine.focusAvailable = true;
      await handler.play();
      expect(engine.foregroundStarts, 3);
      expect(player.isPlaying, isTrue);
    },
  );

  testWidgets(
    'Android pause sends the saved position without holding up Play',
    (tester) async {
      openPlayer();
      await player.play(1);
      engine.position = const Duration(seconds: 42);
      final sent = sync.sending = Completer<void>();
      final pausing = handler.pause();
      await tester.pump();
      expect(library.stateOf(1).positionMs, 42000);
      expect(handler.playbackState.value.playing, isFalse);
      final resuming = handler.play();
      await tester.pump();
      expect(player.isPlaying, isTrue);
      expect(
        calls,
        containsAllInOrder(['record:1:42000', 'send:5000', 'play']),
      );
      expect(sync.fullSyncs, 0);
      sent.complete();
      await pausing;
      await resuming;
    },
  );

  testWidgets(
    'cold Android Auto Play waits for a fresh library and updates browse lists',
    (tester) async {
      openPlayer();
      final inProgress = <Map<String, dynamic>>[];
      final changes = handler
          .subscribeToChildren('in-progress')
          .listen(inProgress.add);
      addTearDown(changes.cancel);
      final refreshing = Completer<void>();
      sync.onSync = () async {
        await refreshing.future;
        library.change(1, status: EpisodeStatus.played);
        library.change(2, position: const Duration(minutes: 2));
      };
      final playing = handler.play();
      await tester.pump();
      final pausing = handler.pause();
      expect(sync.fullSyncs, 1);
      expect(calls, isEmpty);
      expect(player.current, isNull);
      refreshing.complete();
      await playing;
      await pausing;
      await tester.pump();
      expect(player.current, _second);
      expect(player.isPlaying, isFalse);
      expect(calls.first, 'refresh:2');
      expect(inProgress, isNotEmpty);
      final entries = await handler.getChildren('in-progress');
      expect(entries.map((item) => item.id), ['episode:2']);

      final downloaded = <Map<String, dynamic>>[];
      final updates = handler
          .subscribeToChildren('downloaded')
          .listen(downloaded.add);
      addTearDown(updates.cancel);
      await tester.pump();
      final before = downloaded.length;
      downloads.changed();
      await tester.pump();
      expect(downloaded, hasLength(before));
      downloads.downloadedEpisodeIds = [1];
      downloads.changed();
      await tester.pump();
      expect(downloaded, hasLength(before + 1));
    },
  );

  testWidgets(
    'cold Recent and empty search share the newest sub-minute candidate',
    (_) async {
      openPlayer();
      library.change(2, position: const Duration(minutes: 2));
      library.change(3, position: const Duration(seconds: 12));
      final recent = await handler.getChildren(AudioService.recentRootId);
      expect(recent.single.id, 'episode:3');
      await handler.prepare();
      await handler.prepareFromMediaId(recent.single.id);
      expect(calls, isEmpty);
      expect(player.current, isNull);
      sync.onRefresh = (id) =>
          library.change(id, position: const Duration(seconds: 42));
      await handler.playFromSearch(' ');
      expect(player.current, _third);
      expect(engine.position, const Duration(seconds: 42));
      expect(calls.first, 'refresh:3');
    },
  );

  testWidgets('a cold headset play falls back to the eligible queue head', (
    _,
  ) async {
    openPlayer();
    sync.onRefresh = (id) {
      if (id == 1) library.change(1, status: EpisodeStatus.played);
    };
    await handler.click();
    expect(player.current, _second);
    expect(calls.take(2), ['refresh:1', 'refresh:2']);
  });

  testWidgets(
    'voice play by podcast title prefers unfinished over newer new episodes',
    (_) async {
      openPlayer();
      library.change(2, position: const Duration(seconds: 15));
      await handler.playFromSearch(' NOTES  FÍELD ');
      expect(player.current, _second);
      expect(calls.first, 'refresh:2');
      await handler.stop();
      library.change(1, status: EpisodeStatus.dismissed);
      library.change(2, status: EpisodeStatus.played);
      await handler.playFromSearch('Field Notes');
      expect(player.current, _third);
    },
  );

  testWidgets(
    'focus gain resumes a transient pause through the pre-play check',
    (tester) async {
      openPlayer();
      await player.play(1);
      engine.position = const Duration(seconds: 25);
      engine.interruptionEvents.add(PlaybackInterruption.transientLoss);
      await tester.pump(const Duration(seconds: 1));
      expect(player.isPlaying, isFalse);
      expect(engine.focusReleases, 0);
      expect(library.stateOf(1).positionMs, 25000);
      await tester.pump(const Duration(seconds: 31));
      sync.onRefresh = (id) =>
          library.change(id, position: const Duration(seconds: 35));
      calls.clear();
      engine.interruptionEvents.add(PlaybackInterruption.regained);
      await tester.pump();
      expect(calls, ['refresh:1', 'seek:35000', 'play', 'playing:1']);
      expect(engine.foregroundStarts, 1);
      expect(player.isPlaying, isTrue);
    },
  );

  testWidgets(
    'focus gain right after a saved position resumes without seeking back',
    (tester) async {
      openPlayer();
      await player.play(1);
      engine.position = const Duration(seconds: 25);
      engine.interruptionEvents.add(PlaybackInterruption.transientLoss);
      await tester.pump(const Duration(seconds: 1));
      engine.interruptionEvents.add(PlaybackInterruption.regained);
      await tester.pump();
      expect(player.isPlaying, isTrue);
      engine.position = const Duration(seconds: 25, milliseconds: 700);
      engine.interruptionEvents.add(PlaybackInterruption.transientLoss);
      await tester.pump(const Duration(seconds: 1));
      expect(library.stateOf(1).positionMs, 25000);
      calls.clear();
      engine.interruptionEvents.add(PlaybackInterruption.regained);
      await tester.pump();
      expect(calls.where((call) => call.startsWith('seek')), isEmpty);
      expect(engine.position, const Duration(seconds: 25, milliseconds: 700));
      expect(player.isPlaying, isTrue);
    },
  );

  for (final cancelBy in ['pause', 'sleep', 'output disconnect']) {
    testWidgets('focus return cannot undo $cancelBy', (tester) async {
      openPlayer();
      await player.play(1);
      await player.setSleepTimer(const Duration(seconds: 2));
      engine.interruptionEvents.add(PlaybackInterruption.transientLoss);
      await tester.pump();
      switch (cancelBy) {
        case 'pause':
          await player.pause();
        case 'sleep':
          await tester.pump(const Duration(seconds: 2));
        case 'output disconnect':
          engine.interruptionEvents.add(PlaybackInterruption.permanentLoss);
          await tester.pump();
      }
      engine.interruptionEvents.add(PlaybackInterruption.regained);
      await tester.pump();
      expect(player.isPlaying, isFalse);
      expect(engine.focusReleases, 1);
      expect(handler.playbackState.value.playing, isFalse);
      await handler.play();
      expect(player.isPlaying, isTrue);
    });
  }

  test(
    'declined Android focus clears the request before Play can retry',
    () async {
      final activations = <bool>[];
      var requests = 0;
      Future<bool> setActive(bool active) async {
        activations.add(active);
        return active && ++requests == 2;
      }

      expect(await activatePlaybackFocus(setActive), isFalse);
      expect(await activatePlaybackFocus(setActive), isTrue);
      expect(activations, [true, false, true]);
    },
  );

  testWidgets(
    'Android localizes controls and keeps skips without absolute seek',
    (_) async {
      openPlayer(languageCode: 'cs');
      final root = await handler.getChildren(AudioService.browsableRootId);
      expect(root.map((item) => item.title), [
        'Rozposlouchané',
        'Fronta',
        'Stažené',
        'Podcasty',
      ]);
      await handler.play();
      final state = handler.playbackState.value;
      expect(state.controls.map((control) => control.label), [
        'Skok zpět',
        'Pauza',
        'Skok vpřed',
        'Zastavit',
      ]);
      expect(state.systemActions, isNot(contains(MediaAction.seek)));
      await handler.seek(const Duration(seconds: 98));
      expect(engine.position, const Duration(seconds: 10));
      await handler.skipToNext();
      expect(engine.position, const Duration(seconds: 40));
    },
  );

  testWidgets('Android Auto lists at most the newest 100 unfinished episodes', (
    _,
  ) async {
    openPlayer();
    library.podcastEpisodes = [
      for (var id = 105; id >= 1; id--)
        Episode(
          id: id,
          podcastId: 1,
          title: 'Field Notes $id',
          enclosureUrl: 'https://example.test/$id.mp3',
        ),
    ];
    library.change(105, status: EpisodeStatus.played);
    library.change(104, status: EpisodeStatus.dismissed);

    final items = await handler.getChildren('podcast:1');
    expect(items.map((item) => item.id), [
      for (var id = 103; id >= 4; id--) 'episode:$id',
    ]);
  });

  test('Android Auto requests lists for browsable and playable items', () {
    expect(androidAudioConfig.androidBrowsableRootExtras, {
      AndroidContentStyle.supportedKey: true,
      AndroidContentStyle.browsableHintKey:
          AndroidContentStyle.listItemHintValue,
      AndroidContentStyle.playableHintKey:
          AndroidContentStyle.listItemHintValue,
    });
  });

  testWidgets('Linux MPRIS publishes advancing position for relative seek', (
    tester,
  ) async {
    openPlayer(android: false);
    await handler.play();
    engine.position = const Duration(seconds: 90);
    await tester.pump(const Duration(seconds: 1));
    final state = handler.playbackState.value;
    expect(state.updatePosition, const Duration(seconds: 90));
    expect(state.systemActions, contains(MediaAction.seek));
    await handler.seek(state.updatePosition + const Duration(seconds: 30));
    expect(engine.position, const Duration(seconds: 120));
  });

  testWidgets('Linux exit saves the position before waiting for the send', (
    tester,
  ) async {
    openPlayer(android: false);
    await player.play(1);
    engine.position = const Duration(seconds: 45);
    final sent = sync.sending = Completer<void>();
    calls.clear();
    var closed = false;
    final closing = player.didRequestAppExit().then((response) {
      closed = true;
      return response;
    });
    await tester.pump();
    expect(calls, ['record:1:45000', 'playing:null', 'send:2000']);
    await tester.pump(const Duration(seconds: 1));
    expect(closed, isFalse);
    sent.complete();
    expect(await closing, AppExitResponse.exit);
    expect(sync.fullSyncs, 0);
  });

  testWidgets('Linux keeps MPRIS after stop and publishes the playback rate', (
    tester,
  ) async {
    openPlayer(android: false);
    final previousPlatform = AudioServicePlatform.instance;
    final platform = _MprisPlatform();
    AudioServicePlatform.instance = platform;
    addTearDown(() => AudioServicePlatform.instance = previousPlatform);
    await connectMpris(player);
    expect(Mpris().minimumRate, lessThanOrEqualTo(0.8));
    expect(Mpris().maximumRate, greaterThanOrEqualTo(2.0));

    await platform.callbacks.play(const PlayRequest());
    await player.setSpeed(1.7);
    await tester.pump();
    expect(platform.states.last.speed, 1.7);
    await platform.callbacks.stop(const StopRequest());
    await tester.pump();
    expect(platform.stops, 0);
    expect(
      platform.states.last.processingState,
      AudioProcessingStateMessage.ready,
    );
    await platform.callbacks.play(const PlayRequest());
    expect(player.isPlaying, isTrue);
  });

  group('player with two synced libraries', () {
    late TestClock clock;
    late FakeServer server;
    late List<int> ids;
    late Device local;
    late Device remote;
    late _Engine decoder;
    late EpisodePlayer activePlayer;

    setUpAll(sqfliteFfiInit);

    setUp(() async {
      clock = TestClock();
      server = FakeServer(clock)..addPodcast(1, 'Garden Talk');
      ids = server.addEpisodes(1, 3);
      local = await Device.open(
        server,
        initialBackoff: const Duration(seconds: 10),
        maxBackoff: const Duration(seconds: 10),
      );
      addTearDown(local.close);
      await local.loginAndStart('Palma');
      remote = await Device.open(server);
      addTearDown(remote.close);
      await remote.loginAndStart('HiBreak');
      decoder = _Engine([])..duration = const Duration(hours: 1);
      activePlayer = EpisodePlayer(
        library: local.library,
        sync: local.sync,
        downloads: _Downloads(),
        settings: settings,
        engine: decoder,
        clock: clock.call,
      );
      addTearDown(settings.dispose);
      addTearDown(activePlayer.dispose);
    });

    test(
      'closing sends the paused position without refreshing state',
      () async {
        final id = ids.first;
        await activePlayer.play(id);
        decoder.position = const Duration(minutes: 10);
        final stateCalls = local.api.stateCalls;
        final podcastsCalls = local.api.podcastsCalls;
        final closing = activePlayer.didRequestAppExit();
        expect(await closing, AppExitResponse.exit);
        expect(server.states[id]?.positionMs, 600000);
        expect(local.api.stateCalls, stateCalls);
        expect(local.api.podcastsCalls, podcastsCalls);
      },
    );

    test('closing bounds a stuck pause send and skips an empty send', () async {
      await activePlayer.play(ids.first);
      decoder.position = const Duration(minutes: 10);
      local.api.syncCalls.clear();
      final sent = Completer<void>();
      local.api.beforePush = () => sent.future;
      try {
        await activePlayer.pause();
        expect(
          await activePlayer.didRequestAppExit().timeout(
            const Duration(seconds: 3),
          ),
          AppExitResponse.exit,
        );
        expect(local.library.pendingCount, 1);
      } finally {
        sent.complete();
        await local.sync.whenIdle();
      }
      expect(await activePlayer.didRequestAppExit(), AppExitResponse.exit);
      expect(local.api.syncCalls, ['push']);
    });

    for (final action in ['background', 'stop', 'switch']) {
      test(
        '$action reconciles an offline pause with a newer remote position',
        () async {
          final id = ids.first;
          await activePlayer.play(id);
          local.api.online = false;
          clock.advance(const Duration(minutes: 10));
          decoder.position = const Duration(minutes: 10);
          await activePlayer.pause();
          await local.sync.whenIdle();
          final paused = local.library.stateOf(id);
          expect(paused.positionMs, 600000);
          expect(paused.updatedAt, clock.now);
          expect(local.library.pendingCount, 1);

          clock.advance(const Duration(minutes: 25));
          await remote.library.recordPosition(id, const Duration(minutes: 35));
          await remote.sync.whenIdle();
          final newer = remote.library.stateOf(id);

          clock.advance(const Duration(hours: 1));
          local.api.online = true;
          await switch (action) {
            'background' => activePlayer.reportBeforeBackground(),
            'stop' => activePlayer.stop(),
            _ => activePlayer.play(ids[1]),
          };
          await local.sync.whenIdle();
          expect(local.api.pushedStates.single, [paused]);
          expect(local.library.pendingCount, 0);
          expect(local.library.stateOf(id).toJson(), newer.toJson());
          expect(server.states[id]?.toJson(), newer.toJson());
        },
      );
    }

    for (final terminal in [false, true]) {
      test(
        'a held load uses the latest ${terminal ? 'terminal state' : 'position'}',
        () async {
          final id = ids.first;
          await local.library.recordPosition(id, const Duration(minutes: 10));
          await local.sync.whenIdle();
          final loading = Completer<void>();
          final release = Completer<void>();
          decoder.onLoad = () {
            loading.complete();
            return release.future;
          };
          final play = activePlayer.play(id);
          try {
            await loading.future;
            expect(decoder.position, const Duration(minutes: 10));
            clock.advance(const Duration(minutes: 1));
            if (terminal) {
              await remote.library.markPlayed(id);
            } else {
              await remote.library.recordPosition(
                id,
                const Duration(minutes: 35),
              );
            }
            await remote.sync.whenIdle();
            await local.sync.syncNow();
          } finally {
            release.complete();
            await play;
          }

          final expected = terminal
              ? Duration.zero
              : const Duration(minutes: 35);
          expect(decoder.position, expected);
          expect(activePlayer.isPlaying, isTrue);
          expect(local.library.stateOf(id).status, EpisodeStatus.none);
          clock.advance(const Duration(seconds: 1));
          await activePlayer.pause();
          await local.sync.whenIdle();
          expect(server.states[id]?.positionMs, expected.inMilliseconds);
        },
      );
    }

    test('autoplay skips a head that is finished during its load', () async {
      final [first, next, following] = ids;
      await local.library.enqueue(next);
      await local.library.enqueue(following);
      await local.sync.whenIdle();
      await activePlayer.play(first);
      final loading = Completer<void>();
      final release = Completer<void>();
      decoder.onLoad = () {
        decoder.onLoad = null;
        loading.complete();
        return release.future;
      };
      decoder.complete();
      final completion = activePlayer.reportBeforeBackground();
      try {
        await loading.future;
        expect(activePlayer.current?.id, next);
        clock.advance(const Duration(seconds: 1));
        await remote.library.dismiss(next);
        await remote.sync.whenIdle();
        await local.sync.syncNow();
      } finally {
        release.complete();
        await completion;
      }
      expect(activePlayer.current?.id, following);
      expect(activePlayer.isPlaying, isTrue);
      expect(server.states[next]?.isDismissed, isTrue);
      expect(decoder.calls.where((call) => call == 'play'), hasLength(2));
    });

    test(
      'completion is durable at observation time while the decoder stops',
      () async {
        settings.autoplayQueue = false;
        final id = ids.first;
        await activePlayer.play(id);
        final stopping = Completer<void>();
        final release = Completer<void>();
        decoder.onStop = () {
          stopping.complete();
          return release.future;
        };
        final observedAt = clock.now;
        decoder.complete();
        try {
          await stopping.future;
          final completed = (await local.store.load()).states.single;
          expect(completed.isPlayed, isTrue);
          expect(completed.updatedAt, observedAt);
          await local.sync.whenIdle();
          expect(server.states[id]?.toJson(), completed.toJson());

          clock.advance(const Duration(seconds: 3));
          await remote.sync.syncNow();
          await remote.library.prepareForPlayback(id);
          await remote.library.recordPosition(id, const Duration(minutes: 6));
          await remote.sync.whenIdle();
          await local.sync.syncNow();
          clock.advance(const Duration(seconds: 1));
        } finally {
          release.complete();
          await activePlayer.reportBeforeBackground();
        }
        await local.sync.whenIdle();
        expect(activePlayer.current, isNull);
        expect(server.states[id]?.status, EpisodeStatus.none);
        expect(server.states[id]?.positionMs, 360000);
      },
    );

    for (final status in [EpisodeStatus.played, EpisodeStatus.dismissed]) {
      test(
        'replaying a ${status.name} episode only resets it after the engine starts',
        () async {
          final id = ids.first;
          if (status == EpisodeStatus.played) {
            await local.library.markPlayed(id);
          } else {
            await local.library.dismiss(id);
          }
          await local.sync.whenIdle();
          final previous = local.library.stateOf(id);
          local.api.online = false;
          decoder.onLoad = () => throw OfflineException();
          await expectLater(
            activePlayer.play(id),
            throwsA(isA<OfflineException>()),
          );
          expect(decoder.position, Duration.zero);
          expect(local.library.stateOf(id), same(previous));
          expect(local.library.pendingCount, 0);
          expect(
            (await local.store.load()).states.single.toJson(),
            previous.toJson(),
          );

          decoder.onLoad = null;
          final starting = Completer<void>();
          final release = Completer<void>();
          decoder.onPlay = () {
            starting.complete();
            return release.future;
          };
          final play = activePlayer.play(id);
          try {
            await starting.future;
            expect(local.library.stateOf(id), same(previous));
            expect(local.library.pendingCount, 0);
          } finally {
            release.complete();
            await play;
          }
          expect(activePlayer.isPlaying, isTrue);
          expect(local.library.stateOf(id).isNew, isTrue);
          local.api.online = true;
          await local.sync.syncNow();
          expect(server.states[id]?.isNew, isTrue);
        },
      );
    }

    for (final remoteWins in [false, true]) {
      test(
        'a paused seek keeps its target and respects a ${remoteWins ? 'later' : 'prior'} remote edit',
        () async {
          final id = ids.first;
          await activePlayer.play(id);
          decoder.position = const Duration(minutes: 10);
          await activePlayer.pause();
          await local.sync.whenIdle();
          Future<void> editRemotely() async {
            clock.advance(const Duration(seconds: 1));
            await remote.library.recordPosition(
              id,
              const Duration(minutes: 35),
            );
            await remote.sync.whenIdle();
          }

          if (!remoteWins) await editRemotely();
          clock.advance(const Duration(seconds: 1));
          final issuedAt = clock.now;
          final seeking = Completer<void>();
          final release = Completer<void>();
          const target = Duration(minutes: 20);
          decoder.onSeek = (position) async {
            if (position != target) return;
            seeking.complete();
            await release.future;
            decoder.position = const Duration(minutes: 21);
          };
          final seek = activePlayer.seekTo(target);
          try {
            await seeking.future;
            if (remoteWins) await editRemotely();
            await local.sync.syncNow();
            expect(local.library.stateOf(id).positionMs, 2100000);
            clock.advance(const Duration(minutes: 1));
          } finally {
            release.complete();
            await seek;
          }
          await local.sync.whenIdle();
          expect(
            local.library.stateOf(id).positionMs,
            remoteWins ? 2100000 : 1200000,
          );
          expect(server.states[id]?.positionMs, remoteWins ? 2100000 : 1200000);
          if (!remoteWins) expect(server.states[id]?.updatedAt, issuedAt);
        },
      );
    }

    for (final detailAvailable in [true, false]) {
      test(
        'autoplay waits for the uncached head (detail available: $detailAvailable)',
        () async {
          await activePlayer.play(ids[0]);
          final missing = server.addEpisodes(1, 1).single;
          await remote.sync.syncNow();
          await remote.library.enqueue(missing);
          await remote.library.enqueue(ids[1]);
          await remote.sync.whenIdle();

          final catalog = Completer<void>();
          final releaseCatalog = Completer<void>();
          local.api.beforePodcasts = () {
            local.api.beforePodcasts = null;
            catalog.complete();
            return releaseCatalog.future;
          };
          final detail = Completer<int>();
          final releaseDetail = Completer<void>();
          local.api.beforeEpisode = (id) {
            detail.complete(id);
            return releaseDetail.future;
          };
          final pull = local.sync.syncNow();
          Future<void>? complete;
          try {
            await catalog.future;
            expect(local.library.episode(missing), isNull);
            expect(local.library.queue.single.id, ids[1]);
            decoder.complete();
            complete = activePlayer.reportBeforeBackground();
            expect(
              await detail.future.timeout(const Duration(seconds: 2)),
              missing,
            );
            expect(activePlayer.current?.id, ids[0]);
            if (detailAvailable) releaseDetail.complete();
            await complete.timeout(const Duration(seconds: 4));
            expect(activePlayer.current?.id, detailAvailable ? missing : null);
            expect(activePlayer.isPlaying, detailAvailable);
            expect(local.library.episode(missing), isNull);
          } finally {
            if (!releaseDetail.isCompleted) releaseDetail.complete();
            releaseCatalog.complete();
            await pull;
            await complete;
          }
        },
      );
    }
  });
}

class _Engine implements PlaybackEngine {
  _Engine(this.calls);
  final List<String> calls;
  FutureOr<void> Function()? onLoad;
  FutureOr<void> Function()? onPlay;
  FutureOr<void> Function(Duration)? onSeek;
  FutureOr<void> Function()? onStop;
  final events = StreamController<void>.broadcast(sync: true);
  final interruptionEvents = StreamController<PlaybackInterruption>.broadcast();
  int focusReleases = 0;
  int foregroundStarts = 0;
  bool focusAvailable = true;
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
  Stream<PlaybackInterruption> get interruptions => interruptionEvents.stream;

  @override
  Future<void> prepareToPlay() async => foregroundStarts++;

  @override
  Future<void> load(Uri uri, Duration position) async {
    calls.add('load');
    this.uri = uri;
    this.position = position;
    await onLoad?.call();
    processingState = ProcessingState.ready;
  }

  @override
  Future<void> pause() async => playing = false;

  @override
  Future<void> releaseFocus() async => focusReleases++;

  void complete({Duration? at}) {
    position = at ?? duration ?? position;
    playing = false;
    processingState = ProcessingState.completed;
    events.add(null);
  }

  @override
  Future<void> play({
    required void Function(Object, StackTrace) onError,
  }) async {
    calls.add('play');
    if (onPlay case final hook?) await hook();
    playing = focusAvailable;
  }

  @override
  Future<void> seek(Duration position) async {
    calls.add('seek:${position.inMilliseconds}');
    this.position = position;
    await onSeek?.call(position);
  }

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> stop() async {
    playing = false;
    processingState = ProcessingState.idle;
    await onStop?.call();
  }

  @override
  Future<void> dispose() async {
    await events.close();
    await interruptionEvents.close();
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
  List<Episode> podcastEpisodes = [_third, _second, _first];
  int _revision = 0;

  static const _podcast = Podcast(
    id: 1,
    title: 'Fíeld Notes — The Nature Podcast',
    feedUrl: 'https://example.test/feed',
  );

  @override
  List<Podcast> get podcasts => [_podcast];

  @override
  Podcast? podcast(int id) => id == 1 ? _podcast : null;

  @override
  List<Episode> episodesOf(int id) => id == 1 ? podcastEpisodes : [];

  @override
  List<Episode> get inProgress => [
    _first,
    _second,
    _third,
  ].where((e) => stateOf(e.id).isInProgress).toList();

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
      updatedAt: DateTime.utc(2026).add(Duration(milliseconds: _revision++)),
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
    final previous = stateOf(id);
    if (!previous.isFinished &&
        (position.inMilliseconds - previous.positionMs).abs() > 1000) {
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
  FutureOr<void> Function(int)? onRefresh;
  Future<void> Function()? onSync;
  Completer<void>? sending;
  int fullSyncs = 0;

  @override
  Future<void> sendPending({Duration? timeout}) async {
    calls.add('send:${timeout?.inMilliseconds}');
    await sending?.future;
  }

  @override
  Future<void> freshStateBeforePlay(int id) async {
    calls.add('refresh:$id');
    await onRefresh?.call(id);
  }

  @override
  void setPlayingEpisode(int? id) => calls.add('playing:$id');

  @override
  Future<void> syncNow() async {
    fullSyncs++;
    await onSync?.call();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MprisPlatform extends AudioServicePlatform {
  late AudioHandlerCallbacks callbacks;
  final states = <PlaybackStateMessage>[];
  int stops = 0;

  @override
  void setHandlerCallbacks(AudioHandlerCallbacks callbacks) =>
      this.callbacks = callbacks;

  @override
  Future<void> configure(ConfigureRequest request) async {}

  @override
  Future<void> setState(SetStateRequest request) async =>
      states.add(request.state);

  @override
  Future<void> setMediaItem(SetMediaItemRequest request) async {}

  @override
  Future<void> setQueue(SetQueueRequest request) async {}

  @override
  Future<void> stopService(StopServiceRequest request) async => stops++;
}

class _Downloads extends DownloadService {
  void changed() => notifyListeners();

  @override
  List<int> downloadedEpisodeIds = const [];

  @override
  String? localFileOf(int id) =>
      id == _first.id ? '/downloads/episode.mp3' : null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
