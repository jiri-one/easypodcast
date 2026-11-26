import 'dart:async';

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
  int? checkingId;
  Timer? _checkingTimer;
  DateTime? _pausedAt;
  int? _playingId;
  int? _sleepMinutes;
  DateTime? _sleepDeadline;

  Listenable get interaction => _interaction;
  bool get sleepUntilEnd => services.player.sleepAtEndOfEpisode;
  int? get sleepMinutes => _sleepMinutes;

  DateTime? get sleepDeadline {
    if (services.player.sleepRemaining == null) return null;
    return _sleepDeadline ??= DateTime.now().add(
      services.player.sleepRemaining!,
    );
  }

  Episode? get target {
    final current = services.player.current;
    if (current != null &&
        services.library.stateOf(current.id).status == EpisodeStatus.none) {
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
        services.library.stateOf(item.id).status == EpisodeStatus.none;
    if (same && player.isPlaying) return _run(player.pause, episodeId: item.id);
    if (loading(item.id)) return Future.value();
    final pausedAt = _pausedAt;
    final check =
        !same ||
        pausedAt == null ||
        DateTime.now().difference(pausedAt) >= const Duration(seconds: 30);

    return _run(
      () async {
        if (same) {
          await player.resume();
        } else {
          await player.play(item.id);
        }
      },
      checking: check ? item.id : null,
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
      services.library.stateOf(episodeId).status == EpisodeStatus.none &&
      services.player.lastPlaybackError == null &&
      checkingId == null &&
      !services.player.isBuffering;

  void showSeekUnavailable() {
    if (seekUnavailable || _disposed) return;
    seekUnavailable = true;
    notifyListeners();
  }

  Future<void> skip(Duration delta) {
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
        _sleepMinutes = minutes;
        _sleepDeadline = null;
      });

  void refreshTime() {
    if (!_disposed) _interaction.value++;
  }

  void _playerChanged() {
    final player = services.player;
    final current = player.current?.id;
    if (player.isPlaying) {
      _playingId = current;
      _pausedAt = null;
    } else if (_playingId != null) {
      _pausedAt = current == _playingId ? DateTime.now() : null;
      _playingId = null;
    }
    if (_sleepMinutes != null && player.sleepRemaining == null) {
      _sleepMinutes = null;
      _sleepDeadline = null;
    }
    if (canSeek(current)) seekUnavailable = false;
    notifyListeners();
  }

  Future<void> _run(
    Future<void> Function() operation, {
    int? checking,
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
    if (checking != null) {
      checkingId = checking;
      _checkingTimer = Timer(const Duration(seconds: 2), () {
        checkingId = null;
        notifyListeners();
      });
    }
    if (checking != null || hadNotice) notifyListeners();
    try {
      await operation();
    } on Exception {
      failed = services.player.lastPlaybackError == null;
      failedPlaying = failed && playing;
      failedEpisodeId = episodeId;
    } finally {
      _busy = false;
      _checkingTimer?.cancel();
      checkingId = null;
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
    _checkingTimer?.cancel();
    _interaction.dispose();
    super.dispose();
  }
}
