const inProgressThresholdMs = 60000;

DateTime? _time(Object? value) =>
    value == null ? null : DateTime.parse(value as String).toUtc();

/// Millisecond precision keeps the device's order identical after a round trip through the API.
String formatTime(DateTime time) =>
    DateTime.fromMillisecondsSinceEpoch(time.millisecondsSinceEpoch, isUtc: true)
        .toIso8601String();

DateTime nowUtc() => DateTime.fromMillisecondsSinceEpoch(
    DateTime.now().millisecondsSinceEpoch,
    isUtc: true);

final DateTime oldestTime = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

enum EpisodeStatus {
  none(''),
  played('played'),
  dismissed('dismissed');

  const EpisodeStatus(this.json);
  final String json;

  static EpisodeStatus fromJson(String value) =>
      values.firstWhere((s) => s.json == value, orElse: () => none);
}

class Podcast {
  const Podcast({
    required this.id,
    required this.feedUrl,
    required this.title,
    this.author = '',
    this.description = '',
    this.imageUrl,
    this.link,
    this.subscribed = true,
    this.episodeCount = 0,
    this.playedCount = 0,
    this.episodesVersion = '',
    this.lastSuccessAt,
    this.lastError,
  });

  final int id;
  final String feedUrl;
  final String title;
  final String author;
  final String description;
  final String? imageUrl;
  final String? link;
  final bool subscribed;
  final int episodeCount;
  final int playedCount;
  final String episodesVersion;
  final DateTime? lastSuccessAt;
  final String? lastError;

  factory Podcast.fromJson(Map<String, Object?> json) => Podcast(
        id: json['id'] as int,
        feedUrl: json['feed_url'] as String,
        title: json['title'] as String? ?? '',
        author: json['author'] as String? ?? '',
        description: json['description'] as String? ?? '',
        imageUrl: json['image_url'] as String?,
        link: json['link'] as String?,
        subscribed: json['subscribed'] as bool? ?? false,
        episodeCount: json['episode_count'] as int? ?? 0,
        playedCount: json['played_count'] as int? ?? 0,
        episodesVersion: json['episodes_version'] as String? ?? '',
        lastSuccessAt: _time(json['last_success_at']),
        lastError: json['last_error'] as String?,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'feed_url': feedUrl,
        'title': title,
        'author': author,
        'description': description,
        'image_url': imageUrl,
        'link': link,
        'subscribed': subscribed,
        'episode_count': episodeCount,
        'played_count': playedCount,
        'episodes_version': episodesVersion,
        'last_success_at': lastSuccessAt == null ? null : formatTime(lastSuccessAt!),
        'last_error': lastError,
      };
}

class Episode {
  const Episode({
    required this.id,
    required this.podcastId,
    required this.guid,
    required this.title,
    required this.enclosureUrl,
    this.publishedAt,
    this.durationS,
    this.enclosureType,
    this.enclosureLength,
    this.link,
    this.imageUrl,
    this.removedFromFeed = false,
  });

  final int id;
  final int podcastId;
  final String guid;
  final String title;
  final String enclosureUrl;
  final DateTime? publishedAt;

  /// From the feed and often wrong; the player's duration wins once known.
  final int? durationS;
  final String? enclosureType;
  final int? enclosureLength;
  final String? link;
  final String? imageUrl;
  final bool removedFromFeed;

  factory Episode.fromJson(Map<String, Object?> json) => Episode(
        id: json['id'] as int,
        podcastId: json['podcast_id'] as int,
        guid: json['guid'] as String? ?? '',
        title: json['title'] as String? ?? '',
        enclosureUrl: json['enclosure_url'] as String,
        publishedAt: _time(json['published_at']),
        durationS: json['duration_s'] as int?,
        enclosureType: json['enclosure_type'] as String?,
        enclosureLength: json['enclosure_length'] as int?,
        link: json['link'] as String?,
        imageUrl: json['image_url'] as String?,
        removedFromFeed: json['removed_from_feed'] as bool? ?? false,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'podcast_id': podcastId,
        'guid': guid,
        'title': title,
        'enclosure_url': enclosureUrl,
        'published_at': publishedAt == null ? null : formatTime(publishedAt!),
        'duration_s': durationS,
        'enclosure_type': enclosureType,
        'enclosure_length': enclosureLength,
        'link': link,
        'image_url': imageUrl,
        'removed_from_feed': removedFromFeed,
      };
}

class EpisodeState {
  const EpisodeState({
    required this.episodeId,
    required this.positionMs,
    required this.status,
    required this.updatedAt,
  });

  /// What an episode without any stored state behaves like.
  EpisodeState.initial(this.episodeId)
      : positionMs = 0,
        status = EpisodeStatus.none,
        updatedAt = oldestTime;

  final int episodeId;
  final int positionMs;
  final EpisodeStatus status;
  final DateTime updatedAt;

  bool get isInProgress =>
      status == EpisodeStatus.none && positionMs >= inProgressThresholdMs;
  bool get isNew =>
      status == EpisodeStatus.none && positionMs < inProgressThresholdMs;
  bool get isPlayed => status == EpisodeStatus.played;
  bool get isDismissed => status == EpisodeStatus.dismissed;

  /// Equal times keep the stored record, the same rule the server applies.
  bool isNewerThan(EpisodeState other) => updatedAt.isAfter(other.updatedAt);

  factory EpisodeState.fromJson(Map<String, Object?> json) => EpisodeState(
        episodeId: json['episode_id'] as int,
        positionMs: json['position_ms'] as int? ?? 0,
        status: EpisodeStatus.fromJson(json['status'] as String? ?? ''),
        updatedAt: _time(json['updated_at'])!,
      );

  Map<String, Object?> toJson() => {
        'episode_id': episodeId,
        'position_ms': positionMs,
        'status': status.json,
        'updated_at': formatTime(updatedAt),
      };
}

class QueueState {
  const QueueState({required this.episodeIds, required this.updatedAt});

  final List<int> episodeIds;
  final DateTime updatedAt;

  bool isNewerThan(QueueState? other) =>
      other == null || updatedAt.isAfter(other.updatedAt);

  factory QueueState.fromJson(Map<String, Object?> json) => QueueState(
        episodeIds: [for (final id in json['episode_ids'] as List) id as int],
        updatedAt: _time(json['updated_at'])!,
      );

  Map<String, Object?> toJson() => {
        'episode_ids': episodeIds,
        'updated_at': formatTime(updatedAt),
      };
}
