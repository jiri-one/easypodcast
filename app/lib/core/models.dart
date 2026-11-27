const inProgressThresholdMs = 60000;

// Positions this close count as the same: the library does not store them.
const samePositionTolerance = Duration(seconds: 1);

DateTime? _time(Object? value) =>
    value == null ? null : DateTime.parse(value as String).toUtc();

/// Millisecond precision keeps the device's order identical after a round trip through the API.
String formatTime(DateTime time) => DateTime.fromMillisecondsSinceEpoch(
  time.millisecondsSinceEpoch,
  isUtc: true,
).toIso8601String();

DateTime nowUtc() => DateTime.fromMillisecondsSinceEpoch(
  DateTime.now().millisecondsSinceEpoch,
  isUtc: true,
);

DateTime stampAfter(DateTime previous, DateTime now) =>
    now.isAfter(previous) ? now : previous.add(const Duration(milliseconds: 1));

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
    this.showInNewEpisodes = true,
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
  final bool showInNewEpisodes;
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
    showInNewEpisodes: json['show_in_new_episodes'] as bool? ?? true,
    episodeCount: json['episode_count'] as int? ?? 0,
    playedCount: json['played_count'] as int? ?? 0,
    episodesVersion: json['episodes_version'] as String? ?? '',
    lastSuccessAt: _time(json['last_success_at']),
    lastError: json['last_error'] as String?,
  );

  Podcast copyWith({
    String? title,
    bool? subscribed,
    bool? showInNewEpisodes,
    int? episodeCount,
    int? playedCount,
    String? episodesVersion,
    DateTime? lastSuccessAt,
  }) => Podcast(
    id: id,
    feedUrl: feedUrl,
    title: title ?? this.title,
    author: author,
    description: description,
    imageUrl: imageUrl,
    link: link,
    subscribed: subscribed ?? this.subscribed,
    showInNewEpisodes: showInNewEpisodes ?? this.showInNewEpisodes,
    episodeCount: episodeCount ?? this.episodeCount,
    playedCount: playedCount ?? this.playedCount,
    episodesVersion: episodesVersion ?? this.episodesVersion,
    lastSuccessAt: lastSuccessAt ?? this.lastSuccessAt,
    lastError: lastSuccessAt == null ? lastError : null,
  );
}

class Episode {
  const Episode({
    required this.id,
    required this.podcastId,
    required this.title,
    required this.enclosureUrl,
    this.publishedAt,
    this.durationS,
    this.enclosureLength,
    this.imageUrl,
    this.removedFromFeed = false,
  });

  final int id;
  final int podcastId;
  final String title;
  final String enclosureUrl;
  final DateTime? publishedAt;

  /// From the feed and often wrong; the player's duration wins once known.
  final int? durationS;
  final int? enclosureLength;
  final String? imageUrl;
  final bool removedFromFeed;

  factory Episode.fromJson(Map<String, Object?> json) => Episode(
    id: json['id'] as int,
    podcastId: json['podcast_id'] as int,
    title: json['title'] as String? ?? '',
    enclosureUrl: json['enclosure_url'] as String,
    publishedAt: _time(json['published_at']),
    durationS: json['duration_s'] as int?,
    enclosureLength: json['enclosure_length'] as int?,
    imageUrl: json['image_url'] as String?,
    removedFromFeed: json['removed_from_feed'] as bool? ?? false,
  );

  Duration? get feedDuration => durationS != null && durationS! > 0
      ? Duration(seconds: durationS!)
      : null;
}

Duration? episodeDuration(Episode episode, EpisodeState state) {
  final measured = state.durationMs;
  return measured != null && measured > 0
      ? Duration(milliseconds: measured)
      : episode.feedDuration;
}

double playedFraction(Duration elapsed, Duration? duration) =>
    duration == null || duration <= Duration.zero
    ? 0
    : (elapsed.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);

class EpisodeState {
  const EpisodeState({
    required this.episodeId,
    required this.positionMs,
    required this.status,
    required this.updatedAt,
    this.durationMs,
  });

  /// What an episode without any stored state behaves like.
  EpisodeState.initial(this.episodeId)
    : positionMs = 0,
      status = EpisodeStatus.none,
      durationMs = null,
      updatedAt = oldestTime;

  final int episodeId;
  final int positionMs;
  final EpisodeStatus status;
  final int? durationMs;
  final DateTime updatedAt;

  bool get isInProgress =>
      status == EpisodeStatus.none && positionMs >= inProgressThresholdMs;
  bool get isNew =>
      status == EpisodeStatus.none && positionMs < inProgressThresholdMs;
  bool get isFinished => status != EpisodeStatus.none;
  Duration get resumePosition =>
      isFinished ? Duration.zero : Duration(milliseconds: positionMs);
  bool get isPlayed => status == EpisodeStatus.played;
  bool get isDismissed => status == EpisodeStatus.dismissed;

  /// Equal times keep the stored record, the same rule the server applies.
  bool isNewerThan(EpisodeState other) => updatedAt.isAfter(other.updatedAt);

  factory EpisodeState.fromJson(Map<String, Object?> json) => EpisodeState(
    episodeId: json['episode_id'] as int,
    positionMs: json['position_ms'] as int? ?? 0,
    status: EpisodeStatus.fromJson(json['status'] as String? ?? ''),
    durationMs: json['duration_ms'] as int?,
    updatedAt: _time(json['updated_at'])!,
  );

  Map<String, Object?> toJson() => {
    'episode_id': episodeId,
    'position_ms': positionMs,
    'status': status.json,
    'duration_ms': durationMs,
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
