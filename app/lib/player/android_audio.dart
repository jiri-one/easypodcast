part of 'player.dart';

Future<void> _openAndroidAudio(
  EpisodePlayer player,
  Library library,
  DownloadService downloads,
  Settings settings,
) async {
  await AudioService.init(
    builder: () => EpisodeAudioHandler(
      player,
      library,
      downloads,
      settings,
      android: true,
    ),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'one.jiri.easypodcast.audio',
      androidNotificationChannelName: 'EasyPodcast',
      androidNotificationIcon: 'drawable/ic_stat_easypodcast',
      androidStopForegroundOnPause: false,
    ),
  );
}

class EpisodeAudioHandler extends BaseAudioHandler {
  EpisodeAudioHandler(
    this._player,
    this._library,
    this._downloads,
    this._settings, {
    required this._android,
    String Function()? languageCode,
  }) : _languageCode = languageCode ?? _deviceLanguage {
    _player._mediaChanges.stream.listen(
      (change) {
        _publish(change.force);
        if (change.pauseReport case final pausedAt? when _android) {
          _background(_finishPauseReport(pausedAt));
        }
      },
      onDone: () {
        if (!_android) return;
        _library.removeListener(_notifyChildrenChanged);
        _downloads.removeListener(_notifyChildrenChanged);
        unawaited(_childrenChanged.close());
      },
    );
    if (_android) {
      _library.addListener(_notifyChildrenChanged);
      _downloads.addListener(_notifyChildrenChanged);
    }
    if (!_android) _player.position.addListener(() => _publish(true));
    _publish(true);
  }

  final EpisodePlayer _player;
  final Library _library;
  final DownloadService _downloads;
  final Settings _settings;
  final bool _android;
  final String Function() _languageCode;
  final _childrenChanged = BehaviorSubject<Map<String, dynamic>>();
  Future<void>? _libraryRefresh;
  int? _preparedEpisodeId;

  static String _deviceLanguage() =>
      WidgetsBinding.instance.platformDispatcher.locale.languageCode;

  bool get _czech => _languageCode() == 'cs';

  static const _inProgress = 'in-progress';
  static const _queue = 'queue';
  static const _downloaded = 'downloaded';
  static const _podcasts = 'podcasts';
  static const _episodePrefix = 'episode:';
  static const _podcastPrefix = 'podcast:';
  List<MediaItem> get _rootItems => [
    MediaItem(
      id: _inProgress,
      title: _czech ? 'Rozposlouchané' : 'In progress',
      playable: false,
    ),
    MediaItem(id: _queue, title: _czech ? 'Fronta' : 'Queue', playable: false),
    MediaItem(
      id: _downloaded,
      title: _czech ? 'Stažené' : 'Downloads',
      playable: false,
    ),
    MediaItem(
      id: _podcasts,
      title: _czech ? 'Podcasty' : 'Podcasts',
      playable: false,
    ),
  ];

  MediaItem _item(Episode episode, {Duration? duration}) {
    final podcast = _library.podcast(episode.podcastId);
    return MediaItem(
      id: '$_episodePrefix${episode.id}',
      title: episode.title,
      album: podcast?.title,
      artist: _android ? null : podcast?.author,
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
        if (_android) _background(_refreshLibrary());
        return _rootItems;
      case AudioService.recentRootId:
        if (_android && _libraryRefresh != null) await _refreshLibrary();
        final head = _library.queueHeadId;
        final recent =
            _library.recentUnfinishedEpisode ??
            (head == null ? null : await _library.resolveQueueEpisode(head));
        return recent == null ? [] : [_item(recent)];
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
    return id == null
        ? []
        : _library
              .episodesOf(id)
              .where((episode) => _player._isUnfinished(episode.id))
              .map(_item)
              .toList();
  }

  @override
  ValueStream<Map<String, dynamic>> subscribeToChildren(String parentMediaId) {
    if (!_android || parentMediaId == AudioService.browsableRootId) {
      return super.subscribeToChildren(parentMediaId);
    }
    if (parentMediaId == AudioService.recentRootId) {
      _background(_refreshLibrary());
    }
    return _childrenChanged;
  }

  void _notifyChildrenChanged() => _childrenChanged.add(const {});

  Future<void> _finishPauseReport(DateTime pausedAt) async {
    await _player._waitForPendingSend(const Duration(seconds: 5));
    if (!_player._disposed && identical(_player._pausedAt, pausedAt)) {
      await androidPlatform.invokeMethod<void>('pauseReportFinished');
    }
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
    _preparedEpisodeId = null;
    final id = _parseId(mediaId, _episodePrefix);
    if (id != null) await _playRequest(() => _player.play(id));
  }

  @override
  Future<void> prepareFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async {
    _preparedEpisodeId = _parseId(mediaId, _episodePrefix);
  }

  @override
  Future<void> playFromSearch(
    String query, [
    Map<String, dynamic>? extras,
  ]) async {
    _preparedEpisodeId = null;
    final title = _searchKey(query);
    if (title.isEmpty) {
      await play();
      return;
    }
    final titles = [
      for (final podcast in _library.podcasts)
        (id: podcast.id, title: _searchKey(podcast.title)),
    ];
    final words = title.split(' ');
    final match =
        titles.where((item) => item.title == title).firstOrNull ??
        titles
            .where((item) => words.every(item.title.split(' ').contains))
            .firstOrNull;
    if (match != null) {
      await _playRequest(() => _player.playFromPodcast(match.id));
    }
  }

  String _searchKey(String title) {
    var key = title.toLowerCase();
    for (final letters in const [
      'aáàâäãå',
      'cčćç',
      'dď',
      'eéèêëě',
      'iíìîï',
      'lĺľł',
      'nňńñ',
      'oóòôöõ',
      'rřŕ',
      'sšś',
      'tť',
      'uúùûüů',
      'yýÿ',
      'zžźż',
    ]) {
      key = key.replaceAll(RegExp('[${letters.substring(1)}]'), letters[0]);
    }
    return key
        .replaceAll(RegExp(r'\p{M}', unicode: true), '')
        .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
        .trim();
  }

  @override
  Future<void> play() {
    final id = _preparedEpisodeId;
    _preparedEpisodeId = null;
    return _playRequest(
      () => _player.resume(
        preferredEpisodeId: id,
        refreshLibrary: _android ? _refreshLibrary : null,
      ),
    );
  }

  Future<void> _refreshLibrary() async {
    final refresh = _libraryRefresh ??= _player._sync.syncNow().whenComplete(
      () {
        _libraryRefresh = null;
      },
    );
    await refresh.timeout(const Duration(seconds: 2), onTimeout: () {});
  }

  Future<void> _playRequest(Future<void> Function() start) async {
    try {
      await start();
    } on Object {
      if (_player.lastPlaybackError == null) rethrow;
    }
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) async {
    if (!_android) await _player.seekTo(position);
  }

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
    final playing = _player._mediaPlaying;
    final loaded = _player._loaded;
    final engine = _player._engine;
    final error = _player.lastPlaybackError;
    final processing = episode == null
        ? (_android ? AudioProcessingState.idle : AudioProcessingState.ready)
        : error != null
        ? AudioProcessingState.error
        : !loaded
        ? AudioProcessingState.loading
        : switch (engine.processingState) {
            ProcessingState.idle => AudioProcessingState.ready,
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
    final position =
        loaded &&
            !_player._seeking &&
            _player._failureAttempt == null &&
            engine.processingState != ProcessingState.completed
        ? engine.position
        : _player.position.value;
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
                MediaControl.skipToPrevious.copyWith(
                  label: _czech ? 'Skok zpět' : 'Skip back',
                ),
                playing
                    ? MediaControl.pause.copyWith(
                        label: _czech ? 'Pauza' : 'Pause',
                      )
                    : MediaControl.play.copyWith(
                        label: _czech ? 'Přehrát' : 'Play',
                      ),
                MediaControl.skipToNext.copyWith(
                  label: _czech ? 'Skok vpřed' : 'Skip forward',
                ),
                MediaControl.stop.copyWith(label: _czech ? 'Zastavit' : 'Stop'),
              ],
        androidCompactActionIndices: episode == null ? [] : [0, 1, 2],
        systemActions: loaded && !_android
            ? const {MediaAction.seek}
            : const {},
        processingState: processing,
        playing: playing,
        errorMessage: error == null ? null : _errorMessage(error.reason),
        updatePosition: position,
        bufferedPosition: loaded ? engine.bufferedPosition : Duration.zero,
        speed: _player.speed,
      ),
    );
    if (_android &&
        error != null &&
        state.processingState != AudioProcessingState.error) {
      _background(androidPlatform.invokeMethod<void>('stopForeground'));
    }
  }

  String _errorMessage(PlaybackErrorReason reason) => switch (reason) {
    PlaybackErrorReason.loadFailed =>
      _czech ? 'Díl se nepodařilo otevřít.' : 'Could not open the episode.',
    PlaybackErrorReason.streamFailed =>
      _czech ? 'Přehrávání se přerušilo.' : 'Playback was interrupted.',
    PlaybackErrorReason.seekFailed =>
      _czech ? 'Přeskočení se nezdařilo.' : 'Could not seek.',
    PlaybackErrorReason.audioFocusUnavailable =>
      _czech ? 'Zvuk teď není dostupný.' : 'Audio is unavailable.',
  };
}
