import 'package:easypodcast/core/models.dart';
import 'package:easypodcast/data/local_store.dart';
import 'package:easypodcast/data/sqflite_library.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_server.dart';

void main() {
  late TestClock clock;
  late FakeServer server;
  late Device device;
  late List<int> episodes;
  late List<int> finished;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    clock = TestClock();
    server = FakeServer(clock);
    server.addPodcast(1, 'Garden Talk');
    episodes = server.addEpisodes(1, 5);
    device = await Device.open(server);
    await device.loginAndStart('phone');
    finished = [];
    device.library.finishedEpisodes.listen(finished.add);
  });

  tearDown(() => device.close());

  SqfliteLibrary lib() => device.library;

  Future<void> tick() async {
    clock.advance(const Duration(seconds: 1));
    await settle();
  }

  group('rule 9 transitions', () {
    test(
      'completion marks played, resets the position and leaves the queue',
      () async {
        final id = episodes.first;
        await lib().enqueue(id);
        await lib().enqueue(episodes[1]);
        await lib().recordPosition(id, const Duration(minutes: 5));
        await tick();
        await lib().markCompleted(id);
        await settle();

        final state = lib().stateOf(id);
        expect(state.status, EpisodeStatus.played);
        expect(state.positionMs, 0);
        expect(state.updatedAt, clock.now);
        expect(lib().queue.map((e) => e.id), [episodes[1]]);
        expect(lib().queueState!.updatedAt, clock.now);
        expect(finished, [id]);
      },
    );

    test(
      'dismiss marks dismissed, resets the position and leaves the queue',
      () async {
        final id = episodes[2];
        await lib().recordPosition(id, const Duration(minutes: 3));
        await lib().enqueue(id);
        await tick();
        await lib().dismiss(id);
        await settle();

        final state = lib().stateOf(id);
        expect(state.status, EpisodeStatus.dismissed);
        expect(state.positionMs, 0);
        expect(state.updatedAt, clock.now);
        expect(lib().queue, isEmpty);
        expect(lib().inProgress, isEmpty);
        expect(lib().newEpisodes().map((e) => e.id), isNot(contains(id)));
        expect(finished, [id]);
      },
    );

    test('mark as played', () async {
      final id = episodes[3];
      await lib().enqueue(id);
      await tick();
      await lib().markPlayed(id);
      await settle();
      expect(lib().stateOf(id).status, EpisodeStatus.played);
      expect(lib().stateOf(id).positionMs, 0);
      expect(lib().queue, isEmpty);
      expect(finished, [id]);
    });

    test('return to new', () async {
      final id = episodes[3];
      await lib().markPlayed(id);
      await tick();
      await lib().markNew(id);
      final state = lib().stateOf(id);
      expect(state.status, EpisodeStatus.none);
      expect(state.positionMs, 0);
      expect(state.updatedAt, clock.now);
      expect(lib().newEpisodes().map((e) => e.id), contains(id));
    });

    test(
      'starting a played or dismissed episode resets it to new from 0',
      () async {
        final played = episodes[0];
        final dismissed = episodes[1];
        await lib().markPlayed(played);
        await lib().dismiss(dismissed);
        await tick();

        expect(await lib().prepareForPlayback(played), Duration.zero);
        expect(await lib().prepareForPlayback(dismissed), Duration.zero);
        for (final id in [played, dismissed]) {
          expect(lib().stateOf(id).status, EpisodeStatus.none);
          expect(lib().stateOf(id).positionMs, 0);
          expect(lib().stateOf(id).updatedAt, clock.now);
        }
      },
    );

    test('starting an in-progress episode keeps its state', () async {
      final id = episodes[0];
      await lib().recordPosition(id, const Duration(minutes: 7));
      final before = lib().stateOf(id);
      await tick();
      expect(await lib().prepareForPlayback(id), const Duration(minutes: 7));
      expect(lib().stateOf(id).updatedAt, before.updatedAt);
    });

    test(
      'dismissOlder dismisses new and in-progress episodes before the date',
      () async {
        // Published 2026-01-01 .. 2026-01-05; episodes[0] is the oldest.
        await lib().markPlayed(episodes[0]);
        await lib().recordPosition(episodes[1], const Duration(minutes: 2));
        await lib().enqueue(episodes[2]);
        await tick();
        finished.clear();
        await lib().dismissOlder(1, DateTime.utc(2026, 1, 4));
        await settle();

        expect(lib().stateOf(episodes[0]).status, EpisodeStatus.played);
        expect(lib().stateOf(episodes[1]).status, EpisodeStatus.dismissed);
        expect(lib().stateOf(episodes[2]).status, EpisodeStatus.dismissed);
        expect(lib().stateOf(episodes[3]).status, EpisodeStatus.none);
        expect(lib().stateOf(episodes[4]).status, EpisodeStatus.none);
        expect(lib().queue, isEmpty);
        expect(finished, unorderedEquals([episodes[1], episodes[2]]));
      },
    );
  });

  test('the in-progress threshold is 60 s', () async {
    final id = episodes[0];
    await lib().recordPosition(id, const Duration(milliseconds: 59999));
    expect(lib().inProgress, isEmpty);
    expect(lib().newEpisodes().map((e) => e.id), contains(id));

    await tick();
    await lib().recordPosition(id, const Duration(milliseconds: 60000));
    expect(lib().inProgress.map((e) => e.id), [id]);
    expect(lib().newEpisodes().map((e) => e.id), isNot(contains(id)));
  });

  test('in progress is sorted by the last change, newest first', () async {
    await lib().recordPosition(episodes[0], const Duration(minutes: 2));
    await tick();
    await lib().recordPosition(episodes[1], const Duration(minutes: 2));
    await tick();
    await lib().recordPosition(episodes[2], const Duration(minutes: 2));
    await tick();
    await lib().recordPosition(episodes[0], const Duration(minutes: 3));
    expect(lib().inProgress.map((e) => e.id), [
      episodes[0],
      episodes[2],
      episodes[1],
    ]);
  });

  test('new episodes are newest first and respect the limit', () async {
    expect(lib().newEpisodes().map((e) => e.id), episodes.reversed);
    expect(lib().newEpisodes(limit: 2).map((e) => e.id), [
      episodes[4],
      episodes[3],
    ]);
    await lib().markPlayed(episodes[4]);
    expect(lib().newEpisodes(limit: 1).map((e) => e.id), [episodes[3]]);
  });

  test('episodesOf keeps the server order, newest first', () {
    expect(lib().episodesOf(1).map((e) => e.id), episodes.reversed);
    expect(lib().episode(episodes[0])!.title, 'Episode ${episodes[0]}');
  });

  group('queue', () {
    test('every change replaces the whole queue with a newer time', () async {
      final times = <DateTime>[];
      Future<void> step(Future<void> Function() change) async {
        await tick();
        await change();
        times.add(lib().queueState!.updatedAt);
        expect(lib().queueState!.updatedAt, clock.now);
      }

      await step(() => lib().enqueue(episodes[0]));
      await step(() => lib().enqueue(episodes[1]));
      await step(() => lib().enqueue(episodes[2], next: true));
      expect(lib().queue.map((e) => e.id), [
        episodes[2],
        episodes[0],
        episodes[1],
      ]);
      await step(() => lib().moveInQueue(episodes[2], 5));
      expect(lib().queue.map((e) => e.id), [
        episodes[0],
        episodes[1],
        episodes[2],
      ]);
      await step(() => lib().moveInQueue(episodes[1], 0));
      expect(lib().queue.map((e) => e.id), [
        episodes[1],
        episodes[0],
        episodes[2],
      ]);
      await step(() => lib().dequeue(episodes[0]));
      expect(lib().queue.map((e) => e.id), [episodes[1], episodes[2]]);
      expect(times.toSet(), hasLength(times.length));
    });

    test(
      'enqueue of a queued episode changes nothing, next moves it up',
      () async {
        await lib().enqueue(episodes[0]);
        await lib().enqueue(episodes[1]);
        final before = lib().queueState!.updatedAt;
        await tick();
        await lib().enqueue(episodes[1]);
        expect(lib().queueState!.updatedAt, before);
        await lib().enqueue(episodes[1], next: true);
        expect(lib().queue.map((e) => e.id), [episodes[1], episodes[0]]);
      },
    );

    test('play next goes after the playing episode', () async {
      await lib().enqueue(episodes[0]);
      await lib().enqueue(episodes[1]);
      device.sync.setPlayingEpisode(episodes[0]);
      await lib().enqueue(episodes[2], next: true);
      expect(lib().queue.map((e) => e.id), [
        episodes[0],
        episodes[2],
        episodes[1],
      ]);
    });
  });

  group('remote records', () {
    EpisodeState remote(
      int id,
      int position,
      DateTime at, [
      EpisodeStatus s = EpisodeStatus.none,
    ]) => EpisodeState(
      episodeId: id,
      positionMs: position,
      status: s,
      updatedAt: at,
    );

    test('newer wins, equal or older is ignored', () async {
      final id = episodes[0];
      await lib().recordPosition(id, const Duration(minutes: 10));
      final local = lib().stateOf(id);

      await lib().applyRemote([remote(id, 1, local.updatedAt)], null);
      expect(lib().stateOf(id).positionMs, 600000);
      await lib().applyRemote([
        remote(
          id,
          2,
          local.updatedAt.subtract(const Duration(milliseconds: 1)),
        ),
      ], null);
      expect(lib().stateOf(id).positionMs, 600000);
      await lib().applyRemote([
        remote(
          id,
          120000,
          local.updatedAt.add(const Duration(milliseconds: 1)),
        ),
      ], null);
      expect(lib().stateOf(id).positionMs, 120000);
    });

    test('the playing episode is never changed from outside', () async {
      final id = episodes[0];
      await lib().recordPosition(id, const Duration(minutes: 10));
      device.sync.setPlayingEpisode(id);
      await lib().applyRemote([
        remote(
          id,
          5000,
          clock.now.add(const Duration(minutes: 1)),
          EpisodeStatus.played,
        ),
      ], null);
      expect(lib().stateOf(id).positionMs, 600000);
      expect(lib().stateOf(id).status, EpisodeStatus.none);
      expect(finished, isEmpty);

      device.sync.setPlayingEpisode(null);
      await lib().applyRemote([
        remote(
          id,
          0,
          clock.now.add(const Duration(minutes: 1)),
          EpisodeStatus.played,
        ),
      ], null);
      expect(lib().stateOf(id).status, EpisodeStatus.played);
      expect(finished, [id]);
    });

    test(
      'finishedEpisodes reports remote played and dismissed, not other changes',
      () async {
        final later = clock.now.add(const Duration(minutes: 1));
        await lib().applyRemote([
          remote(episodes[0], 0, later, EpisodeStatus.played),
          remote(episodes[1], 0, later, EpisodeStatus.dismissed),
          remote(episodes[2], 90000, later),
        ], null);
        await settle();
        expect(finished, [episodes[0], episodes[1]]);

        // Same status again from a newer record is not a new event.
        await lib().applyRemote([
          remote(
            episodes[0],
            0,
            later.add(const Duration(seconds: 1)),
            EpisodeStatus.played,
          ),
        ], null);
        await settle();
        expect(finished, [episodes[0], episodes[1]]);
      },
    );

    test(
      'a newer remote queue replaces the local one, an older one does not',
      () async {
        await lib().enqueue(episodes[0]);
        final local = lib().queueState!;
        await lib().applyRemote(
          const [],
          QueueState(episodeIds: [episodes[1]], updatedAt: local.updatedAt),
        );
        expect(lib().queue.map((e) => e.id), [episodes[0]]);
        await lib().applyRemote(
          const [],
          QueueState(
            episodeIds: [episodes[1]],
            updatedAt: local.updatedAt.add(const Duration(milliseconds: 1)),
          ),
        );
        expect(lib().queue.map((e) => e.id), [episodes[1]]);
      },
    );
  });

  test(
    'podcasts are sorted by played count, then title; unsubscribed are hidden',
    () async {
      server.addPodcast(2, 'apple stories');
      final second = server.addEpisodes(2, 2);
      server.addPodcast(3, 'Birds at Dawn');
      final third = server.addEpisodes(3, 3);
      server.addPodcast(4, 'Zebra Facts', subscribed: false);
      await device.sync.syncNow();

      expect(lib().podcasts.map((p) => p.title), [
        'apple stories',
        'Birds at Dawn',
        'Garden Talk',
      ]);
      await lib().markPlayed(third[0]);
      await lib().markPlayed(third[1]);
      await lib().markPlayed(second[0]);
      expect(lib().podcasts.map((p) => p.title), [
        'Birds at Dawn',
        'apple stories',
        'Garden Talk',
      ]);
      expect(lib().podcasts.first.playedCount, 2);
      expect(lib().podcast(3)!.playedCount, 2);
    },
  );

  test('everything survives a restart, including pending flags', () async {
    device.api.online = false;
    await lib().recordPosition(episodes[0], const Duration(minutes: 4));
    await lib().enqueue(episodes[1]);
    await device.sync.whenIdle();
    expect(lib().pendingCount, 2);

    final store = LocalStore(device.db);
    final reopened = await SqfliteLibrary.open(store, device.api);
    expect(reopened.podcasts.map((p) => p.title), ['Garden Talk']);
    expect(reopened.episodesOf(1).map((e) => e.id), episodes.reversed);
    expect(reopened.stateOf(episodes[0]).positionMs, 240000);
    expect(
      reopened.stateOf(episodes[0]).updatedAt,
      lib().stateOf(episodes[0]).updatedAt,
    );
    expect(reopened.queue.map((e) => e.id), [episodes[1]]);
    expect(reopened.pendingCount, 2);
    expect(
      reopened.storedEpisodesVersion(1),
      server.listPodcasts().first.episodesVersion,
    );
    expect(store.meta(MetaKey.token), 'token-phone');
    reopened.dispose();
  });

  test('descriptions are fetched once and cached', () async {
    final id = episodes[0];
    expect(await lib().description(id), 'About episode $id');
    device.api.online = false;
    expect(await lib().description(id), 'About episode $id');
  });

  test('subscribe and unsubscribe go to the server', () async {
    server.addPodcast(7, 'Night Trains', subscribed: false);
    final added = server.addEpisodes(7, 2);
    final podcast = await lib().subscribe('https://feeds.example.test/7.xml');
    expect(podcast.id, 7);
    expect(lib().podcasts.map((p) => p.id), contains(7));
    expect(lib().episodesOf(7).map((e) => e.id), added.reversed);

    await lib().unsubscribe(7);
    expect(lib().podcasts.map((p) => p.id), isNot(contains(7)));
    expect(lib().podcast(7)!.subscribed, isFalse);
  });
}
