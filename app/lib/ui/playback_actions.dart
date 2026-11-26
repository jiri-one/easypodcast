import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../core/services.dart';

class PlaybackActions extends ChangeNotifier {
  PlaybackActions(this.services) {
    services.player.addListener(_playerChanged);
  }

  final AppServices services;
  final _interaction = ValueNotifier(0);
  bool _busy = false;
  bool _disposed = false;
  bool failed = false;
  bool failedPlaying = false;
  bool seekUnavailable = false;
  int? failedEpisodeId;
  Listenable get interaction => _interaction;

  Episode? get target {
    final current = services.player.current;
    if (current != null && !services.library.stateOf(current.id).isFinished) {
      return current;
    }
    return services.player.lastPlaybackError?.episode ??
        services.library.recentUnfinishedEpisode;
  }

  bool playing(int id) =>
      services.player.isPlaying && services.player.current?.id == id;

  bool loading(int id) =>
      services.player.current?.id == id && services.player.isBuffering;

  Future<void> toggle([Episode? episode]) {
    final item = episode ?? target;
    if (item == null || _busy) return Future.value();
    final player = services.player;
    final same =
        player.current?.id == item.id &&
        !services.library.stateOf(item.id).isFinished;
    if (same && player.isPlaying) return _run(player.pause, episodeId: item.id);
    if (loading(item.id)) return Future.value();
    return _run(
      same ? player.resume : () => player.play(item.id),
      episodeId: item.id,
      playing: true,
    );
  }

  Future<void> retry() => _run(
    services.player.resume,
    episodeId: services.player.lastPlaybackError?.episode.id,
    playing: true,
  );

  bool canSeek(int? episodeId) =>
      episodeId != null &&
      services.player.current?.id == episodeId &&
      !services.library.stateOf(episodeId).isFinished &&
      services.player.lastPlaybackError == null &&
      !services.player.isCheckingPosition &&
      !services.player.isBuffering;

  void showSeekUnavailable() {
    if (seekUnavailable || _disposed) return;
    seekUnavailable = true;
    notifyListeners();
  }

  Future<void> skipBack() =>
      _skip(Duration(seconds: -services.settings.skipBackSeconds));

  Future<void> skipForward() =>
      _skip(Duration(seconds: services.settings.skipForwardSeconds));

  Future<void> _skip(Duration delta) {
    final id = services.player.current?.id;
    if (!canSeek(id)) {
      showSeekUnavailable();
      return Future.value();
    }
    return _run(() => services.player.seekBy(delta), episodeId: id);
  }

  Future<void> seekTo(int episodeId, Duration position) {
    if (!canSeek(episodeId)) {
      showSeekUnavailable();
      return Future.value();
    }
    return _run(() => services.player.seekTo(position), episodeId: episodeId);
  }

  Future<void> speed(double value) =>
      _run(() => services.player.setSpeed(value));

  Future<void> setSleep({int? minutes, bool endOfEpisode = false}) =>
      _run(() async {
        final player = services.player;
        if (endOfEpisode) {
          await player.setSleepAtEndOfEpisode(true);
        } else {
          await player.setSleepTimer(
            minutes == null ? null : Duration(minutes: minutes),
          );
        }
      });

  void refreshTime() {
    if (!_disposed) _interaction.value++;
  }

  void _playerChanged() {
    if (canSeek(services.player.current?.id)) seekUnavailable = false;
    notifyListeners();
  }

  Future<void> _run(
    Future<void> Function() operation, {
    int? episodeId,
    bool playing = false,
  }) async {
    if (_busy || _disposed) return;
    _busy = true;
    final hadNotice = failed || seekUnavailable;
    failed = false;
    failedPlaying = false;
    seekUnavailable = false;
    failedEpisodeId = null;
    if (hadNotice) notifyListeners();
    try {
      await operation();
    } on Exception {
      failed = services.player.lastPlaybackError == null;
      failedPlaying = failed && playing;
      failedEpisodeId = episodeId;
    } finally {
      _busy = false;
      if (canSeek(services.player.current?.id)) seekUnavailable = false;
      if (!_disposed) {
        refreshTime();
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    services.player.removeListener(_playerChanged);
    _interaction.dispose();
    super.dispose();
  }
}
