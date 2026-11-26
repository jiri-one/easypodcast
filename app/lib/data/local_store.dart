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
    required this.meta,
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
  final Map<String, String> meta;
}

abstract final class MetaKey {
  static const token = 'token';
  static const serverUrl = 'server_url';
  static const deviceId = 'device_id';
  static const deviceName = 'device_name';
  static const podcastsEtag = 'podcasts_etag';
  static const lastSync = 'last_sync';
}

class LocalStore {
  LocalStore(this.db);

  final Database db;
  final Map<String, String> _meta = {};

  static const schemaVersion = 3;

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
      },
      singleInstance: false,
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
      ..execute('''CREATE TABLE IF NOT EXISTS episodes (
        id INTEGER PRIMARY KEY, podcast_id INTEGER NOT NULL, sort INTEGER NOT NULL,
        guid TEXT NOT NULL, title TEXT NOT NULL, enclosure_url TEXT NOT NULL,
        published_at INTEGER, duration_s INTEGER, enclosure_type TEXT,
        enclosure_length INTEGER, link TEXT, image_url TEXT,
        removed_from_feed INTEGER NOT NULL)''')
      ..execute(
        'CREATE INDEX IF NOT EXISTS episodes_podcast ON episodes (podcast_id, sort)',
      )
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
      meta: Map.of(_meta),
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

  Future<void> replacePodcasts(List<Podcast> podcasts) =>
      db.transaction((txn) async {
        final batch = txn.batch()..delete('podcasts');
        for (final p in podcasts) {
          batch.insert('podcasts', _podcastRow(p));
        }
        final ids = podcasts.map((p) => p.id).join(',');
        batch
          ..delete('episodes', where: 'podcast_id NOT IN ($ids)')
          ..delete('episode_lists', where: 'podcast_id NOT IN ($ids)');
        await batch.commit(noResult: true);
      });

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
    Iterable<(EpisodeState, bool)> states, {
    (QueueState, bool)? queue,
    Map<int?, DateTime> clockRejections = const {},
    Map<int, EpisodeState> acknowledgedStates = const {},
    QueueState? acknowledgedQueue,
  }) => db.transaction((txn) async {
    final batch = txn.batch();
    for (final (state, pending) in states) {
      final row = {
        'episode_id': state.episodeId,
        'position_ms': state.positionMs,
        'status': state.status.json,
        'duration_ms': state.durationMs,
        'updated_at': state.updatedAt.millisecondsSinceEpoch,
        'pending': pending ? 1 : 0,
        'clock_rejected':
            pending && clockRejections[state.episodeId] == state.updatedAt
            ? 1
            : 0,
      };
      final sent = acknowledgedStates[state.episodeId];
      if (pending) {
        batch.insert(
          'episode_states',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      } else if (sent == null) {
        batch.update(
          'episode_states',
          row,
          where: 'episode_id = ? AND updated_at < ?',
          whereArgs: [state.episodeId, state.updatedAt.millisecondsSinceEpoch],
        );
        batch.insert(
          'episode_states',
          row,
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      } else {
        final match = _pendingState(sent);
        batch.update(
          'episode_states',
          row,
          where: match.where,
          whereArgs: match.args,
        );
      }
    }
    if (queue != null) {
      final (q, pending) = queue;
      final row = {
        'id': 1,
        'episode_ids': jsonEncode(q.episodeIds),
        'updated_at': q.updatedAt.millisecondsSinceEpoch,
        'pending': pending ? 1 : 0,
        'clock_rejected': pending && clockRejections[null] == q.updatedAt
            ? 1
            : 0,
      };
      if (pending) {
        batch.insert(
          'queue',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      } else if (acknowledgedQueue == null) {
        batch.update(
          'queue',
          row,
          where: 'id = 1 AND updated_at < ?',
          whereArgs: [q.updatedAt.millisecondsSinceEpoch],
        );
        batch.insert('queue', row, conflictAlgorithm: ConflictAlgorithm.ignore);
      } else {
        final match = _pendingQueue(acknowledgedQueue);
        batch.update('queue', row, where: match.where, whereArgs: match.args);
      }
    }
    await batch.commit(noResult: true);
  });

  static ({String where, List<Object?> args}) _pendingState(
    EpisodeState sent,
  ) => (
    where:
        'pending = 1 AND episode_id = ? AND updated_at = ? '
        'AND position_ms = ? AND status = ? AND duration_ms '
        '${sent.durationMs == null ? 'IS NULL' : '= ?'}',
    args: [
      sent.episodeId,
      sent.updatedAt.millisecondsSinceEpoch,
      sent.positionMs,
      sent.status.json,
      ?sent.durationMs,
    ],
  );

  static ({String where, List<Object?> args}) _pendingQueue(QueueState sent) =>
      (
        where: 'id = 1 AND pending = 1 AND updated_at = ? AND episode_ids = ?',
        args: [
          sent.updatedAt.millisecondsSinceEpoch,
          jsonEncode(sent.episodeIds),
        ],
      );

  Future<bool> updateRejectedTime(
    EpisodeState? state,
    QueueState? queue,
    DateTime? correctedTime,
  ) async {
    final match = state == null ? _pendingQueue(queue!) : _pendingState(state);
    final updated = await db.update(
      state == null ? 'queue' : 'episode_states',
      {
        'clock_rejected': correctedTime == null ? 1 : 0,
        if (correctedTime != null)
          'updated_at': correctedTime.millisecondsSinceEpoch,
      },
      where: match.where,
      whereArgs: match.args,
    );
    return updated == 1;
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

  Future<void> clearLibrary() => db.transaction((txn) async {
    final batch = txn.batch();
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
    batch.delete('meta', where: 'key = ?', whereArgs: [MetaKey.podcastsEtag]);
    await batch.commit(noResult: true);
    _meta.remove(MetaKey.podcastsEtag);
  });

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
    guid: row['guid'] as String,
    title: row['title'] as String,
    enclosureUrl: row['enclosure_url'] as String,
    publishedAt: _fromMsOrNull(row['published_at']),
    durationS: row['duration_s'] as int?,
    enclosureType: row['enclosure_type'] as String?,
    enclosureLength: row['enclosure_length'] as int?,
    link: row['link'] as String?,
    imageUrl: row['image_url'] as String?,
    removedFromFeed: row['removed_from_feed'] == 1,
  );

  static Map<String, Object?> _episodeRow(Episode e, int sort) => {
    'id': e.id,
    'podcast_id': e.podcastId,
    'sort': sort,
    'guid': e.guid,
    'title': e.title,
    'enclosure_url': e.enclosureUrl,
    'published_at': e.publishedAt?.millisecondsSinceEpoch,
    'duration_s': e.durationS,
    'enclosure_type': e.enclosureType,
    'enclosure_length': e.enclosureLength,
    'link': e.link,
    'image_url': e.imageUrl,
    'removed_from_feed': e.removedFromFeed ? 1 : 0,
  };
}
