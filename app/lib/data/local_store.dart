import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../core/models.dart';

class EpisodeListInfo {
  const EpisodeListInfo(this.version, this.etag);

  final String version;
  final String? etag;
}

class LocalSnapshot {
  LocalSnapshot({
    required this.podcasts,
    required this.episodes,
    required this.states,
    required this.pendingStates,
    required this.clockRejections,
    required this.queue,
    required this.queuePending,
    required this.episodeLists,
  });

  final List<Podcast> podcasts;

  /// In server order (newest first) within each podcast.
  final List<Episode> episodes;
  final List<EpisodeState> states;
  final Set<int> pendingStates;
  final Map<int?, DateTime> clockRejections;
  final QueueState? queue;
  final bool queuePending;
  final Map<int, EpisodeListInfo> episodeLists;
}

abstract final class MetaKey {
  static const token = 'token';
  static const serverUrl = 'server_url';
  static const serverId = 'server_id';
  static const deviceName = 'device_name';
  static const podcastsEtag = 'podcasts_etag';
  static const stateEtag = 'state_etag';
  static const lastSync = 'last_sync';
}

class LocalStore {
  LocalStore(this.db);

  final Database db;
  final Map<String, String> _meta = {};

  static const schemaVersion = 4;
  static const _episodesTable = '''CREATE TABLE IF NOT EXISTS episodes (
    id INTEGER PRIMARY KEY, podcast_id INTEGER NOT NULL, sort INTEGER NOT NULL,
    title TEXT NOT NULL, enclosure_url TEXT NOT NULL, published_at INTEGER,
    duration_s INTEGER, enclosure_length INTEGER, image_url TEXT,
    removed_from_feed INTEGER NOT NULL)''';
  static const _episodesIndex =
      'CREATE INDEX IF NOT EXISTS episodes_podcast ON episodes (podcast_id, sort)';

  static Future<Database> open(
    DatabaseFactory factory,
    String path,
  ) => factory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: schemaVersion,
      onCreate: (db, _) => createSchema(db),
      onUpgrade: (db, oldVersion, _) async {
        if (oldVersion < 2) {
          await db.execute(
            'ALTER TABLE episode_states ADD COLUMN duration_ms INTEGER',
          );
        }
        if (oldVersion < 3) {
          await db.execute(
            'ALTER TABLE descriptions ADD COLUMN episodes_version TEXT',
          );
          for (final table in ['episode_states', 'queue']) {
            await db.execute(
              'ALTER TABLE $table ADD COLUMN clock_rejected INTEGER NOT NULL DEFAULT 0',
            );
          }
        }
        if (oldVersion < 4) {
          await db.execute('ALTER TABLE episodes RENAME TO episodes_v3');
          await db.execute(_episodesTable);
          await db.execute(
            'INSERT INTO episodes SELECT id, podcast_id, sort, title, enclosure_url, '
            'published_at, duration_s, enclosure_length, image_url, removed_from_feed FROM episodes_v3',
          );
          await db.execute('DROP TABLE episodes_v3');
          await db.execute(_episodesIndex);
          await db.delete('meta', where: "key = 'device_id'");
        }
      },
    ),
  );

  static Future<void> createSchema(Database db) async {
    final batch = db.batch()
      ..execute('''CREATE TABLE IF NOT EXISTS podcasts (
        id INTEGER PRIMARY KEY, feed_url TEXT NOT NULL, title TEXT NOT NULL,
        author TEXT NOT NULL, description TEXT NOT NULL, image_url TEXT, link TEXT,
        subscribed INTEGER NOT NULL, episode_count INTEGER NOT NULL,
        played_count INTEGER NOT NULL, episodes_version TEXT NOT NULL,
        last_success_at INTEGER, last_error TEXT)''')
      ..execute(_episodesTable)
      ..execute(_episodesIndex)
      ..execute('''CREATE TABLE IF NOT EXISTS episode_states (
        episode_id INTEGER PRIMARY KEY, position_ms INTEGER NOT NULL,
        status TEXT NOT NULL, duration_ms INTEGER, updated_at INTEGER NOT NULL,
        pending INTEGER NOT NULL, clock_rejected INTEGER NOT NULL DEFAULT 0)''')
      ..execute('''CREATE TABLE IF NOT EXISTS queue (
        id INTEGER PRIMARY KEY CHECK (id = 1), episode_ids TEXT NOT NULL,
        updated_at INTEGER NOT NULL, pending INTEGER NOT NULL,
        clock_rejected INTEGER NOT NULL DEFAULT 0)''')
      ..execute(
        '''CREATE TABLE IF NOT EXISTS descriptions (
        episode_id INTEGER PRIMARY KEY, text TEXT NOT NULL, episodes_version TEXT)''',
      )
      ..execute(
        '''CREATE TABLE IF NOT EXISTS episode_lists (
        podcast_id INTEGER PRIMARY KEY, episodes_version TEXT NOT NULL, etag TEXT)''',
      )
      ..execute(
        'CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
      );
    await batch.commit(noResult: true);
  }

  Future<LocalSnapshot> load() async {
    final podcastRows = await db.query('podcasts');
    final episodeRows = await db.query('episodes', orderBy: 'podcast_id, sort');
    final stateRows = await db.query('episode_states');
    final queueRows = await db.query('queue');
    final listRows = await db.query('episode_lists');
    final metaRows = await db.query('meta');

    _meta
      ..clear()
      ..addAll({
        for (final row in metaRows)
          row['key'] as String: row['value'] as String,
      });
    final pending = <int>{};
    final clockRejections = <int?, DateTime>{};
    final states = <EpisodeState>[];
    for (final row in stateRows) {
      final id = row['episode_id'] as int;
      final updatedAt = _fromMs(row['updated_at'] as int);
      states.add(
        EpisodeState(
          episodeId: id,
          positionMs: row['position_ms'] as int,
          status: EpisodeStatus.fromJson(row['status'] as String),
          durationMs: row['duration_ms'] as int?,
          updatedAt: updatedAt,
        ),
      );
      if (row['pending'] == 1) {
        pending.add(id);
        if (row['clock_rejected'] == 1) clockRejections[id] = updatedAt;
      }
    }
    final queueRow = queueRows.isEmpty ? null : queueRows.first;
    if (queueRow != null &&
        queueRow['pending'] == 1 &&
        queueRow['clock_rejected'] == 1) {
      clockRejections[null] = _fromMs(queueRow['updated_at'] as int);
    }
    return LocalSnapshot(
      podcasts: [for (final row in podcastRows) _podcast(row)],
      episodes: [for (final row in episodeRows) _episode(row)],
      states: states,
      pendingStates: pending,
      clockRejections: clockRejections,
      queue: queueRow == null
          ? null
          : QueueState(
              episodeIds: [
                for (final id
                    in jsonDecode(queueRow['episode_ids'] as String) as List)
                  id as int,
              ],
              updatedAt: _fromMs(queueRow['updated_at'] as int),
            ),
      queuePending: queueRow?['pending'] == 1,
      episodeLists: {
        for (final row in listRows)
          row['podcast_id'] as int: EpisodeListInfo(
            row['episodes_version'] as String,
            row['etag'] as String?,
          ),
      },
    );
  }

  String? meta(String key) => _meta[key];

  Future<void> setMeta(String key, String? value) async {
    if (value == null) {
      _meta.remove(key);
      await db.delete('meta', where: 'key = ?', whereArgs: [key]);
    } else {
      _meta[key] = value;
      await db.insert('meta', {
        'key': key,
        'value': value,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  Future<void> replacePodcasts(List<Podcast> podcasts, Set<int> removed) async {
    final batch = db.batch();
    if (removed.isNotEmpty) {
      final ids = removed.join(',');
      batch
        ..delete('podcasts', where: 'id IN ($ids)')
        ..delete('episodes', where: 'podcast_id IN ($ids)')
        ..delete('episode_lists', where: 'podcast_id IN ($ids)');
    }
    for (final p in podcasts) {
      batch.insert(
        'podcasts',
        _podcastRow(p),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> upsertPodcast(Podcast podcast) => db.insert(
    'podcasts',
    _podcastRow(podcast),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  Future<void> replaceEpisodes(
    int podcastId,
    List<Episode> episodes,
    EpisodeListInfo info,
  ) => db.transaction((txn) async {
    final batch = txn.batch()
      ..delete('episodes', where: 'podcast_id = ?', whereArgs: [podcastId]);
    for (var i = 0; i < episodes.length; i++) {
      batch.insert(
        'episodes',
        _episodeRow(episodes[i], i),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    batch.insert('episode_lists', {
      'podcast_id': podcastId,
      'episodes_version': info.version,
      'etag': info.etag,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await batch.commit(noResult: true);
  });

  Future<void> setEpisodeListInfo(int podcastId, EpisodeListInfo info) =>
      db.insert('episode_lists', {
        'podcast_id': podcastId,
        'episodes_version': info.version,
        'etag': info.etag,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> writeStates(
    Iterable<EpisodeState> states, {
    QueueState? queue,
    Set<int?> pending = const {},
    Map<int?, DateTime> clockRejections = const {},
    DateTime? lastSync,
  }) async {
    final batch = db.batch();
    void write(String table, Map<String, Object?> row, int? id, DateTime at) {
      batch.insert(table, {
        ...row,
        'updated_at': at.millisecondsSinceEpoch,
        'pending': pending.contains(id) ? 1 : 0,
        'clock_rejected': clockRejections[id] == at ? 1 : 0,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }

    for (final state in states) {
      write(
        'episode_states',
        {
          'episode_id': state.episodeId,
          'position_ms': state.positionMs,
          'status': state.status.json,
          'duration_ms': state.durationMs,
        },
        state.episodeId,
        state.updatedAt,
      );
    }
    if (queue != null) {
      write(
        'queue',
        {'id': 1, 'episode_ids': jsonEncode(queue.episodeIds)},
        null,
        queue.updatedAt,
      );
    }
    if (lastSync != null) {
      batch.insert('meta', {
        'key': MetaKey.lastSync,
        'value': formatTime(lastSync),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
    if (lastSync != null) _meta[MetaKey.lastSync] = formatTime(lastSync);
  }

  Future<({String text, String? version})?> description(int episodeId) async {
    final rows = await db.query(
      'descriptions',
      where: 'episode_id = ?',
      whereArgs: [episodeId],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return (
      text: row['text'] as String,
      version: row['episodes_version'] as String?,
    );
  }

  Future<void> setDescription(
    int episodeId,
    String text,
    String? version, {
    required bool replace,
  }) => db.insert(
    'descriptions',
    {'episode_id': episodeId, 'text': text, 'episodes_version': version},
    conflictAlgorithm: replace
        ? ConflictAlgorithm.replace
        : ConflictAlgorithm.ignore,
  );

  Future<void> clearLibrary(String serverId) async {
    const keys = [MetaKey.podcastsEtag, MetaKey.stateEtag, MetaKey.lastSync];
    final batch = db.batch();
    for (final table in const [
      'podcasts',
      'episodes',
      'episode_states',
      'queue',
      'descriptions',
      'episode_lists',
    ]) {
      batch.delete(table);
    }
    for (final key in keys) {
      batch.delete('meta', where: 'key = ?', whereArgs: [key]);
    }
    batch.insert('meta', {
      'key': MetaKey.serverId,
      'value': serverId,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await batch.commit(noResult: true);
    keys.forEach(_meta.remove);
    _meta[MetaKey.serverId] = serverId;
  }

  static DateTime _fromMs(int ms) =>
      DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);

  static DateTime? _fromMsOrNull(Object? ms) =>
      ms == null ? null : _fromMs(ms as int);

  static Podcast _podcast(Map<String, Object?> row) => Podcast(
    id: row['id'] as int,
    feedUrl: row['feed_url'] as String,
    title: row['title'] as String,
    author: row['author'] as String,
    description: row['description'] as String,
    imageUrl: row['image_url'] as String?,
    link: row['link'] as String?,
    subscribed: row['subscribed'] == 1,
    episodeCount: row['episode_count'] as int,
    playedCount: row['played_count'] as int,
    episodesVersion: row['episodes_version'] as String,
    lastSuccessAt: _fromMsOrNull(row['last_success_at']),
    lastError: row['last_error'] as String?,
  );

  static Map<String, Object?> _podcastRow(Podcast p) => {
    'id': p.id,
    'feed_url': p.feedUrl,
    'title': p.title,
    'author': p.author,
    'description': p.description,
    'image_url': p.imageUrl,
    'link': p.link,
    'subscribed': p.subscribed ? 1 : 0,
    'episode_count': p.episodeCount,
    'played_count': p.playedCount,
    'episodes_version': p.episodesVersion,
    'last_success_at': p.lastSuccessAt?.millisecondsSinceEpoch,
    'last_error': p.lastError,
  };

  static Episode _episode(Map<String, Object?> row) => Episode(
    id: row['id'] as int,
    podcastId: row['podcast_id'] as int,
    title: row['title'] as String,
    enclosureUrl: row['enclosure_url'] as String,
    publishedAt: _fromMsOrNull(row['published_at']),
    durationS: row['duration_s'] as int?,
    enclosureLength: row['enclosure_length'] as int?,
    imageUrl: row['image_url'] as String?,
    removedFromFeed: row['removed_from_feed'] == 1,
  );

  static Map<String, Object?> _episodeRow(Episode e, int sort) => {
    'id': e.id,
    'podcast_id': e.podcastId,
    'sort': sort,
    'title': e.title,
    'enclosure_url': e.enclosureUrl,
    'published_at': e.publishedAt?.millisecondsSinceEpoch,
    'duration_s': e.durationS,
    'enclosure_length': e.enclosureLength,
    'image_url': e.imageUrl,
    'removed_from_feed': e.removedFromFeed ? 1 : 0,
  };
}
