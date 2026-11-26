import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/library.dart';
import '../../core/models.dart';
import '../../core/player.dart';
import '../../core/settings.dart';
import '../../core/sync.dart';

class DemoPlayerController extends PlayerController {
  DemoPlayerController(this._library, this._settings, this._sync) {
    _finished = _library.finishedEpisodes.listen((id) {
      if (_current?.id != id) return;
      unawaited(
        _run(() async {
          if (_current?.id == id &&
              _library.stateOf(id).status != EpisodeStatus.none) {
            _clear();
            notifyListeners();
          }
        }),
      );
    });
  }

  final Library _library;
  final Settings _settings;
  final SyncService _sync;
  final _position = ValueNotifier(Duration.zero);
  late final StreamSubscription<int> _finished;
  Future<void> _commands = Future.value();
  bool _disposed = false;
  Episode? _current;
  Timer? _ticker;
  Timer? _sleepTimer;
  Stopwatch? _sleepClock;
  Duration? _sleepDuration;
  bool _sleepAtEndOfEpisode = false;

  @override
  Episode? get current => _current;

  @override
  bool get isPlaying => _ticker != null;

  @override
  bool get isBuffering => false;

  @override
  ValueListenable<Duration> get position => _position;

  @override
  Duration? get duration {
    final episode = _current;
    if (episode == null) return null;
    final measured = _library.stateOf(episode.id).durationMs;
    if (measured != null) return Duration(milliseconds: measured);
    final feed = episode.durationS;
    return feed == null ? null : Duration(seconds: feed);
  }

  @override
  double get speed => _settings.speed;

  @override
  Duration? get sleepRemaining {
    final duration = _sleepDuration;
    if (duration == null) return null;
    final remaining = duration - _sleepClock!.elapsed;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  @override
  bool get sleepAtEndOfEpisode => _sleepAtEndOfEpisode;

  @override
  Future<void> setSleepAtEndOfEpisode(bool on) => _run(() async {
    if (on) _cancelSleepTimer();
    _sleepAtEndOfEpisode = on;
    notifyListeners();
  });

  @override
  Future<void> play(int episodeId) => _run(() => _play(episodeId));

  Future<void> _play(int episodeId) async {
    final episode = _library.episode(episodeId);
    if (episode == null || (_current?.id == episodeId && isPlaying)) return;
    if (isPlaying) {
      _stopTicking();
      await _recordPosition();
    }
    await _sync.freshStateBeforePlay(episodeId);
    final start = await _library.prepareForPlayback(episodeId);
    if (_disposed) return;
    _current = episode;
    _position.value = start;
    _ticker = Timer.periodic(const Duration(seconds: 1), _tick);
    _sync.setPlayingEpisode(episodeId);
    notifyListeners();
  }

  @override
  Future<void> resume() => _run(() async {
    final episode = _current;
    if (episode != null) await _play(episode.id);
  });

  @override
  Future<void> pause() => _run(_pause);

  Future<void> _pause() async {
    if (!isPlaying) return;
    _stopTicking();
    await _recordPosition();
    if (!_disposed) notifyListeners();
  }

  void _tick(Timer timer) {
    final next =
        _position.value + Duration(microseconds: (speed * 1000000).round());
    final end = duration;
    _position.value = end != null && next > end ? end : next;
    if (end != null && next >= end) {
      unawaited(
        _run(() async {
          if (identical(timer, _ticker)) await _complete(advance: true);
        }),
      );
    } else if (timer.tick % 30 == 0) {
      unawaited(_run(_recordPosition));
    }
  }

  @override
  Future<void> seekBy(Duration delta) =>
      _run(() => _seek(_position.value + delta));

  @override
  Future<void> seekTo(Duration position) => _run(() => _seek(position));

  Future<void> _seek(Duration position) async {
    if (_current == null) return;
    final end = duration;
    if (end != null && position >= end) {
      await _complete(advance: isPlaying);
    } else {
      _position.value = position.isNegative ? Duration.zero : position;
      await _recordPosition();
    }
  }

  Future<void> _recordPosition() async {
    final episode = _current;
    if (episode == null) return;
    await _library.recordPosition(
      episode.id,
      _position.value,
      duration: duration,
    );
  }

  Future<void> _complete({required bool advance}) async {
    final episodeId = _current!.id;
    final stopAtEnd = _sleepAtEndOfEpisode;
    _sleepAtEndOfEpisode = false;
    _clear();
    await _library.markCompleted(episodeId);
    if (_disposed) return;
    final next = _library.queue.firstOrNull;
    if (advance && !stopAtEnd && _settings.autoplayQueue && next != null) {
      await _play(next.id);
    } else {
      notifyListeners();
    }
  }

  @override
  Future<void> setSpeed(double speed) => _run(() async {
    if (!speed.isFinite || speed <= 0) throw ArgumentError.value(speed);
    if (speed == this.speed) return;
    _settings.speed = speed;
    notifyListeners();
  });

  @override
  Future<void> setSleepTimer(Duration? duration) => _run(() async {
    _cancelSleepTimer();
    _sleepAtEndOfEpisode = false;
    if (duration != null) {
      _sleepDuration = duration;
      _sleepClock = Stopwatch()..start();
      late final Timer timer;
      timer = _sleepTimer = Timer(duration, () {
        unawaited(
          _run(() async {
            if (!identical(timer, _sleepTimer)) return;
            _cancelSleepTimer();
            if (isPlaying) {
              await _pause();
            } else {
              notifyListeners();
            }
          }),
        );
      });
    }
    notifyListeners();
  });

  void _cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepClock = null;
    _sleepDuration = null;
  }

  @override
  Future<void> stop() => _run(() async {
    _cancelSleepTimer();
    _sleepAtEndOfEpisode = false;
    _stopTicking();
    await _recordPosition();
    if (_disposed) return;
    _clear();
    notifyListeners();
  });

  void _stopTicking() {
    _ticker?.cancel();
    _ticker = null;
    _sync.setPlayingEpisode(null);
  }

  void _clear() {
    _stopTicking();
    _current = null;
    _position.value = Duration.zero;
  }

  Future<void> _run(Future<void> Function() command) {
    final result = _commands.then((_) async {
      if (!_disposed) await command();
    });
    _commands = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  @override
  void dispose() {
    _disposed = true;
    _stopTicking();
    _cancelSleepTimer();
    unawaited(_finished.cancel());
    _position.dispose();
    super.dispose();
  }
}
