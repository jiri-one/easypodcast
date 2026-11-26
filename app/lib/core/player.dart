import 'package:flutter/foundation.dart';

import 'models.dart';

/// Notifies on episode, play/pause, speed and sleep timer changes only. The position has its
/// own listenable so that an e-ink screen redraws it only where and when the UI wants.
abstract class PlayerController extends ChangeNotifier {
  Episode? get current;

  bool get isPlaying;

  bool get isBuffering;

  ValueListenable<Duration> get position;

  /// From the player once known, else from the feed.
  Duration? get duration;

  double get speed;

  /// Null when no sleep timer runs.
  Duration? get sleepRemaining;

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
