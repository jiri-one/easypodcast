import 'package:easypodcast/core/api.dart';
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
      'completion hides the episode and leaves the stored queue intact',
      () async {
        final id = episodes.first;
        await lib().enqueue(id);
        await lib().enqueue(episodes[1]);
        final queuedBefore = lib().queueState;
        await lib().recordPosition(id, const Duration(minutes: 5));
        await tick();
        await lib().markCompleted(id);
        await settle();

        final state = lib().stateOf(id);
        expect(state.status, EpisodeStatus.played);
        expect(state.positionMs, 0);
        expect(state.updatedAt, clock.now);
        expect(lib().queue.map((e) => e.id), [episodes[1]]);
        expect(lib().queueState, same(queuedBefore));
        expect(lib().queueState!.episodeIds, [id, episodes[1]]);
        expect(finished, [id]);
      },
    );

    test(
      'dismiss resets the position and hides the episode from the queue',
      () async {
        final id = episodes[2];
        await lib().recordPosition(id, const Duration(minutes: 3));
        await lib().enqueue(id);
        final queuedBefore = lib().queueState;
        await tick();
        await lib().dismiss(id);
        await settle();

        final state = lib().stateOf(id);
        expect(state.status, EpisodeStatus.dismissed);
        expect(state.positionMs, 0);
        expect(state.updatedAt, clock.now);
        expect(lib().queue, isEmpty);
        expect(lib().queueState, same(queuedBefore));
        expect(lib().inProgress, isEmpty);
        expect(
          lib().newEpisodes(since: oldestTime).map((e) => e.id),
          isNot(contains(id)),
        );
        expect(finished, [id]);
      },
    );

    test('mark as played', () async {
      final id = episodes[3];
      await lib().enqueue(id);
      final queuedBefore = lib().queueState;
      await tick();
      await lib().markPlayed(id);
      await settle();
      expect(lib().stateOf(id).status, EpisodeStatus.played);
      expect(lib().stateOf(id).positionMs, 0);
      expect(lib().queue, isEmpty);
      expect(lib().queueState, same(queuedBefore));
      expect(finished, [id]);
    });

    test('return to new', () async {
      final id = episodes[3];
      await lib().enqueue(id);
      final queuedBefore = lib().queueState;
      await lib().markPlayed(id);
      await tick();
      await lib().markNew(id);
      final state = lib().stateOf(id);
      expect(state.status, EpisodeStatus.none);
      expect(state.positionMs, 0);
      expect(state.updatedAt, clock.now);
      expect(
        lib().newEpisodes(since: oldestTime).map((e) => e.id),
        contains(id),
      );
      expect(lib().queue.map((e) => e.id), [id]);
      expect(lib().queueState, same(queuedBefore));
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

    test('bulk dismiss includes the chosen episode and older unqueued new episodes', () async {
      episodes.addAll(server.addEpisodes(1, 2));
      server.addPodcast(2, 'Birds at Dawn');
      final other = server.addEpisodes(2, 1).single;
      await device.sync.syncNow();

      await lib().markPlayed(episodes[0]);
      final played = lib().stateOf(episodes[0]);
      await lib().recordPosition(episodes[1], const Duration(minutes: 2));
      await lib().enqueue(episodes[2]);
      final queuedBefore = lib().queueState;
      await lib().dismiss(episodes[3]);
      final dismissed = lib().stateOf(episodes[3]);
      await lib().recordPosition(episodes[4], const Duration(seconds: 59));
      await tick();
      finished.clear();
      await lib().dismissOlder(episodes[5]);
      await settle();

      expect(lib().stateOf(episodes[0]), same(played));
      expect(lib().stateOf(episodes[1]).isInProgress, isTrue);
      expect(lib().stateOf(episodes[2]).isNew, isTrue);
      expect(lib().stateOf(episodes[3]), same(dismissed));
      expect(lib().stateOf(episodes[4]).isDismissed, isTrue);
      expect(lib().stateOf(episodes[5]).isDismissed, isTrue);
      expect(lib().stateOf(episodes[6]).isNew, isTrue);
      expect(lib().stateOf(other).isNew, isTrue);
      expect(lib().queueState, same(queuedBefore));
      expect(finished, unorderedEquals([episodes[4], episodes[5]]));
    });

    test('played and dismissed states ignore late playback reports', () async {
      final played = episodes[0];
      final marked = episodes[1];
      final dismissed = episodes[2];
      await lib().markCompleted(played);
      await lib().markPlayed(marked);
      await lib().dismiss(dismissed);
      await device.sync.whenIdle();
      final pushes = device.api.pushCalls;
      final before = [
        for (final id in [played, marked, dismissed]) lib().stateOf(id),
      ];

      await tick();
      for (final state in before) {
        final id = state.episodeId;
        await lib().recordPosition(
          id,
          const Duration(minutes: 9),
          duration: const Duration(minutes: 30),
        );
        await lib().markCompleted(id);
        expect(lib().stateOf(id), same(state));
      }
      await lib().dismiss(played);
      expect(lib().stateOf(played), same(before.first));
      await device.sync.whenIdle();
      expect(device.api.pushCalls, pushes);

      await lib().prepareForPlayback(dismissed);
      await lib().recordPosition(dismissed, const Duration(minutes: 2));
      expect(lib().stateOf(dismissed).isInProgress, isTrue);
      await lib().markCompleted(dismissed);
      expect(lib().stateOf(dismissed).isPlayed, isTrue);
    });
  });

  test(
    'position samples keep measured duration and advance the timestamp',
    () async {
      final id = episodes[0];
      await lib().recordPosition(
        id,
        const Duration(minutes: 4),
        duration: const Duration(minutes: 20),
      );
      expect(lib().stateOf(id).updatedAt, clock.now);
      expect(lib().stateOf(id).durationMs, 1200000);

      await lib().recordPosition(id, const Duration(minutes: 5));
      final second = lib().stateOf(id);
      expect(second.updatedAt, clock.now.add(const Duration(milliseconds: 1)));
      expect(second.durationMs, 1200000);

      clock.advance(const Duration(minutes: -1));
      await lib().markCompleted(id);
      final completed = lib().stateOf(id);
      expect(
        completed.updatedAt,
        second.updatedAt.add(const Duration(milliseconds: 1)),
      );
      expect(completed.durationMs, 1200000);
    },
  );

  test('the in-progress threshold is 60 s', () async {
    final id = episodes[1];
    await lib().recordPosition(
      episodes[0],
      const Duration(milliseconds: 59999),
    );
    expect(lib().inProgress, isEmpty);
    expect(
      lib().newEpisodes(since: oldestTime).map((e) => e.id),
      contains(episodes[0]),
    );

    await tick();
    await lib().recordPosition(id, const Duration(milliseconds: 60000));
    expect(lib().inProgress.map((e) => e.id), [id]);
    expect(
      lib().newEpisodes(since: oldestTime).map((e) => e.id),
      isNot(contains(id)),
    );
  });

  test('a stalled position keeps its timestamp through pauses and small decoder corrections', () async {
    final id = episodes.first;
    const position = Duration(minutes: 20);
    await lib().recordPosition(
      id,
      position,
      duration: const Duration(hours: 1),
    );
    await device.sync.whenIdle();
    final original = lib().stateOf(id);
    final sends = device.api.pushCalls;
    clock.advance(const Duration(hours: 1));
    for (final delta in [0, -900, 1000]) {
      await lib().recordPositionAt(
        id,
        position + Duration(milliseconds: delta),
        updatedAt: clock.now,
      );
      expect(lib().stateOf(id), same(original));
    }
    await lib().recordPosition(
      id,
      position,
      duration: const Duration(minutes: 59),
    );
    await device.sync.whenIdle();
    expect(device.api.pushCalls, sends);
    expect(lib().pendingCount, 0);
    expect(
      (await device.store.load()).states.single.toJson(),
      original.toJson(),
    );
    await lib().recordPosition(
      id,
      position + const Duration(milliseconds: 1001),
    );
    expect(lib().stateOf(id).updatedAt, clock.now);
  });

  test('playing position samples notify only when the visible lists or duration change', () async {
    final library = lib();
    final id = episodes.first;
    device.sync.setPlayingEpisode(id);
    var changes = 0;
    library.addListener(() => changes++);
    await library.recordPosition(id, const Duration(seconds: 30));
    expect(changes, 1);
    await library.recordPosition(id, const Duration(seconds: 40));
    expect(changes, 1);
    await library.recordPosition(id, const Duration(minutes: 1));
    final order = library.inProgress;
    expect(changes, 2);
    await library.recordPosition(id, const Duration(minutes: 2));
    expect(library.inProgress, same(order));
    expect(changes, 2);
    await library.recordPosition(
      id,
      const Duration(minutes: 3),
      duration: const Duration(hours: 1),
    );
    expect(changes, 3);
    await tick();
    await library.recordPosition(episodes.last, const Duration(minutes: 4));
    expect(library.inProgress.first.id, episodes.last);
    await tick();
    await library.recordPosition(id, const Duration(minutes: 5));
    expect(changes, 5);
    expect(library.inProgress.first.id, id);
    await device.sync.whenIdle();
    expect(device.api.server.states[id]?.positionMs, 300000);
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

  test(
    'cold resume includes sub-minute progress on unsubscribed podcasts',
    () async {
      await lib().recordPosition(episodes[0], const Duration(minutes: 2));
      await tick();
      await lib().recordPosition(episodes[1], const Duration(seconds: 15));
      await lib().unsubscribe(1);
      expect(lib().podcasts, isEmpty);
      expect(lib().recentUnfinishedEpisode?.id, episodes[1]);

      await tick();
      await lib().recordPosition(episodes[2], Duration.zero);
      await lib().markPlayed(episodes[1]);
      expect(lib().recentUnfinishedEpisode?.id, episodes[0]);
    },
  );

  test('new episodes are newest first and include the cutoff day', () async {
    expect(
      lib().newEpisodes(since: oldestTime).map((e) => e.id),
      episodes.reversed,
    );
    final cutoff = lib().episode(episodes[3])!.publishedAt!;
    expect(lib().newEpisodes(since: cutoff).map((e) => e.id), [
      episodes[4],
      episodes[3],
    ]);
    await lib().markPlayed(episodes[4]);
    expect(lib().newEpisodes(since: cutoff).map((e) => e.id), [episodes[3]]);
  });

  test('episodesOf keeps the server order, newest first', () {
    expect(lib().episodesOf(1).map((e) => e.id), episodes.reversed);
    expect(lib().episode(episodes[0])!.title, 'Episode ${episodes[0]}');
  });

  test(
    'dismiss older starts at the selected row among tied and undated episodes',
    () async {
      final list = server.listEpisodes(1)!;
      final date = clock.now;
      for (var i = 0; i < list.length; i++) {
        list[i] = Episode.fromJson({
          ...episodeJson(list[i]),
          'published_at': i < 3 ? formatTime(date) : null,
        });
      }
      server.addEpisodes(1, 0);
      await device.sync.syncNow();
      final ids = list.map((e) => e.id).toList();
      for (final index in [3, 1]) {
        final expected = index == 1 ? ids.sublist(1, 3) : ids.sublist(3);
        expect(
          lib().dismissOlderCandidates(ids[index]).map((e) => e.id),
          expected,
        );
        await lib().dismissOlder(ids[index]);
        expect([
          for (final id in ids)
            if (lib().stateOf(id).isDismissed) id,
        ], ids.sublist(index));
      }
    },
  );

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

    test(
      'manual edits prune finished episodes and enqueue resets them',
      () async {
        final played = episodes[0];
        final dismissed = episodes[1];
        final remaining = episodes[2];
        for (final id in [played, dismissed, remaining]) {
          await lib().enqueue(id);
        }
        await device.sync.whenIdle();
        final before = server.queue!;

        await tick();
        await lib().markCompleted(played);
        await lib().dismiss(dismissed);
        await device.sync.whenIdle();
        expect(server.queue, same(before));
        expect(lib().queue.map((e) => e.id), [remaining]);

        await lib().enqueue(played);
        expect(lib().stateOf(played).isNew, isTrue);
        expect(lib().queueState!.episodeIds, [remaining, played]);
        await lib().enqueue(dismissed, next: true);
        await device.sync.whenIdle();
        expect(lib().stateOf(dismissed).isNew, isTrue);
        expect(server.states[dismissed]!.isNew, isTrue);
        expect(server.queue!.episodeIds, [dismissed, remaining, played]);
      },
    );

    test('queue moves use visible indexes and preserve uncached IDs', () async {
      final uncached = server.addEpisodes(1, 1).single;
      device.api.online = false;
      await lib().applyRemote(
        const [],
        QueueState(
          episodeIds: [uncached, ...episodes.take(3)],
          updatedAt: clock.now,
        ),
      );

      await lib().moveInQueue(episodes[0], 2);
      expect(lib().queue.map((e) => e.id), [
        episodes[1],
        episodes[2],
        episodes[0],
      ]);
      expect(lib().queueState!.episodeIds, [
        uncached,
        episodes[1],
        episodes[2],
        episodes[0],
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
    await lib().recordPosition(
      episodes[0],
      const Duration(minutes: 4),
      duration: const Duration(minutes: 30),
    );
    await lib().enqueue(episodes[1]);
    await device.sync.whenIdle();
    expect(lib().pendingCount, 2);

    final store = LocalStore(device.db);
    final reopened = await SqfliteLibrary.open(store, device.api);
    expect(reopened.podcasts.map((p) => p.title), ['Garden Talk']);
    expect(reopened.episodesOf(1).map((e) => e.id), episodes.reversed);
    expect(reopened.stateOf(episodes[0]).positionMs, 240000);
    expect(reopened.stateOf(episodes[0]).durationMs, 1800000);
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

  test('show notes revalidate on demand after their own podcast changes and survive offline', () async {
    final id = episodes.first;
    var reads = 0;
    device.api.beforeEpisode = (_) async {
      reads++;
    };
    final original = await lib().description(id);
    expect(reads, 1);
    server.addPodcast(2, 'Night Trains');
    server.addEpisodes(2, 1);
    server.descriptions[id] = 'Corrected show notes';
    await device.sync.syncNow();
    expect(await lib().description(id), original);
    expect(reads, 1);

    server.addEpisodes(1, 0);
    await device.sync.syncNow();
    expect(device.api.episodesNotModified[1], 1);
    expect(reads, 1);
    final reopened = await SqfliteLibrary.open(
      LocalStore(device.db),
      device.api,
    );
    addTearDown(reopened.dispose);
    device.api.online = false;
    expect(await reopened.description(id), original);
    device.api.online = true;
    expect(await reopened.description(id), 'Corrected show notes');
    expect(await reopened.description(id), 'Corrected show notes');
    expect(reads, 2);
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

  test('New episodes leaves out a podcast hidden on the server', () async {
    server.addPodcast(2, 'Night Trains');
    final kept = server.addEpisodes(2, 1);
    final pc = await Device.open(server);
    addTearDown(pc.close);
    await pc.loginAndStart('pc');
    await device.sync.syncNow();
    await lib().recordPosition(episodes[0], const Duration(minutes: 2));

    await lib().setNewEpisodesVisibility(1, false);
    expect(lib().podcast(1)!.showInNewEpisodes, isFalse);
    expect(lib().newEpisodes(since: oldestTime).map((e) => e.id), kept);
    expect(lib().episodesOf(1), hasLength(5));
    expect(lib().inProgress.map((e) => e.id), [episodes[0]]);

    await pc.sync.syncNow();
    expect(pc.library.newEpisodes(since: oldestTime).map((e) => e.id), kept);
    final reopened = await SqfliteLibrary.open(
      LocalStore(device.db),
      device.api,
    );
    addTearDown(reopened.dispose);
    expect(reopened.newEpisodes(since: oldestTime).map((e) => e.id), kept);

    device.api.online = false;
    await expectLater(
      lib().setNewEpisodesVisibility(1, true),
      throwsA(isA<OfflineException>()),
    );
    expect(lib().podcast(1)!.showInNewEpisodes, isFalse);
    expect(lib().newEpisodes(since: oldestTime).map((e) => e.id), kept);
  });
}
