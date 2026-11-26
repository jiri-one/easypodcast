import 'package:easypodcast/core/models.dart';
import 'package:easypodcast/data/local_store.dart';
import 'package:easypodcast/data/sqflite_library.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_server.dart';

void main() {
  setUpAll(sqfliteFfiInit);

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
    ]);
    final states = <(EpisodeState, bool)>[];
    for (var p = 1; p <= 50; p++) {
      final episodes = [
        for (var i = 0; i < 400; i++)
          Episode(
            id: p * 1000 + i,
            podcastId: p,
            guid: 'guid-$p-$i',
            title: 'Episode $i of show $p',
            enclosureUrl: 'https://media.example.test/$p/$i.mp3',
            publishedAt: published.add(Duration(hours: i)),
            durationS: 3600,
          ),
      ];
      await store.replaceEpisodes(p, episodes, EpisodeListInfo('v$p', null));
      for (var i = 0; i < 200; i++) {
        states.add((
          EpisodeState(
            episodeId: p * 1000 + i,
            positionMs: i.isEven ? 0 : 90000,
            status: i.isEven ? EpisodeStatus.played : EpisodeStatus.none,
            updatedAt: published.add(Duration(minutes: i)),
          ),
          false,
        ));
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
    expect(library.newEpisodes(), hasLength(100));
    expect(library.inProgress, hasLength(5000));
    expect(opened, lessThan(const Duration(seconds: 3)));
    library.dispose();
    await db.close();
  });
}
