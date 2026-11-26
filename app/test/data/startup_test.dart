import 'dart:io';

import 'package:easypodcast/core/models.dart';
import 'package:easypodcast/data/local_store.dart';
import 'package:easypodcast/data/sqflite_library.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_server.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test(
    'upgrading a v1 database preserves legacy states and pending flags',
    () async {
      final directory = await Directory.systemTemp.createTemp('easypodcast-');
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/easypodcast.db';
      final legacy = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            await db.execute(
              '''CREATE TABLE episode_states (
            episode_id INTEGER PRIMARY KEY, position_ms INTEGER NOT NULL,
            status TEXT NOT NULL, updated_at INTEGER NOT NULL, pending INTEGER NOT NULL)''',
            );
            await db.execute(
              'CREATE TABLE descriptions (episode_id INTEGER PRIMARY KEY, text TEXT NOT NULL)',
            );
            await db.execute(
              'CREATE TABLE queue (id INTEGER PRIMARY KEY CHECK (id = 1), '
              'episode_ids TEXT NOT NULL, updated_at INTEGER NOT NULL, pending INTEGER NOT NULL)',
            );
            await db.execute('''CREATE TABLE episodes (
              id INTEGER PRIMARY KEY, podcast_id INTEGER NOT NULL, sort INTEGER NOT NULL,
              guid TEXT NOT NULL, title TEXT NOT NULL, enclosure_url TEXT NOT NULL,
              published_at INTEGER, duration_s INTEGER, enclosure_type TEXT,
              enclosure_length INTEGER, link TEXT, image_url TEXT,
              removed_from_feed INTEGER NOT NULL)''');
            await db.execute('''CREATE TABLE podcasts (
              id INTEGER PRIMARY KEY, feed_url TEXT NOT NULL, title TEXT NOT NULL,
              author TEXT NOT NULL, description TEXT NOT NULL, image_url TEXT, link TEXT,
              subscribed INTEGER NOT NULL, episode_count INTEGER NOT NULL,
              played_count INTEGER NOT NULL, episodes_version TEXT NOT NULL,
              last_success_at INTEGER, last_error TEXT)''');
            await LocalStore.createSchema(db);
          },
        ),
      );
      final at = DateTime.utc(2026, 11, 26);
      try {
        await legacy.insert('podcasts', {
          'id': 3,
          'feed_url': 'https://example.test/feed.xml',
          'title': 'Saved podcast',
          'author': '',
          'description': '',
          'subscribed': 1,
          'episode_count': 1,
          'played_count': 0,
          'episodes_version': 'legacy',
        });
        await legacy.insert('episodes', {
          'id': 7,
          'podcast_id': 3,
          'sort': 0,
          'guid': 'legacy',
          'title': 'Saved episode',
          'enclosure_url': 'https://example.test/7',
          'enclosure_length': 700,
          'removed_from_feed': 1,
        });
        await legacy.insert('episode_states', {
          'episode_id': 7,
          'position_ms': 61000,
          'status': '',
          'updated_at': at.millisecondsSinceEpoch,
          'pending': 1,
        });
        await legacy.insert('descriptions', {
          'episode_id': 7,
          'text': 'Saved notes',
        });
      } finally {
        await legacy.close();
      }

      final db = await LocalStore.open(databaseFactoryFfi, path);
      addTearDown(db.close);
      expect(await db.getVersion(), LocalStore.schemaVersion);
      final store = LocalStore(db);
      expect(await store.description(7), (text: 'Saved notes', version: null));
      final snapshot = await store.load();
      expect(snapshot.podcasts.single.showInNewEpisodes, isTrue);
      final episode = snapshot.episodes.single;
      expect(
        (
          episode.id,
          episode.title,
          episode.enclosureLength,
          episode.removedFromFeed,
        ),
        (7, 'Saved episode', 700, true),
      );
      final columns = await db.rawQuery('PRAGMA table_info(episodes)');
      expect(
        columns.map((row) => row['name']),
        isNot(anyElement(isIn(['guid', 'link', 'enclosure_type']))),
      );
      expect(snapshot.pendingStates, {7});
      final state = snapshot.states.single;
      expect(state.episodeId, 7);
      expect(state.positionMs, 61000);
      expect(state.status, EpisodeStatus.none);
      expect(state.updatedAt, at);
      expect(state.durationMs, isNull);

      final library = await SqfliteLibrary.open(
        store,
        FakeApiClient(FakeServer(TestClock())),
      );
      addTearDown(library.dispose);
      await library.recordPosition(
        7,
        const Duration(seconds: 63),
        duration: const Duration(minutes: 10),
      );
      final updated = await store.load();
      expect(updated.states.single.durationMs, 600000);
      expect(updated.pendingStates, {7});
    },
  );

  test('50 podcasts with 20 000 episodes open quickly', () async {
    final db = await LocalStore.open(databaseFactoryFfi, inMemoryDatabasePath);
    final store = LocalStore(db);
    final published = DateTime.utc(2020);
    await store.replacePodcasts([
      for (var p = 1; p <= 50; p++)
        Podcast(
          id: p,
          feedUrl: 'https://feeds.example.test/$p.xml',
          title: 'Show $p',
        ),
    ], {});
    final states = <EpisodeState>[];
    for (var p = 1; p <= 50; p++) {
      final episodes = [
        for (var i = 0; i < 400; i++)
          Episode(
            id: p * 1000 + i,
            podcastId: p,
            title: 'Episode $i of show $p',
            enclosureUrl: 'https://media.example.test/$p/$i.mp3',
            publishedAt: published.add(Duration(hours: i)),
            durationS: 3600,
          ),
      ];
      await store.replaceEpisodes(p, episodes, EpisodeListInfo('v$p', null));
      for (var i = 0; i < 200; i++) {
        states.add(
          EpisodeState(
            episodeId: p * 1000 + i,
            positionMs: i.isEven ? 0 : 90000,
            status: i.isEven ? EpisodeStatus.played : EpisodeStatus.none,
            updatedAt: published.add(Duration(minutes: i)),
          ),
        );
      }
    }
    await store.writeStates(states);

    final watch = Stopwatch()..start();
    final library = await SqfliteLibrary.open(
      LocalStore(db),
      FakeApiClient(FakeServer(TestClock())),
    );
    final opened = watch.elapsed;
    expect(library.podcasts, hasLength(50));
    expect(
      library.newEpisodes(since: published.add(const Duration(hours: 398))),
      hasLength(100),
    );
    expect(library.inProgress, hasLength(5000));
    expect(opened, lessThan(const Duration(seconds: 3)));
    library.dispose();
    await db.close();
  });
}
