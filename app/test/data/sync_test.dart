import 'dart:async';
import 'dart:io';

import 'package:easypodcast/core/api.dart';
import 'package:easypodcast/core/library.dart';
import 'package:easypodcast/core/models.dart';
import 'package:easypodcast/core/sync.dart';
import 'package:easypodcast/data/local_store.dart';
import 'package:easypodcast/data/sqflite_library.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_server.dart';

const restoredServerId = 'f85c6188-ba98-4c4b-9c44-8542d14927be';

void main() {
  late TestClock clock;
  late FakeServer server;
  late List<int> episodes;
  final devices = <Device>[];

  setUpAll(sqfliteFfiInit);

  setUp(() {
    clock = TestClock();
    server = FakeServer(clock);
    server.addPodcast(1, 'Garden Talk');
    episodes = server.addEpisodes(1, 5);
    server.addPodcast(2, 'Night Trains');
    server.addEpisodes(2, 3);
  });

  tearDown(() async {
    for (final d in devices) {
      await d.close();
    }
    devices.clear();
  });

  Future<Device> device(
    String name, {
    bool start = true,
    Duration initialBackoff = const Duration(milliseconds: 20),
    Duration maxBackoff = const Duration(milliseconds: 160),
    Duration freshStateTimeout = const Duration(milliseconds: 100),
    Duration queueRefreshTimeout = const Duration(seconds: 2),
    Duration logoutSendTimeout = const Duration(seconds: 2),
  }) async {
    final d = await Device.open(
      server,
      initialBackoff: initialBackoff,
      maxBackoff: maxBackoff,
      freshStateTimeout: freshStateTimeout,
      queueRefreshTimeout: queueRefreshTimeout,
      logoutSendTimeout: logoutSendTimeout,
    );
    devices.add(d);
    if (start) await d.loginAndStart(name);
    return d;
  }

  void later([Duration delta = const Duration(seconds: 1)]) =>
      clock.advance(delta);

  test('start pulls podcasts, episode lists and state', () async {
    later();
    server.states[episodes[0]] = EpisodeState(
      episodeId: episodes[0],
      positionMs: 300000,
      status: EpisodeStatus.none,
      updatedAt: clock.now,
    );
    final phone = await device('phone');
    expect(phone.library.podcasts.map((p) => p.title), [
      'Garden Talk',
      'Night Trains',
    ]);
    expect(phone.library.episodesOf(1), hasLength(5));
    expect(phone.library.inProgress.map((e) => e.id), [episodes[0]]);
    expect(phone.store.meta(MetaKey.serverId), server.serverId);
    expect(phone.sync.status.value.phase, SyncPhase.idle);
    expect(phone.sync.status.value.lastSuccess, clock.now);
  });

  test(
    'a local change is sent at once and the pending count drops to 0',
    () async {
      final phone = await device('phone');
      later();
      await phone.library.recordPosition(
        episodes[1],
        const Duration(minutes: 2),
      );
      expect(phone.sync.status.value.pending, 1);
      await settle();
      await phone.sync.whenIdle();
      expect(server.states[episodes[1]]!.positionMs, 120000);
      expect(server.states[episodes[1]]!.updatedAt, clock.now);
      expect(phone.library.pendingCount, 0);
      expect(phone.sync.status.value.pending, 0);
      expect(phone.sync.status.value.phase, SyncPhase.idle);
    },
  );

  test('state and queue travel in one request', () async {
    final phone = await device('phone');
    phone.api.online = false;
    await phone.library.recordPosition(episodes[0], const Duration(minutes: 2));
    await phone.library.enqueue(episodes[1]);
    await phone.sync.whenIdle();
    phone.api.online = true;
    final before = phone.api.pushCalls;
    phone.api.syncCalls.clear();
    await phone.sync.syncNow();
    expect(phone.api.pushCalls, before + 1);
    expect(phone.api.syncCalls, ['state', 'push', 'state', 'podcasts']);
    expect(server.queue!.episodeIds, [episodes[1]]);
    expect(server.states[episodes[0]]!.positionMs, 120000);
  });

  test('status and queue commands force a send even when the preceding write failed', () async {
    const retry = Duration(seconds: 30);
    final phone = await device(
      'phone',
      initialBackoff: retry,
      maxBackoff: retry,
    );
    final library = phone.library;
    final id = episodes.first;
    final other = episodes[1];
    final commands = <Future<void> Function()>[
      () => library.markPlayed(id),
      () async {
        await library.prepareForPlayback(id);
      },
      () => library.dismiss(id),
      () => library.markNew(id),
      () => library.enqueue(id),
      () => library.enqueue(other),
      () => library.moveInQueue(other, 0),
      () => library.dequeue(id),
      () => library.dismissOlder(id),
    ];
    for (final (i, command) in commands.indexed) {
      final state = library.stateOf(id).updatedAt;
      final queue = library.queueState;
      phone.api.beforePush = () async {
        if (library.stateOf(id).updatedAt == state &&
            identical(library.queueState, queue)) {
          throw OfflineException();
        }
      };
      await library.recordPosition(episodes.last, Duration(minutes: i + 1));
      await phone.sync.whenIdle();
      expect(phone.sync.currentBackoff, retry);
      await command();
      await phone.sync.whenIdle();
      expect(library.pendingCount, 0);
      expect(server.states[episodes.last]?.positionMs, (i + 1) * 60000);
    }
    expect(server.states[id]?.isDismissed, isTrue);
    expect(server.queue?.episodeIds, [other]);
  });

  test(
    'a failed catalogue pull keeps its own backoff while posts succeed',
    () async {
      const wait = Duration(seconds: 30);
      final phone = await device(
        'phone',
        initialBackoff: wait,
        maxBackoff: wait,
      );
      phone.api.beforePodcasts = () async =>
          throw ApiException(503, 'catalogue unavailable');
      await phone.sync.syncNow();
      final pulls = phone.api.stateCalls;
      await phone.library.recordPosition(
        episodes[0],
        const Duration(minutes: 4),
      );
      await phone.sync.whenIdle();
      await phone.library.markPlayed(episodes[1]);
      await phone.sync.whenIdle();
      expect(server.states[episodes[0]]?.positionMs, 240000);
      expect(server.states[episodes[1]]?.isPlayed, isTrue);
      expect(phone.api.stateCalls, pulls);
      expect(phone.sync.currentBackoff, wait);
      expect(phone.sync.status.value.error, 'catalogue unavailable');
    },
  );

  test('a send starts during a held episode list and finishes before the next list', () async {
    final phone = await device('phone');
    final added = server.addEpisodes(1, 1).single;
    server.addEpisodes(2, 1);
    final listStarted = Completer<void>();
    final releaseList = Completer<void>();
    final firstListSaved = Completer<void>();
    final pushStarted = Completer<void>();
    final releasePush = Completer<void>();
    var secondListStarted = false;
    phone.api.beforeEpisodes = (id) async {
      if (id == 1) {
        listStarted.complete();
        await releaseList.future;
      } else {
        secondListStarted = true;
      }
    };
    phone.library.addListener(() {
      if (!firstListSaved.isCompleted && phone.library.episode(added) != null) {
        firstListSaved.complete();
      }
    });
    phone.api.beforePush = () {
      pushStarted.complete();
      return releasePush.future;
    };
    final pull = phone.sync.syncNow();
    try {
      await listStarted.future.timeout(const Duration(seconds: 2));
      await phone.library.markPlayed(episodes.first);
      await pushStarted.future.timeout(const Duration(seconds: 2));
      releaseList.complete();
      await firstListSaved.future.timeout(const Duration(seconds: 2));
      await settle();
      expect(secondListStarted, isFalse);
    } finally {
      if (!releaseList.isCompleted) releaseList.complete();
      releasePush.complete();
      await pull;
    }
    expect(secondListStarted, isTrue);
    expect(server.states[episodes.first]?.isPlayed, isTrue);
    expect(phone.api.pushCalls, 1);
  });

  test(
    'offline changes are kept, retried with backoff and sent later',
    () async {
      final phone = await device('phone');
      phone.api.online = false;
      later();
      await phone.library.recordPosition(
        episodes[0],
        const Duration(minutes: 3),
      );
      await settle();
      await phone.sync.whenIdle();
      expect(phone.sync.status.value.phase, SyncPhase.offline);
      expect(phone.sync.status.value.pending, 1);
      expect(phone.sync.currentBackoff, const Duration(milliseconds: 20));
      expect(phone.sync.retryScheduled, isTrue);

      await settle(const Duration(milliseconds: 40));
      await phone.sync.whenIdle();
      expect(phone.sync.currentBackoff, const Duration(milliseconds: 40));
      await settle(const Duration(milliseconds: 500));
      await phone.sync.whenIdle();
      expect(phone.sync.currentBackoff, const Duration(milliseconds: 160));
      expect(server.states[episodes[0]], isNull);

      // Another change while waiting does not bypass the backoff.
      final attempts = phone.api.pushCalls;
      await phone.library.recordPosition(
        episodes[0],
        const Duration(minutes: 4),
      );
      await settle();
      expect(phone.api.pushCalls, attempts);
      expect(phone.library.pendingCount, 1);

      final stateCalls = phone.api.stateCalls;
      phone.api.online = true;
      await settle(const Duration(milliseconds: 200));
      await phone.sync.whenIdle();
      expect(server.states[episodes[0]]!.positionMs, 240000);
      expect(phone.library.pendingCount, 0);
      expect(phone.sync.currentBackoff, isNull);
      expect(phone.sync.status.value.phase, SyncPhase.idle);
      // A send after an offline period is followed by a pull.
      expect(phone.api.stateCalls, stateCalls + 2);
    },
  );

  for (final (label, error, phase) in [
    ('a timeout', TimeoutException('slow response'), SyncPhase.offline),
    ('HTTP 503', ApiException(503, 'unavailable'), SyncPhase.error),
  ]) {
    test('retries $label in the background with the original time', () async {
      final phone = await device(
        'phone',
        initialBackoff: const Duration(milliseconds: 100),
      );
      phone.sync.didChangeAppLifecycleState(AppLifecycleState.paused);
      final retried = Completer<void>();
      var attempts = 0;
      phone.api.beforePush = () async {
        if (++attempts == 1) throw error;
        if (attempts == 2) retried.complete();
      };

      final id = episodes[0];
      final listenedAt = clock.now;
      await phone.library.recordPosition(
        id,
        const Duration(minutes: 3),
        duration: const Duration(minutes: 20),
      );
      await phone.sync.whenIdle();
      expect(phone.sync.status.value.phase, phase);
      expect(phone.sync.retryScheduled, isTrue);
      expect(phone.library.pendingCount, 1);
      expect(server.states[id], isNull);

      later();
      await retried.future.timeout(const Duration(seconds: 2));
      await phone.sync.whenIdle();
      expect(phone.library.pendingCount, 0);
      expect(server.states[id]!.updatedAt, listenedAt);
      expect(server.states[id]!.durationMs, 1200000);
      expect(phone.api.syncCalls, [
        'state',
        'podcasts',
        'push',
        'state',
        'push',
        'state',
        'podcasts',
      ]);
    });
  }

  test(
    'pending changes survive a restart and go out on the next start',
    () async {
      final phone = await device('phone');
      phone.api.online = false;
      await phone.library.markPlayed(episodes[2]);
      await phone.sync.whenIdle();
      await phone.sync.stop();

      final restarted = await Device.open(server, db: phone.db);
      devices.add(restarted);
      expect(restarted.library.pendingCount, 1);
      await restarted.sync.start();
      await restarted.sync.whenIdle();
      expect(restarted.api.syncCalls.take(2), ['state', 'push']);
      expect(restarted.api.stateNotModified, 1);
      expect(server.states[episodes[2]]!.status, EpisodeStatus.played);
      expect(restarted.library.pendingCount, 0);
    },
  );

  test('the foreground retries at once, skipping the backoff', () async {
    final phone = await device('phone');
    phone.api.online = false;
    await phone.library.markPlayed(episodes[0]);
    await phone.sync.whenIdle();
    expect(phone.sync.retryScheduled, isTrue);
    phone.sync.didChangeAppLifecycleState(AppLifecycleState.paused);
    await phone.sync.whenIdle();
    phone.api.online = true;
    final pulls = phone.api.stateCalls;
    phone.sync.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await phone.sync.whenIdle();
    expect(server.states[episodes[0]]!.status, EpisodeStatus.played);
    expect(phone.api.stateCalls, greaterThan(pulls));
  });

  test('a headless start pulls once, then polls only while the activity is in the foreground', () async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    final previous = binding.lifecycleState;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    const interval = Duration(milliseconds: 50);
    final phone = await Device.open(
      server,
      observeLifecycle: true,
      pullInterval: interval,
    );
    devices.add(phone);
    try {
      await phone.loginAndStart('Auto');
      await settle(interval * 3);
      expect(phone.api.stateCalls, 1);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await phone.sync.whenIdle();
      expect(phone.api.stateCalls, 2);
      final poll = Completer<void>();
      phone.api.beforeStateReply = () async {
        if (!poll.isCompleted) poll.complete();
      };
      await poll.future.timeout(const Duration(seconds: 2));
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await phone.sync.whenIdle();
      final calls = phone.api.stateCalls;
      await settle(interval * 3);
      expect(phone.api.stateCalls, calls);
    } finally {
      await phone.sync.stop();
      if (previous != null) binding.handleAppLifecycleStateChanged(previous);
    }
  });

  test(
    'returning to the foreground during a failing send still retries at once',
    () async {
      final phone = await device('phone');
      phone.sync.didChangeAppLifecycleState(AppLifecycleState.paused);
      final started = Completer<void>();
      final release = Completer<void>();
      phone.api.beforePush = () async {
        phone.api.beforePush = null;
        started.complete();
        await release.future;
        throw OfflineException('connection lost');
      };
      final id = episodes[0];
      await phone.library.markPlayed(id);
      try {
        await started.future.timeout(const Duration(seconds: 2));
        phone.sync.didChangeAppLifecycleState(AppLifecycleState.resumed);
      } finally {
        release.complete();
      }
      await phone.sync.whenIdle();
      expect(phone.sync.retryScheduled, isFalse);
      expect(server.states[id]?.isPlayed, isTrue);
    },
  );

  test('a newer local change wins on the server, an older one takes the server state', () async {
    final phone = await device('phone');
    phone.api.online = false;
    later();
    await phone.library.recordPosition(episodes[0], const Duration(minutes: 5));
    await phone.library.recordPosition(episodes[1], const Duration(minutes: 5));
    await phone.sync.whenIdle();

    later();
    server.states[episodes[1]] = EpisodeState(
      episodeId: episodes[1],
      positionMs: 900000,
      status: EpisodeStatus.none,
      updatedAt: clock.now,
    );
    server.states[episodes[0]] = EpisodeState(
      episodeId: episodes[0],
      positionMs: 1000,
      status: EpisodeStatus.none,
      updatedAt: clock.now.subtract(const Duration(hours: 1)),
    );
    phone.api.online = true;
    await phone.sync.syncNow();

    expect(server.states[episodes[0]]!.positionMs, 300000);
    expect(server.states[episodes[1]]!.positionMs, 900000);
    expect(phone.library.stateOf(episodes[1]).positionMs, 900000);
    expect(phone.library.stateOf(episodes[0]).positionMs, 300000);
    expect(phone.library.pendingCount, 0);
  });

  test(
    'a pull applies only newer records and never moves the playing episode',
    () async {
      final phone = await device('phone');
      await phone.library.recordPosition(
        episodes[0],
        const Duration(minutes: 5),
      );
      await phone.library.recordPosition(
        episodes[1],
        const Duration(minutes: 5),
      );
      await phone.library.recordPosition(
        episodes[2],
        const Duration(minutes: 5),
      );
      await phone.sync.whenIdle();
      final stamp = phone.library.stateOf(episodes[0]).updatedAt;

      later();
      server.states[episodes[0]] = EpisodeState(
        episodeId: episodes[0],
        positionMs: 1,
        status: EpisodeStatus.none,
        updatedAt: stamp,
      );
      server.states[episodes[1]] = EpisodeState(
        episodeId: episodes[1],
        positionMs: 700000,
        status: EpisodeStatus.none,
        updatedAt: clock.now,
      );
      server.states[episodes[2]] = EpisodeState(
        episodeId: episodes[2],
        positionMs: 800000,
        status: EpisodeStatus.none,
        updatedAt: clock.now,
      );
      phone.sync.setPlayingEpisode(episodes[2]);
      await phone.sync.syncNow();

      expect(phone.library.stateOf(episodes[0]).positionMs, 300000);
      expect(phone.library.stateOf(episodes[1]).positionMs, 700000);
      expect(phone.library.stateOf(episodes[2]).positionMs, 300000);

      // The player's next report is newer and wins everywhere.
      later();
      await phone.library.recordPosition(
        episodes[2],
        const Duration(minutes: 6),
      );
      await settle();
      await phone.sync.whenIdle();
      expect(server.states[episodes[2]]!.positionMs, 360000);
    },
  );

  test(
    'pending changes for ids the server does not know are dropped',
    () async {
      final phone = await device('phone');
      phone.api.online = false;
      await phone.library.recordPosition(99999, const Duration(minutes: 2));
      await phone.library.recordPosition(
        episodes[0],
        const Duration(minutes: 2),
      );
      await phone.library.enqueue(99998);
      await phone.library.enqueue(episodes[1]);
      await phone.sync.whenIdle();
      expect(phone.library.pendingCount, 3);

      phone.api.online = true;
      await phone.sync.syncNow();
      expect(phone.library.pendingCount, 0);
      expect(server.states.containsKey(99999), isFalse);
      expect(server.states[episodes[0]]!.positionMs, 120000);
      expect(server.queue!.episodeIds, [episodes[1]]);
      expect(phone.library.queueState!.episodeIds, [episodes[1]]);

      final pushes = phone.api.pushCalls;
      await phone.sync.syncNow();
      expect(phone.api.pushCalls, pushes);
    },
  );

  test(
    'episode lists are fetched again only when episodes_version changes',
    () async {
      final phone = await device('phone');
      expect(phone.api.episodesCalls, {1: 1, 2: 1});

      await phone.sync.syncNow();
      expect(phone.api.episodesCalls, {1: 1, 2: 1});

      final added = server.addEpisodes(
        2,
        1,
        firstPublished: DateTime.utc(2026, 6),
      );
      await phone.sync.syncNow();
      expect(phone.api.episodesCalls, {1: 1, 2: 2});
      expect(phone.library.episodesOf(2).first.id, added.single);
      expect(phone.library.newEpisodes().first.id, added.single);
    },
  );

  test(
    'an unchanged list behind a new version keeps the local copy (304)',
    () async {
      final phone = await device('phone');
      server.addEpisodes(1, 0);
      await phone.sync.syncNow();
      expect(phone.api.episodesCalls[1], 2);
      expect(phone.api.episodesNotModified[1], 1);
      expect(phone.library.episodesOf(1), hasLength(5));
      expect(
        phone.library.storedEpisodesVersion(1),
        server.listPodcasts().firstWhere((p) => p.id == 1).episodesVersion,
      );
    },
  );

  test('each online queue command refreshes before editing', () async {
    final phone = await device('phone');
    final pc = await device('pc');
    final first = episodes[0];
    final second = episodes[1];
    final third = episodes[2];

    await phone.library.enqueue(first);
    await phone.sync.whenIdle();
    await pc.library.enqueue(second);
    await pc.sync.whenIdle();
    expect(server.queue!.episodeIds, [first, second]);

    await phone.library.moveInQueue(second, 0);
    await phone.sync.whenIdle();
    expect(server.queue!.episodeIds, [second, first]);

    await phone.library.enqueue(third, next: true);
    await phone.sync.whenIdle();
    await pc.library.dequeue(first);
    await pc.sync.whenIdle();
    expect(server.queue!.episodeIds, [third, second]);
  });

  test(
    'quick add, move and remove commands preserve their issue order',
    () async {
      final phone = await device('phone');
      final pc = await device('pc');
      final [remote, a, b, _, _] = episodes;
      await pc.library.enqueue(remote);
      await pc.sync.whenIdle();
      final reading = Completer<void>();
      final release = Completer<void>();
      var refreshes = 0;
      phone.api.beforeStateReply = () async {
        if (++refreshes == 1) {
          reading.complete();
          await release.future;
        }
      };
      final edits = Future.wait([
        phone.library.enqueue(a),
        phone.library.enqueue(b),
        phone.library.moveInQueue(b, 0),
        phone.library.dequeue(remote),
      ]);
      try {
        await reading.future.timeout(const Duration(seconds: 2));
        await settle();
        expect(refreshes, 1);
      } finally {
        release.complete();
        await edits;
      }
      await phone.sync.whenIdle();
      expect(refreshes, 4);
      expect(server.queue?.episodeIds, [b, a]);
      await pc.sync.syncNow();
      expect(pc.library.queue.map((item) => item.id), [b, a]);
    },
  );

  for (final slow in [false, true]) {
    test(
      'bulk dismiss without a fresh snapshot preserves remote progress (slow: $slow)',
      () async {
        final palma = await device(
          'palma',
          queueRefreshTimeout: const Duration(milliseconds: 100),
        );
        final other = await device('pc');
        final listening = episodes.first;
        await other.library.recordPosition(
          listening,
          const Duration(minutes: 25),
        );
        await other.sync.whenIdle();
        later(const Duration(hours: 8));
        final release = Completer<void>();
        if (slow) {
          palma.api.beforeStateReply = () => release.future;
        } else {
          palma.api.online = false;
        }
        try {
          await expectLater(
            palma.library.dismissOlder(episodes.last),
            throwsA(isA<BulkDismissNeedsConnection>()),
          );
          expect(palma.library.pendingCount, 0);
          expect(palma.api.pushCalls, 0);
          expect((await palma.store.load()).states, isEmpty);
        } finally {
          release.complete();
        }
        palma.api.beforeStateReply = null;
        palma.api.online = true;
        await palma.sync.syncNow();
        expect(palma.library.stateOf(listening).positionMs, 1500000);
        expect(server.states.length, 1);
      },
    );
  }

  for (final playingLocally in [false, true]) {
    test(
      'bulk dismissal protects remote listening (playing locally: $playingLocally)',
      () async {
        final palma = await device('palma');
        final hibreak = await device('hibreak');
        final [queued, listening, older, chosen, newer] = episodes;
        later();
        await hibreak.library.enqueue(queued);
        await hibreak.library.recordPosition(
          listening,
          const Duration(minutes: 9),
        );
        await hibreak.sync.whenIdle();
        expect(palma.library.queue, isEmpty);
        expect(palma.library.stateOf(listening).isNew, isTrue);
        if (playingLocally) palma.sync.setPlayingEpisode(listening);

        later();
        palma.api.syncCalls.clear();
        await palma.library.dismissOlder(chosen);
        await palma.sync.whenIdle();
        expect(palma.api.syncCalls.take(2), ['state', 'push']);
        expect(palma.library.queue.map((entry) => entry.id), [queued]);
        expect(server.states[queued], isNull);
        expect(server.states[listening]?.positionMs, 540000);
        expect(palma.library.stateOf(listening).isNew, playingLocally);
        expect(server.states[older]?.isDismissed, isTrue);
        expect(server.states[chosen]?.isDismissed, isTrue);
        expect(server.states[newer], isNull);
      },
    );
  }

  test('the newer queue wins when an older offline edit arrives', () async {
    final phone = await device('phone');
    final pc = await device('pc');

    later();
    await phone.library.enqueue(episodes[0]);
    await phone.sync.whenIdle();
    later();
    await pc.library.enqueue(episodes[3]);
    await pc.sync.whenIdle();
    expect(server.queue!.episodeIds, [episodes[0], episodes[3]]);

    await phone.sync.syncNow();
    expect(phone.library.queue.map((e) => e.id), [episodes[0], episodes[3]]);

    pc.api.online = false;
    later();
    await pc.library.enqueue(episodes[4]);
    await pc.sync.whenIdle();
    later();
    await phone.library.dequeue(episodes[3]);
    await phone.sync.whenIdle();
    pc.api.online = true;
    await pc.sync.syncNow();
    expect(server.queue!.episodeIds, [episodes[0]]);
    expect(pc.library.queue.map((e) => e.id), [episodes[0]]);
  });

  test('a slow queue refresh leaves the edit on the cached queue', () async {
    final phone = await device(
      'phone',
      queueRefreshTimeout: const Duration(milliseconds: 100),
    );
    await phone.library.enqueue(episodes[0]);
    await phone.sync.whenIdle();
    server.queue = QueueState(
      episodeIds: [episodes[3]],
      updatedAt: clock.now.add(const Duration(minutes: 1)),
    );
    final requested = Completer<void>();
    final reply = Completer<void>();
    phone.api.beforeStateReply = () {
      requested.complete();
      return reply.future;
    };

    final edit = phone.library.enqueue(episodes[1]);
    try {
      await requested.future.timeout(const Duration(seconds: 2));
      phone.api.online = false;
      await edit.timeout(const Duration(seconds: 1));
      expect(phone.library.queueState!.episodeIds, [episodes[0], episodes[1]]);
    } finally {
      reply.complete();
      await edit;
    }
    await settle();
    expect(phone.library.queueState!.episodeIds, [episodes[0], episodes[1]]);
    expect(phone.library.pendingCount, 1);
  });

  test('queue refresh sends pending state before reading the server', () async {
    final phone = await device('phone');
    phone.api.online = false;
    await phone.library.recordPosition(episodes[0], const Duration(minutes: 2));
    await phone.sync.whenIdle();
    phone.api.online = true;
    phone.api.syncCalls.clear();

    await phone.library.enqueue(episodes[1]);
    await phone.sync.whenIdle();
    expect(phone.api.syncCalls.take(3), ['state', 'push', 'state']);
    expect(server.states[episodes[0]]!.positionMs, 120000);
    expect(server.queue!.episodeIds, [episodes[1]]);
  });

  test(
    'a reachable queue is refreshed even when a pending write fails',
    () async {
      final phone = await device('phone');
      final pc = await device('pc');
      await pc.library.enqueue(episodes[1]);
      await pc.sync.whenIdle();
      phone.api.online = false;
      await phone.library.markPlayed(episodes[0]);
      await phone.sync.whenIdle();
      phone.api.online = true;
      phone.api.beforePush = () async => throw ApiException(503, 'unavailable');
      phone.api.syncCalls.clear();

      await phone.library.enqueue(episodes[2]);
      expect(phone.api.syncCalls.take(3), ['state', 'push', 'state']);
      expect(phone.library.queueState!.episodeIds, [episodes[1], episodes[2]]);
      expect(phone.library.pendingCount, 2);
    },
  );

  test(
    'a played episode from another device reaches finishedEpisodes',
    () async {
      final phone = await device('phone');
      final pc = await device('pc');
      final finished = <int>[];
      phone.library.finishedEpisodes.listen(finished.add);

      later();
      await pc.library.dismiss(episodes[2]);
      await pc.sync.whenIdle();
      await phone.sync.syncNow();
      await settle();
      expect(finished, [episodes[2]]);
      expect(phone.library.stateOf(episodes[2]).isDismissed, isTrue);
    },
  );

  test(
    'a late pause on the dismissing device stays dismissed on both devices',
    () async {
      final a = await device('phone');
      final b = await device('pc');
      final id = episodes[0];
      await a.library.enqueue(id);
      await a.sync.whenIdle();
      await b.sync.syncNow();
      final queuedBefore = server.queue;
      expect(b.library.queue.map((e) => e.id), [id]);

      a.api.online = false;
      later();
      await a.library.dismiss(id);
      final dismissed = a.library.stateOf(id);
      later();
      await a.library.recordPosition(id, const Duration(minutes: 4));
      expect(a.library.stateOf(id), same(dismissed));

      a.api.online = true;
      await a.sync.syncNow();
      await b.sync.syncNow();
      expect(server.states[id]!.isDismissed, isTrue);
      expect(b.library.stateOf(id).updatedAt, dismissed.updatedAt);
      expect(b.library.stateOf(id).positionMs, 0);
      expect(b.library.stateOf(id).isDismissed, isTrue);
      expect(b.library.queue, isEmpty);
      expect(server.queue, same(queuedBefore));
    },
  );

  test('an uncached episode state is stored before the list arrives', () async {
    final a = await device('phone');
    final b = await device('pc');
    final id = server.addEpisodes(1, 1).single;
    await a.sync.syncNow();
    await a.library.recordPosition(
      id,
      const Duration(minutes: 10),
      duration: const Duration(minutes: 30),
    );
    await a.library.enqueue(id);
    await a.sync.whenIdle();

    final catalogRequested = Completer<void>();
    final releaseCatalog = Completer<void>();
    b.api.beforePodcasts = () {
      catalogRequested.complete();
      return releaseCatalog.future;
    };
    final sync = b.sync.syncNow();
    try {
      await catalogRequested.future.timeout(const Duration(seconds: 2));
      expect(b.library.episode(id), isNull);
      expect(b.library.stateOf(id).positionMs, 600000);
      expect(b.library.queueState!.episodeIds, [id]);
      expect(b.library.queue, isEmpty);
      final cached = await b.store.load();
      expect(cached.states.single.durationMs, 1800000);
      expect(cached.pendingStates, isEmpty);
      expect(cached.queue!.episodeIds, [id]);
    } finally {
      releaseCatalog.complete();
      await sync;
    }

    expect(b.library.inProgress.map((e) => e.id), [id]);
    expect(b.library.queue.map((e) => e.id), [id]);
    expect(b.library.stateOf(id).updatedAt, a.library.stateOf(id).updatedAt);
    expect(b.api.episodesCalls, {1: 2, 2: 1});
    expect(b.api.pushCalls, 0);
  });

  test(
    'an uncached queue entry found during an edit refreshes its episode list',
    () async {
      final a = await device('phone');
      final b = await device('pc');
      final id = server.addEpisodes(2, 1).single;
      await a.sync.syncNow();
      await a.library.enqueue(id);
      await a.sync.whenIdle();
      expect(b.library.episode(id), isNull);

      await b.library.enqueue(episodes[0]);
      await b.sync.whenIdle();
      expect(b.library.queue.map((e) => e.id), [id, episodes[0]]);
      expect(server.queue!.episodeIds, [id, episodes[0]]);
      expect(b.api.episodesCalls, {1: 1, 2: 2});
    },
  );

  test(
    'key scenario: an offline listen does not overwrite a later one',
    () async {
      final a = await device('palma');
      final b = await device('hibreak');
      final id = episodes[0];

      // B listens offline in the evening.
      b.api.online = false;
      later(const Duration(hours: 1));
      await b.library.prepareForPlayback(id);
      b.sync.setPlayingEpisode(id);
      await b.library.recordPosition(id, const Duration(minutes: 10));
      later(const Duration(minutes: 10));
      await b.library.recordPosition(id, const Duration(minutes: 20));
      b.sync.setPlayingEpisode(null);
      await b.sync.whenIdle();
      expect(b.library.pendingCount, 1);

      // A listens later online and gets further.
      later(const Duration(hours: 10));
      await a.sync.freshStateBeforePlay(id);
      final start = await a.library.prepareForPlayback(id);
      expect(start, Duration.zero);
      a.sync.setPlayingEpisode(id);
      await a.library.recordPosition(id, const Duration(minutes: 35));
      a.sync.setPlayingEpisode(null);
      await settle();
      await a.sync.whenIdle();
      expect(server.states[id]!.positionMs, 35 * 60000);

      // B comes back: the server keeps A's position and B takes it over.
      later(const Duration(minutes: 5));
      b.api.online = true;
      b.sync.didChangeAppLifecycleState(AppLifecycleState.paused);
      b.sync.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await b.sync.whenIdle();
      expect(server.states[id]!.positionMs, 35 * 60000);
      expect(b.library.stateOf(id).positionMs, 35 * 60000);
      expect(b.library.pendingCount, 0);
      expect(b.library.inProgress.map((e) => e.id), [id]);

      await b.sync.freshStateBeforePlay(id);
      expect(
        await b.library.prepareForPlayback(id),
        const Duration(minutes: 35),
      );
    },
  );

  group('freshStateBeforePlay', () {
    test('applies a newer server state', () async {
      final phone = await device('phone');
      await phone.library.recordPosition(
        episodes[0],
        const Duration(minutes: 1),
      );
      await phone.sync.whenIdle();
      later();
      server.states[episodes[0]] = EpisodeState(
        episodeId: episodes[0],
        positionMs: 500000,
        status: EpisodeStatus.none,
        updatedAt: clock.now,
      );
      await phone.sync.freshStateBeforePlay(episodes[0]);
      expect(phone.library.stateOf(episodes[0]).positionMs, 500000);
    });

    test('keeps a newer local state', () async {
      final phone = await device('phone');
      phone.api.online = false;
      later();
      await phone.library.recordPosition(
        episodes[0],
        const Duration(minutes: 9),
      );
      server.states[episodes[0]] = EpisodeState(
        episodeId: episodes[0],
        positionMs: 1000,
        status: EpisodeStatus.none,
        updatedAt: clock.now.subtract(const Duration(minutes: 1)),
      );
      phone.api.online = true;
      await phone.sync.freshStateBeforePlay(episodes[0]);
      expect(phone.library.stateOf(episodes[0]).positionMs, 540000);
    });

    test(
      'flushes offline listening before requesting the episode state',
      () async {
        final phone = await device(
          'phone',
          initialBackoff: const Duration(seconds: 5),
          maxBackoff: const Duration(seconds: 5),
          freshStateTimeout: const Duration(milliseconds: 500),
        );
        final id = episodes.first;
        phone.api.online = false;
        await phone.library.recordPosition(id, const Duration(minutes: 13));
        await phone.sync.whenIdle();
        final offline = phone.library.stateOf(id);

        phone.api.online = true;
        final sending = Completer<void>();
        final release = Completer<void>();
        phone.api.beforePush = () {
          sending.complete();
          return release.future;
        };
        final check = phone.sync.freshStateBeforePlay(id);
        try {
          await sending.future.timeout(const Duration(seconds: 1));
          expect(phone.api.episodeStateCalls, 0);
        } finally {
          release.complete();
          await check;
        }
        expect(phone.api.episodeStateCalls, 1);
        expect(phone.library.pendingCount, 0);
        expect(server.states[id]?.toJson(), offline.toJson());
      },
    );

    test(
      'a delayed flush leaves only the remaining pre-play time for the GET',
      () async {
        const limit = Duration(milliseconds: 500);
        final phone = await device(
          'phone',
          initialBackoff: const Duration(seconds: 5),
          maxBackoff: const Duration(seconds: 5),
          freshStateTimeout: limit,
        );
        phone.api.online = false;
        await phone.library.recordPosition(
          episodes[0],
          const Duration(minutes: 2),
        );
        await phone.sync.whenIdle();
        phone.api.online = true;
        phone.api.beforePush = () => settle(const Duration(milliseconds: 120));
        phone.api.episodeStateDelay = const Duration(seconds: 1);

        final elapsed = Stopwatch()..start();
        await phone.sync.freshStateBeforePlay(episodes[1]);
        expect(phone.api.episodeStateCalls, 1);
        expect(
          phone.api.episodeStateTimeout,
          lessThan(limit - const Duration(milliseconds: 100)),
        );
        expect(
          elapsed.elapsed,
          lessThan(limit + const Duration(milliseconds: 120)),
        );
        expect(phone.library.pendingCount, 0);
      },
    );

    test('offline or slow, it returns in time without throwing', () async {
      final phone = await device('phone');
      phone.api.online = false;
      await phone.sync.freshStateBeforePlay(episodes[0]);

      phone.api.online = true;
      phone.api.episodeStateDelay = const Duration(seconds: 5);
      final watch = Stopwatch()..start();
      await phone.sync.freshStateBeforePlay(episodes[0]);
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));

      phone.api.episodeStateDelay = null;
      phone.api.statusOverride = 500;
      await phone.sync.freshStateBeforePlay(episodes[0]);
    });
  });

  test(
    'snapshots report signed device clock skew only beyond five minutes',
    () async {
      final deviceClock = TestClock(clock.now.add(const Duration(minutes: 5)));
      final phone = await Device.open(server, deviceClock: deviceClock);
      devices.add(phone);
      await phone.loginAndStart('phone');
      final SyncService sync = phone.sync;
      expect(sync.clockSkewWarning, isNull);
      const ahead = Duration(minutes: 5, milliseconds: 1);
      deviceClock.now = clock.now.add(ahead);
      await sync.syncNow();
      expect(phone.api.stateNotModified, 1);
      expect(sync.clockSkewWarning, isNull);
      server.queue = QueueState(
        episodeIds: [episodes.last],
        updatedAt: clock.now,
      );
      await sync.syncNow();
      expect(sync.clockSkewWarning, ahead);
      deviceClock.now = clock.now.subtract(ahead);
      await phone.library.enqueue(episodes[0]);
      await phone.sync.whenIdle();
      expect(sync.status.value.clockSkewWarning, -ahead);
      deviceClock.now = clock.now.subtract(const Duration(minutes: 5));
      await sync.syncNow();
      expect(sync.clockSkewWarning, isNull);
    },
  );

  test('a restart repairs rejected state and queue even when their old time has entered the server acceptance window', () async {
    final deviceClock = TestClock(clock.now.add(const Duration(days: 30)));
    const retry = Duration(seconds: 30);
    final phone = await Device.open(
      server,
      deviceClock: deviceClock,
      initialBackoff: retry,
      maxBackoff: retry,
    );
    devices.add(phone);
    await phone.loginAndStart('phone');
    final id = episodes.first;
    await phone.library.recordPosition(
      id,
      const Duration(minutes: 20),
      duration: const Duration(hours: 1),
    );
    await phone.library.enqueue(episodes.last);
    await phone.sync.whenIdle();
    expect(phone.library.pendingCount, 2);
    expect(server.states[id], isNull);
    expect(server.queue, isNull);
    await phone.sync.stop();

    clock.advance(const Duration(days: 29, hours: 12));
    deviceClock.now = clock.now;
    final rebooted = await Device.open(
      server,
      db: phone.db,
      deviceClock: deviceClock,
    );
    devices.add(rebooted);
    await rebooted.sync.start();
    await rebooted.sync.whenIdle();
    expect(server.states[id]?.updatedAt, clock.now);
    expect(server.states[id]?.positionMs, 1200000);
    expect(server.states[id]?.durationMs, 3600000);
    expect(server.queue?.updatedAt, clock.now);
    expect(server.queue?.episodeIds, [episodes.last]);
    final saved = await rebooted.store.load();
    expect(saved.states.single.toJson(), server.states[id]?.toJson());
    expect(saved.queue?.toJson(), server.queue?.toJson());
    expect(saved.pendingStates, isEmpty);
    expect(saved.queuePending, isFalse);
    expect(saved.clockRejections, isEmpty);
  });

  test('new offline edits stop building on a rejected future time after clock correction', () async {
    final ahead = TestClock(clock.now.add(const Duration(days: 30)));
    final phone = await Device.open(server, deviceClock: ahead);
    devices.add(phone);
    await phone.loginAndStart('palma');
    final id = episodes.first;
    await phone.library.recordPosition(id, const Duration(minutes: 5));
    await phone.library.enqueue(id);
    await phone.sync.whenIdle();
    expect(phone.library.pendingCount, 2);
    phone.api.online = false;
    ahead.now = clock.now;
    await phone.library.recordPositionAt(
      id,
      const Duration(minutes: 15),
      updatedAt: clock.now,
    );
    expect(phone.library.stateOf(id).updatedAt, clock.now);
    await phone.library.enqueue(episodes.last);
    expect(
      phone.library.queueState!.updatedAt.difference(clock.now).abs(),
      lessThanOrEqualTo(const Duration(milliseconds: 1)),
    );
    phone.api.online = true;
    await phone.sync.syncNow();
    expect(server.states[id]?.positionMs, 900000);
    expect(server.queue?.episodeIds, [id, episodes.last]);
    expect(phone.library.pendingCount, 0);
  });

  test(
    'a change from a clock far ahead is kept and retried (rule 4)',
    () async {
      final ahead = TestClock(clock.now.add(const Duration(days: 2)));
      final phone = await Device.open(server, deviceClock: ahead);
      devices.add(phone);
      await phone.loginAndStart('phone');
      await phone.library.markPlayed(episodes[0]);
      await settle();
      await phone.sync.whenIdle();
      expect(phone.sync.status.value.phase, SyncPhase.error);
      expect(phone.sync.status.value.error, contains('24 hours'));
      expect(phone.library.pendingCount, 1);
      expect(phone.sync.retryScheduled, isTrue);
      expect(server.states[episodes[0]], isNull);

      clock.advance(const Duration(days: 2));
      await phone.sync.syncNow();
      expect(server.states[episodes[0]]!.isPlayed, isTrue);
      expect(phone.library.pendingCount, 0);
      expect(phone.sync.status.value.phase, SyncPhase.idle);
    },
  );

  test('an isolated state retries in the background when the server clock catches up', () async {
    final ahead = TestClock(clock.now.add(const Duration(days: 2)));
    final phone = await Device.open(server, deviceClock: ahead);
    devices.add(phone);
    await phone.loginAndStart('phone');
    phone.sync.didChangeAppLifecycleState(AppLifecycleState.paused);
    final id = episodes.first;
    await phone.library.markPlayed(id);
    await phone.sync.whenIdle();
    final rejected = phone.library.stateOf(id);
    expect(server.states[id], isNull);
    expect(phone.sync.retryScheduled, isTrue);

    final retried = Completer<void>();
    phone.api.beforePush = () async {
      phone.api.beforePush = null;
      retried.complete();
    };
    later(const Duration(days: 2));
    await retried.future.timeout(const Duration(seconds: 2));
    await phone.sync.whenIdle();
    expect(server.states[id]?.toJson(), rejected.toJson());
    expect(phone.library.pendingCount, 0);
  });

  for (final rejectQueue in [false, true]) {
    test(
      'a future-dated ${rejectQueue ? 'queue' : 'state'} has independent retry',
      () async {
        final deviceClock = TestClock(clock.now);
        final phone = await Device.open(
          server,
          deviceClock: deviceClock,
          initialBackoff: const Duration(seconds: 5),
          maxBackoff: const Duration(seconds: 5),
        );
        devices.add(phone);
        await phone.loginAndStart('phone');
        final [invalid, valid, queued, incoming, next] = episodes;
        phone.api.online = false;
        deviceClock.advance(const Duration(days: 2));
        if (rejectQueue) {
          await phone.library.enqueue(queued);
        } else {
          await phone.library.markPlayed(invalid);
        }
        final future = phone.library.pendingChanges();
        deviceClock.now = clock.now;
        await phone.library.recordPosition(valid, const Duration(minutes: 2));
        if (!rejectQueue) await phone.library.enqueue(queued);
        await phone.sync.whenIdle();
        server.states[incoming] = EpisodeState(
          episodeId: incoming,
          positionMs: 300000,
          status: EpisodeStatus.none,
          updatedAt: clock.now,
        );

        deviceClock.now = clock.now.add(const Duration(days: 2));
        phone.api.online = true;
        await phone.sync.syncNow();
        expect(server.states[valid]?.positionMs, 120000);
        expect(server.queue?.episodeIds, rejectQueue ? null : [queued]);
        expect(phone.library.stateOf(incoming).positionMs, 300000);
        expect(phone.library.pendingCount, 1);
        expect(phone.sync.retryScheduled, isTrue);
        expect(server.states[invalid], isNull);

        final splitAttempts = phone.api.pushCalls;
        final remaining = phone.library.pendingChanges();
        expect(remaining.states, future.states);
        expect(remaining.queue, future.queue);
        await phone.library.recordPositionAt(
          next,
          const Duration(minutes: 4),
          updatedAt: clock.now,
        );
        await phone.sync.whenIdle();
        expect(phone.api.pushCalls, splitAttempts + 1);
        expect(phone.api.pushedStates.last.single.episodeId, next);
        expect(phone.api.pushedQueues.last, isNull);
        expect(server.states[next]?.positionMs, 240000);

        later(const Duration(days: 2));
        await phone.sync.syncNow();
        expect(phone.library.pendingCount, 0);
        if (rejectQueue) {
          expect(server.queue?.updatedAt, future.queue!.updatedAt);
        } else {
          expect(
            server.states[invalid]?.updatedAt,
            future.states.single.updatedAt,
          );
        }
      },
    );
  }

  for (final missingQueue in [false, true]) {
    test(
      'a push with an unconfirmed ${missingQueue ? 'queue' : 'episode'} keeps the batch pending',
      () async {
        final phone = await device(
          'phone',
          initialBackoff: const Duration(seconds: 5),
          maxBackoff: const Duration(seconds: 5),
        );
        final id = episodes.first;
        phone.api.online = false;
        await phone.library.recordPosition(id, const Duration(minutes: 2));
        await phone.library.enqueue(episodes[1]);
        await phone.sync.whenIdle();
        phone.api.online = true;
        phone.api.transformPushResult = (result) => StatePushResult(
          episodes: missingQueue ? result.episodes : [],
          queue: missingQueue ? null : result.queue,
          unknown: [],
          serverId: result.serverId,
        );
        await phone.sync.syncNow();

        expect(phone.sync.status.value.phase, SyncPhase.error);
        expect(phone.library.pendingCount, 2);
        final snapshot = await phone.store.load();
        expect(snapshot.pendingStates, {id});
        expect(snapshot.queuePending, isTrue);

        phone.api.transformPushResult = null;
        await phone.sync.syncNow();
        expect(phone.library.pendingCount, 0);
      },
    );
  }

  for (final (gap, sendsQueue) in [
    (Duration.zero, true),
    (const Duration(seconds: 1), true),
    (const Duration(seconds: 1), false),
  ]) {
    test(
      'a delayed acknowledgement preserves a second writer at +$gap (sent queue: $sendsQueue)',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'easypodcast-ack-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final path = '${directory.path}/shared.db';
        Future<Database> open() => LocalStore.open(databaseFactoryFfi, path);
        final phone = await Device.open(server, db: await open());
        addTearDown(phone.close);
        await phone.loginAndStart('phone');
        final second = await open();
        addTearDown(second.close);
        final other = await SqfliteLibrary.open(
          LocalStore(second),
          phone.api,
          clock: clock.call,
        );
        addTearDown(other.dispose);
        final id = episodes[0];

        phone.api.online = false;
        await phone.library.recordPosition(id, const Duration(minutes: 2));
        if (sendsQueue) await phone.library.enqueue(episodes[1]);
        await phone.sync.whenIdle();
        final sending = Completer<void>();
        final release = Completer<void>();
        phone.api.beforePush = () {
          sending.complete();
          return release.future;
        };
        phone.api.online = true;
        final sync = phone.sync.syncNow();
        try {
          await sending.future.timeout(const Duration(seconds: 2));
          if (!sendsQueue) {
            server.queue = QueueState(
              episodeIds: [episodes[3]],
              updatedAt: clock.now,
            );
          }
          later(gap);
          await other.recordPosition(id, const Duration(minutes: 15));
          await other.enqueue(episodes[2]);
        } finally {
          release.complete();
          await sync;
        }

        final reopened = await open();
        addTearDown(reopened.close);
        final snapshot = await LocalStore(reopened).load();
        expect(snapshot.states.single.toJson(), other.stateOf(id).toJson());
        expect(snapshot.queue?.toJson(), other.queueState?.toJson());
        expect(snapshot.pendingStates, {id});
        expect(snapshot.queuePending, isTrue);
      },
    );
  }

  test('401 logs the session out and keeps local changes', () async {
    final phone = await device('phone');
    phone.api.statusOverride = 401;
    await phone.library.markPlayed(episodes[0]);
    await settle();
    await phone.sync.whenIdle();
    expect(phone.sync.isLoggedIn, isFalse);
    expect(phone.sync.status.value.phase, SyncPhase.loggedOut);
    expect(phone.store.meta(MetaKey.token), isNull);
    expect(phone.library.pendingCount, 1);
    expect(phone.sync.retryScheduled, isFalse);

    phone.api.statusOverride = null;
    await phone.sync.login(
      serverUrl: 'https://podcasts.example.test/',
      username: 'listener',
      password: 'secret',
      deviceName: 'phone',
    );
    await phone.sync.whenIdle();
    expect(server.states[episodes[0]]!.isPlayed, isTrue);
  });

  test('login stores the session, logout ends it', () async {
    final phone = await device('phone', start: false);
    expect(phone.sync.isLoggedIn, isFalse);
    await phone.sync.start();
    expect(phone.sync.status.value.phase, SyncPhase.loggedOut);

    await expectLater(
      phone.sync.login(
        serverUrl: 'https://podcasts.example.test',
        username: 'listener',
        password: 'wrong',
        deviceName: 'phone',
      ),
      throwsA(isA<Object>()),
    );
    expect(phone.sync.isLoggedIn, isFalse);

    await phone.sync.login(
      serverUrl: 'https://podcasts.example.test/api',
      username: 'listener',
      password: 'secret',
      deviceName: 'phone',
    );
    await phone.sync.whenIdle();
    expect(phone.sync.isLoggedIn, isTrue);
    expect(
      phone.store.meta(MetaKey.serverUrl),
      'https://podcasts.example.test',
    );
    expect(phone.store.meta(MetaKey.deviceName), 'phone');
    expect(phone.library.podcasts, hasLength(2));

    await phone.sync.logout();
    expect(phone.sync.isLoggedIn, isFalse);
    expect(phone.api.token, isNull);
    expect(phone.sync.status.value.phase, SyncPhase.loggedOut);
    expect(phone.library.podcasts, hasLength(2));
  });

  test('logout sends pending changes before revoking the token', () async {
    final phone = await device(
      'phone',
      initialBackoff: const Duration(milliseconds: 150),
    );
    phone.api.online = false;
    await phone.library.markPlayed(episodes[0]);
    await phone.sync.whenIdle();
    expect(phone.sync.retryScheduled, isTrue);

    phone.api.online = true;
    phone.api.syncCalls.clear();
    await phone.sync.logout();
    expect(phone.api.syncCalls, ['state', 'push', 'logout']);
    expect(server.states[episodes[0]]!.isPlayed, isTrue);
    expect(phone.library.pendingCount, 0);
    expect(phone.sync.isLoggedIn, isFalse);
  });

  test('logout gives up on a slow send and keeps the pending change', () async {
    final phone = await device(
      'phone',
      logoutSendTimeout: const Duration(milliseconds: 100),
    );
    final started = Completer<void>();
    final reply = Completer<void>();
    phone.api.beforePush = () {
      started.complete();
      return reply.future;
    };
    phone.api.syncCalls.clear();
    await phone.library.markPlayed(episodes[0]);
    try {
      await started.future.timeout(const Duration(seconds: 2));
      await phone.sync.logout().timeout(const Duration(seconds: 1));
      expect(phone.api.syncCalls, ['push', 'logout']);
      expect(phone.sync.status.value.phase, SyncPhase.loggedOut);
      expect(phone.library.pendingCount, 1);
    } finally {
      reply.complete();
    }
    await settle();
    expect((await phone.store.load()).pendingStates, {episodes[0]});
    expect(phone.sync.retryScheduled, isFalse);
  });

  test('logging in to another server forgets the old local copy', () async {
    final phone = await device('phone');
    expect(phone.library.podcasts, hasLength(2));
    final other = FakeServer(clock)
      ..serverId = restoredServerId
      ..addPodcast(5, 'Quiet Hours');
    other.addEpisodes(5, 1);
    final moved = await Device.open(other, db: phone.db);
    devices.add(moved);
    await moved.sync.login(
      serverUrl: 'https://elsewhere.example.test',
      username: 'listener',
      password: 'secret',
      deviceName: 'phone',
    );
    await moved.sync.start();
    await moved.sync.whenIdle();
    expect(moved.library.podcasts.map((p) => p.title), ['Quiet Hours']);
    expect(moved.store.meta(MetaKey.serverId), restoredServerId);
  });

  test('a new identity discards offline states, queue and cached episode lists before posting', () async {
    final phone = await device('phone');
    final id = episodes.first;
    final etag = phone.store.meta(MetaKey.stateEtag);
    final listCalls = phone.api.episodesCalls[1]!;
    expect(etag, isNotEmpty);
    expect(await phone.library.description(id), 'About episode $id');

    phone.api.online = false;
    await phone.library.markPlayed(id);
    await phone.library.enqueue(episodes.last);
    await phone.sync.whenIdle();
    expect(phone.library.pendingCount, 2);

    server.serverId = restoredServerId;
    server.descriptions[id] = 'About the restored episode';
    phone.api.online = true;
    await phone.sync.syncNow();

    expect(phone.api.pushCalls, 0);
    expect(phone.library.episode(id), isNotNull);
    expect(phone.api.episodesCalls[1], listCalls + 1);
    expect(await phone.library.description(id), 'About the restored episode');
    expect(phone.library.stateOf(id).isNew, isTrue);
    expect(phone.library.queue, isEmpty);
    expect(phone.library.pendingCount, 0);
    expect(phone.store.meta(MetaKey.serverId), restoredServerId);
    expect(phone.store.meta(MetaKey.stateEtag), isNot(etag));
    final stored = await phone.store.load();
    expect(stored.states, isEmpty);
    expect(stored.queue, isNull);
    expect(stored.meta[MetaKey.serverId], restoredServerId);
    expect(phone.sync.status.value.phase, SyncPhase.idle);
  });

  test('logging in at a new URL with the same identity keeps cache and pending changes', () async {
    final phone = await device('phone');
    final id = episodes.first;
    final episode = phone.library.episode(id);
    final etag = phone.store.meta(MetaKey.stateEtag);
    phone.api.online = false;
    await phone.library.markPlayed(id);
    await phone.sync.whenIdle();
    await phone.sync.stop();

    phone.api.online = true;
    const url = 'https://elsewhere.example.test';
    await phone.sync.login(
      serverUrl: '$url/api/',
      username: 'listener',
      password: 'secret',
      deviceName: 'phone',
    );
    expect(phone.store.meta(MetaKey.serverUrl), url);
    expect(phone.store.meta(MetaKey.serverId), server.serverId);
    expect(phone.store.meta(MetaKey.stateEtag), etag);
    expect(phone.library.episode(id), same(episode));
    expect(phone.library.pendingCount, 1);
    await phone.sync.start();
    await phone.sync.whenIdle();
    expect(phone.api.stateNotModified, 1);
    expect(server.states[id]?.isPlayed, isTrue);
  });

  test('a changed identity in a push reply refreshes instead of applying the reply', () async {
    final phone = await device('phone');
    final id = episodes.first;
    final listCalls = phone.api.episodesCalls[1]!;
    var sawOldReply = false;
    phone.api.beforePush = () async => server.serverId = restoredServerId;
    phone.api.transformPushResult = (result) {
      sawOldReply = result.episodes.single.isPlayed;
      server.states.clear();
      return result;
    };

    await phone.library.markPlayed(id);
    await phone.sync.whenIdle();

    expect(sawOldReply, isTrue);
    expect(phone.store.meta(MetaKey.serverId), restoredServerId);
    expect(phone.library.episode(id), isNotNull);
    expect(phone.api.episodesCalls[1], listCalls + 1);
    expect(phone.library.stateOf(id).isNew, isTrue);
    expect(phone.library.pendingCount, 0);
  });
}
