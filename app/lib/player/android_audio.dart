part of 'player.dart';

@visibleForTesting
const androidAudioConfig = AudioServiceConfig(
  androidNotificationChannelId: 'one.jiri.easypodcast.audio',
  androidNotificationChannelName: 'EasyPodcast',
  androidNotificationIcon: 'drawable/ic_stat_easypodcast',
  androidStopForegroundOnPause: false,
  artDownscaleWidth: 256,
  artDownscaleHeight: 256,
  androidBrowsableRootExtras: {
    AndroidContentStyle.supportedKey: true,
    AndroidContentStyle.browsableHintKey: AndroidContentStyle.gridItemHintValue,
    AndroidContentStyle.playableHintKey: AndroidContentStyle.listItemHintValue,
  },
);

Future<void> _openAndroidAudio(
  EpisodePlayer player,
  Future<Uri?> Function(Episode, Podcast?)? artwork,
  Future<Uri?> Function(Episode?, Podcast?)? listArtwork,
) async {
  final carConnected = watchCarConnection();
  await AudioService.init(
    builder: () => EpisodeAudioHandler(
      player,
      player._library,
      player._downloads,
      player._settings,
      android: true,
      artwork: artwork,
      listArtwork: listArtwork,
      carConnected: carConnected,
    ),
    config: androidAudioConfig,
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
    this._artwork,
    this._listArtwork,
    this._carConnected,
  }) : _languageCode = languageCode ?? _deviceLanguage {
    _player._mediaChanges.stream.listen(
      _publish,
      onDone: () {
        if (!_android) return;
        _library.removeListener(_notifyChildrenChanged);
        _downloads.removeListener(_notifyDownloadsChanged);
        _carConnected?.removeListener(_republish);
        unawaited(_childrenChanged.close());
      },
    );
    if (_android) {
      _library.addListener(_notifyChildrenChanged);
      _downloadedIds = List.of(_downloads.downloadedEpisodeIds);
      _downloads.addListener(_notifyDownloadsChanged);
      _carConnected?.addListener(_republish);
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
  final Future<Uri?> Function(Episode, Podcast?)? _artwork;
  final Future<Uri?> Function(Episode?, Podcast?)? _listArtwork;
  final ValueListenable<bool>? _carConnected;
  final _childrenChanged = BehaviorSubject<Map<String, dynamic>>();
  late List<int> _downloadedIds;
  Future<void>? _libraryRefresh;
  int? _preparedEpisodeId;
  int? _artworkId;
  int _artworkRequest = 0;
  Uri? _artUri;

  static String _deviceLanguage() =>
      WidgetsBinding.instance.platformDispatcher.locale.languageCode;

  AppLocalizations get _strings =>
      lookupAppLocalizations(Locale(_languageCode() == 'cs' ? 'cs' : 'en'));

  static const _inProgress = 'in-progress';
  static const _queue = 'queue';
  static const _downloaded = 'downloaded';
  static const _podcasts = 'podcasts';
  static const _episodePrefix = 'episode:';
  static const _podcastPrefix = 'podcast:';
  // androidx.media MediaConstants, which Android Auto reads as a progress bar.
  static const _completionStatus = 'android.media.extra.PLAYBACK_STATUS';
  static const _partiallyPlayed = 1;
  static const _completionPercentage =
      'androidx.media.MediaItem.Extras.COMPLETION_PERCENTAGE';
  List<MediaItem> get _rootItems {
    final strings = _strings;
    return [
      MediaItem(
        id: _inProgress,
        title: strings.inProgressShort,
        playable: false,
      ),
      MediaItem(id: _queue, title: strings.queue, playable: false),
      MediaItem(id: _downloaded, title: strings.downloads, playable: false),
      MediaItem(id: _podcasts, title: strings.podcasts, playable: false),
    ];
  }

  MediaItem _item(
    Episode episode, {
    Duration? duration,
    Uri? artUri,
    Map<String, dynamic>? extras,
  }) {
    final podcast = _library.podcast(episode.podcastId);
    return MediaItem(
      id: '$_episodePrefix${episode.id}',
      title: episode.title,
      album: podcast?.title,
      artist: _android ? null : podcast?.author,
      artUri: artUri,
      duration: duration ?? episode.feedDuration,
      extras: extras,
    );
  }

  MediaItem _podcastItem(Podcast podcast, {Uri? artUri}) => MediaItem(
    id: '$_podcastPrefix${podcast.id}',
    title: podcast.title,
    artUri: artUri,
    playable: false,
  );

  Future<List<MediaItem>> _listItems(Iterable<Episode> episodes) =>
      Future.wait(episodes.map(_listItem));

  Future<MediaItem> _listItem(Episode episode) async {
    final podcast = _library.podcast(episode.podcastId);
    final state = _library.stateOf(episode.id);
    final duration = episodeDuration(episode, state);
    return _item(
      episode,
      duration: duration,
      artUri: await _listArtwork?.call(episode, podcast),
      extras: state.isInProgress
          ? {
              _completionStatus: _partiallyPlayed,
              if (duration != null)
                _completionPercentage: playedFraction(
                  state.resumePosition,
                  duration,
                ),
            }
          : null,
    );
  }

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
        if (_android) background(_refreshLibrary());
        return _rootItems;
      case AudioService.recentRootId:
        if (_android && _libraryRefresh != null) await _refreshLibrary();
        final head = _library.queueHeadId;
        final recent =
            _library.recentUnfinishedEpisode ??
            (head == null ? null : await _library.resolveQueueEpisode(head));
        return recent == null ? [] : [_item(recent)];
      case _inProgress:
        return _listItems(_library.inProgress);
      case _queue:
        return _listItems(_library.queue);
      case _downloaded:
        return _listItems(
          _downloads.downloadedEpisodeIds
              .map(_library.episode)
              .whereType<Episode>(),
        );
      case _podcasts:
        return Future.wait(
          _library.podcasts.map(
            (podcast) async => _podcastItem(
              podcast,
              artUri: await _listArtwork?.call(null, podcast),
            ),
          ),
        );
    }
    final id = _parseId(parentMediaId, _podcastPrefix);
    return id == null
        ? []
        : _listItems(
            _library
                .episodesOf(id)
                .where((episode) => _player._isUnfinished(episode.id))
                .take(100),
          );
  }

  @override
  ValueStream<Map<String, dynamic>> subscribeToChildren(String parentMediaId) {
    if (!_android || parentMediaId == AudioService.browsableRootId) {
      return super.subscribeToChildren(parentMediaId);
    }
    if (parentMediaId == AudioService.recentRootId) {
      background(_refreshLibrary());
    }
    return _childrenChanged;
  }

  void _notifyChildrenChanged() => _childrenChanged.add(const {});

  void _republish() => _publish(true);

  void _notifyDownloadsChanged() {
    final ids = _downloads.downloadedEpisodeIds;
    if (listEquals(ids, _downloadedIds)) return;
    _downloadedIds = List.of(ids);
    _notifyChildrenChanged();
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
    _player._cancelFocusResume();
    return _playRequest(
      () => _player._commands.run(() async {
        if (_android && _player.current == null) await _refreshLibrary();
        await _player._resume(id);
      }),
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

  void _loadArtwork(Episode? episode) {
    final artwork = _artwork;
    // The player may swap in a fresh copy of the same episode; keep its cover.
    if (artwork == null || _artworkId == episode?.id) return;
    _artworkId = episode?.id;
    _artUri = null;
    final request = ++_artworkRequest;
    if (episode == null) return;
    final podcast = _library.podcast(episode.podcastId);
    background(
      artwork(episode, podcast).then((uri) {
        if (request != _artworkRequest) return;
        _artUri = uri;
        _publish(false);
      }),
    );
  }

  void _publish(bool force) {
    final episode = _player.current;
    _loadArtwork(episode);
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
        : _item(episode, duration: _player.duration, artUri: _artUri);
    final previous = mediaItem.value;
    if (item?.id != previous?.id ||
        item?.duration != previous?.duration ||
        item?.artUri != previous?.artUri) {
      mediaItem.add(item);
    }
    final position = loaded && !_player._seeking
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
    final strings = _strings;
    playbackState.add(
      PlaybackState(
        controls: episode == null
            ? []
            : [
                MediaControl.skipToPrevious.copyWith(label: strings.skipBack),
                playing
                    ? MediaControl.pause.copyWith(label: strings.pause)
                    : MediaControl.play.copyWith(label: strings.play),
                MediaControl.skipToNext.copyWith(label: strings.skipForward),
                // In the car Stop is an unlabelled square that ends the session.
                if (_carConnected?.value != true)
                  MediaControl.stop.copyWith(label: strings.stop),
              ],
        androidCompactActionIndices: episode == null ? [] : [0, 1, 2],
        systemActions: loaded && !_android
            ? const {MediaAction.seek}
            : const {},
        processingState: processing,
        playing: playing,
        errorMessage: switch (error?.reason) {
          PlaybackErrorReason.loadFailed => strings.playbackLoadFailed,
          PlaybackErrorReason.streamFailed => strings.playbackStreamFailed,
          PlaybackErrorReason.seekFailed => strings.playbackSeekFailed,
          PlaybackErrorReason.audioFocusUnavailable =>
            strings.playbackFocusUnavailable,
          null => null,
        },
        updatePosition: position,
        bufferedPosition: loaded ? engine.bufferedPosition : Duration.zero,
        speed: _player.speed,
      ),
    );
    if (_android &&
        error != null &&
        state.processingState != AudioProcessingState.error) {
      background(androidPlatform.invokeMethod<void>('stopForeground'));
    }
  }
}
