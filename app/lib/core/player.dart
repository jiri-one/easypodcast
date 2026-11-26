import 'package:flutter/foundation.dart';

import 'models.dart';

enum PlaybackErrorReason {
  loadFailed,
  streamFailed,
  seekFailed,
  audioFocusUnavailable,
}

class PlaybackError {
  const PlaybackError(this.episode, this.reason);

  final Episode episode;
  final PlaybackErrorReason reason;
}

/// Notifies on episode, play/pause, speed and sleep timer changes only. The position has its
/// own listenable so that an e-ink screen redraws it only where and when the UI wants.
abstract class PlayerController extends ChangeNotifier {
  Episode? get current;

  bool get isPlaying;

  bool get isBuffering;

  /// The episode whose saved position is being checked.
  int? get checkingPosition => null;

  ValueListenable<Duration> get position;

  /// From the player once known, else from the feed.
  Duration? get duration;

  double get speed;

  /// Null when no sleep timer runs.
  Duration? get sleepRemaining;

  DateTime? get sleepDeadline => null;

  Duration? get sleepDuration => null;

  bool get sleepAtEndOfEpisode => false;

  Future<void> setSleepAtEndOfEpisode(bool on) async {}

  PlaybackError? get lastPlaybackError => null;

  Future<void> play(int episodeId);

  Future<void> resume();

  Future<void> pause();

  Future<void> seekBy(Duration delta);

  Future<void> seekTo(Duration position);

  Future<void> setSpeed(double speed);

  /// Null switches the timer off.
  Future<void> setSleepTimer(Duration? duration);

  Future<void> stop();
}
