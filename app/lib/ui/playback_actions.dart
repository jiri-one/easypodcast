import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../core/services.dart';
import 'episode_text.dart';

class PlaybackActions extends ChangeNotifier {
  PlaybackActions(this.services) {
    services.player.addListener(_playerChanged);
  }

  final AppServices services;
  final _interaction = ValueNotifier(0);
  bool _busy = false;
  bool _disposed = false;
  bool failed = false;
  int? failedEpisodeId;
  int? checkingId;
  Timer? _checkingTimer;
  DateTime? _pausedAt;
  int? _playingId;
  int? _sleepEpisodeId;
  int? _sleepMinutes;
  DateTime? _sleepDeadline;
  Timer? _sleepAdvance;

  Listenable get interaction => _interaction;
  bool get sleepUntilEnd => _sleepEpisodeId != null;
  int? get sleepMinutes => _sleepMinutes;

  DateTime? get sleepDeadline {
    if (sleepUntilEnd) return _sleepDeadline;
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
    final library = services.library;
    var latest = library.inProgress.firstOrNull;
    var timestamp = latest == null
        ? oldestTime
        : library.stateOf(latest.id).updatedAt;
    for (final episode in library.newEpisodes(limit: 0x7fffffff)) {
      final state = library.stateOf(episode.id);
      if (state.positionMs > 0 && state.updatedAt.isAfter(timestamp)) {
        latest = episode;
        timestamp = state.updatedAt;
      }
    }
    return latest;
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
        if (_sleepEpisodeId != null && _sleepEpisodeId != item.id) {
          _clearEndSleep();
        }
        if (same) {
          await player.resume();
        } else {
          await player.play(item.id);
        }
      },
      checking: check ? item.id : null,
      episodeId: item.id,
    );
  }

  Future<void> skip(Duration delta) => _run(
    () => services.player.seekBy(delta),
    episodeId: services.player.current?.id,
  );

  Future<void> seekTo(int episodeId, Duration position) {
    final player = services.player;
    if (player.current?.id != episodeId) return Future.value();
    return _run(() => player.seekTo(position), episodeId: episodeId);
  }

  Future<void> speed(double value) =>
      _run(() => services.player.setSpeed(value));

  Future<void> setSleep({int? minutes, bool endOfEpisode = false}) =>
      _run(() async {
        final player = services.player;
        _clearEndSleep();
        await player.setSleepTimer(
          minutes == null ? null : Duration(minutes: minutes),
        );
        if (_disposed) return;
        _sleepMinutes = minutes;
        _sleepDeadline = minutes == null
            ? null
            : DateTime.now().add(Duration(minutes: minutes));
        if (endOfEpisode) _sleepEpisodeId = target?.id;
        _estimateSleepEnd();
        notifyListeners();
      });

  void refreshTime() {
    if (!_disposed) _interaction.value++;
  }

  void _estimateSleepEnd() {
    final id = _sleepEpisodeId;
    if (id == null) return;
    final player = services.player;
    final episode = services.library.episode(id);
    if (episode == null) return;
    final state = services.library.stateOf(id);
    final current = player.current?.id == id;
    final duration =
        (current ? player.duration : null) ?? episodeDuration(episode, state);
    final position = current
        ? player.position.value
        : Duration(milliseconds: state.positionMs);
    _sleepDeadline = duration == null
        ? null
        : DateTime.now().add(
            Duration(
              milliseconds:
                  ((duration - position).inMilliseconds / player.speed)
                      .round()
                      .clamp(0, duration.inMilliseconds),
            ),
          );
  }

  void _clearEndSleep() {
    _sleepAdvance?.cancel();
    _sleepAdvance = null;
    if (_sleepEpisodeId != null) {
      _sleepEpisodeId = null;
      _sleepDeadline = null;
    }
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
    final end = _sleepEpisodeId;
    if (end != null && current != end) {
      if (services.library.stateOf(end).isPlayed &&
          services.settings.autoplayQueue &&
          services.library.queueHeadId != null) {
        if (current != null && player.isPlaying) {
          _clearEndSleep();
          unawaited(_pauseAfterAdvance());
        } else if (current == null) {
          _sleepAdvance ??= Timer(const Duration(seconds: 15), () {
            _clearEndSleep();
            notifyListeners();
          });
        }
      } else if (current != null ||
          services.library.stateOf(end).status != EpisodeStatus.none) {
        _clearEndSleep();
      }
    }
    notifyListeners();
  }

  Future<void> _pauseAfterAdvance() async {
    try {
      await services.player.pause();
    } on Exception {
      if (!_disposed) {
        failed = true;
        notifyListeners();
      }
    }
  }

  Future<void> _run(
    Future<void> Function() operation, {
    int? checking,
    int? episodeId,
  }) async {
    if (_busy || _disposed) return;
    _busy = true;
    final hadError = failed;
    failed = false;
    failedEpisodeId = null;
    if (checking != null) {
      checkingId = checking;
      _checkingTimer = Timer(const Duration(seconds: 2), () {
        checkingId = null;
        notifyListeners();
      });
    }
    if (checking != null || hadError) notifyListeners();
    try {
      await operation();
    } on Exception {
      failed = true;
      failedEpisodeId = episodeId;
    } finally {
      _busy = false;
      _checkingTimer?.cancel();
      checkingId = null;
      if (!_disposed) {
        _estimateSleepEnd();
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
    _sleepAdvance?.cancel();
    _interaction.dispose();
    super.dispose();
  }
}
