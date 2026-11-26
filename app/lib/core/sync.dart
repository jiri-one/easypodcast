import 'package:flutter/foundation.dart';

enum SyncPhase { loggedOut, idle, offline, error }

class SyncStatus {
  const SyncStatus({
    required this.phase,
    this.syncing = false,
    this.lastSuccess,
    this.pending = 0,
    this.error,
    this.clockSkewWarning,
  });

  final SyncPhase phase;
  final bool syncing;
  final DateTime? lastSuccess;

  /// Changes waiting to be sent.
  final int pending;
  final String? error;
  final Duration? clockSkewWarning;
}

abstract class SyncService {
  String get serverUrl;

  String get deviceName;

  ValueListenable<SyncStatus> get status;

  bool get isLoggedIn;

  Future<void> login({
    required String serverUrl,
    required String username,
    required String password,
    required String deviceName,
  });

  Future<void> logout();

  Future<void> start();

  Future<void> stop();

  Future<void> syncNow();

  Future<void> sendPending({Duration? timeout}) async {}

  /// Applies a newer server state of the episode before playback; gives up after about 2 s.
  Future<void> freshStateBeforePlay(int episodeId);

  /// The playing episode's position is never changed from outside.
  void setPlayingEpisode(int? episodeId);
}
