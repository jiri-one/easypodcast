part of 'player.dart';

Future<void> _openAndroidAudio(
  EpisodePlayer player,
  Library library,
  DownloadService downloads,
  Settings settings,
) async {
  await AudioService.init(
    builder: () => _EpisodeAudioHandler(player, library, downloads, settings),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'one.jiri.easypodcast.audio',
      androidNotificationChannelName: 'EasyPodcast',
      androidStopForegroundOnPause: false,
    ),
  );
}

class _EpisodeAudioHandler extends BaseAudioHandler {
  _EpisodeAudioHandler(
    this._player,
    this._library,
    this._downloads,
    this._settings,
  ) {
    _player._mediaChanges.stream.listen(_publish);
    _publish(true);
  }

  final EpisodePlayer _player;
  final Library _library;
  final DownloadService _downloads;
  final Settings _settings;

  static const _inProgress = 'in-progress';
  static const _queue = 'queue';
  static const _downloaded = 'downloaded';
  static const _podcasts = 'podcasts';
  static const _episodePrefix = 'episode:';
  static const _podcastPrefix = 'podcast:';
  static const _rootItems = [
    MediaItem(id: _inProgress, title: 'Rozposlouchané', playable: false),
    MediaItem(id: _queue, title: 'Fronta', playable: false),
    MediaItem(id: _downloaded, title: 'Stažené', playable: false),
    MediaItem(id: _podcasts, title: 'Podcasty', playable: false),
  ];

  MediaItem _item(Episode episode, {Duration? duration}) {
    final podcast = _library.podcast(episode.podcastId);
    return MediaItem(
      id: '$_episodePrefix${episode.id}',
      title: episode.title,
      album: podcast?.title,
      artist: Platform.isLinux ? podcast?.author : null,
      duration:
          duration ??
          (episode.durationS == null
              ? null
              : Duration(seconds: episode.durationS!)),
    );
  }

  MediaItem _podcastItem(Podcast podcast) => MediaItem(
    id: '$_podcastPrefix${podcast.id}',
    title: podcast.title,
    playable: false,
  );

  int? _parseId(String value, String prefix) => value.startsWith(prefix)
      ? int.tryParse(value.substring(prefix.length))
      : null;

  @override
  Future<List<MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) async {
    switch (parentMediaId) {
      case AudioService.browsableRootId:
        return _rootItems;
      case AudioService.recentRootId:
        return _library.inProgress.take(1).map(_item).toList();
      case _inProgress:
        return _library.inProgress.map(_item).toList();
      case _queue:
        return _library.queue.map(_item).toList();
      case _downloaded:
        return _downloads.downloadedEpisodeIds
            .map(_library.episode)
            .whereType<Episode>()
            .map(_item)
            .toList();
      case _podcasts:
        return _library.podcasts.map(_podcastItem).toList();
    }
    final id = _parseId(parentMediaId, _podcastPrefix);
    return id == null ? [] : _library.episodesOf(id).map(_item).toList();
  }

  @override
  Future<MediaItem?> getMediaItem(String mediaId) async {
    for (final item in _rootItems) {
      if (item.id == mediaId) return item;
    }
    final episodeId = _parseId(mediaId, _episodePrefix);
    final episode = episodeId == null ? null : _library.episode(episodeId);
    if (episode != null) return _item(episode);
    final podcastId = _parseId(mediaId, _podcastPrefix);
    final podcast = podcastId == null ? null : _library.podcast(podcastId);
    return podcast == null ? null : _podcastItem(podcast);
  }

  @override
  Future<void> playFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async {
    final id = _parseId(mediaId, _episodePrefix);
    if (id != null) await _player.play(id);
  }

  @override
  Future<void> play() => _player.resume();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seekTo(position);

  @override
  Future<void> skipToPrevious() => rewind();

  @override
  Future<void> skipToNext() => fastForward();

  @override
  Future<void> rewind() =>
      _player.seekBy(Duration(seconds: -_settings.skipBackSeconds));

  @override
  Future<void> fastForward() =>
      _player.seekBy(Duration(seconds: _settings.skipForwardSeconds));

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> onTaskRemoved() => _player.reportBeforeBackground();

  void _publish(bool force) {
    final episode = _player.current;
    final playing = _player.isPlaying;
    final loaded = _player._loaded;
    final engine = _player._engine;
    final processing = episode == null
        ? AudioProcessingState.idle
        : !loaded
        ? AudioProcessingState.loading
        : switch (engine.processingState) {
            ProcessingState.idle => AudioProcessingState.idle,
            ProcessingState.loading => AudioProcessingState.loading,
            ProcessingState.buffering => AudioProcessingState.buffering,
            ProcessingState.ready => AudioProcessingState.ready,
            ProcessingState.completed => AudioProcessingState.completed,
          };

    final item = episode == null
        ? null
        : _item(episode, duration: _player.duration);
    final previous = mediaItem.value;
    if (item?.id != previous?.id || item?.duration != previous?.duration) {
      mediaItem.add(item);
    }
    final position = loaded ? engine.position : _player.position.value;
    final state = playbackState.value;
    if (!force &&
        item?.id == previous?.id &&
        state.processingState == processing &&
        state.playing == playing &&
        state.speed == _player.speed &&
        (state.position - position).abs() < const Duration(seconds: 1)) {
      return;
    }
    playbackState.add(
      PlaybackState(
        controls: episode == null
            ? []
            : [
                MediaControl.skipToPrevious.copyWith(label: 'Skip back'),
                playing ? MediaControl.pause : MediaControl.play,
                MediaControl.skipToNext.copyWith(label: 'Skip forward'),
                MediaControl.stop,
              ],
        androidCompactActionIndices: episode == null ? [] : [0, 1, 2],
        systemActions: loaded ? const {MediaAction.seek} : const {},
        processingState: processing,
        playing: playing,
        updatePosition: position,
        bufferedPosition: loaded ? engine.bufferedPosition : Duration.zero,
        speed: _player.speed,
      ),
    );
  }
}
