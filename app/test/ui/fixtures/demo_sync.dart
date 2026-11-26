import 'package:flutter/foundation.dart';

import 'package:easypodcast/core/api.dart';
import 'package:easypodcast/core/models.dart';
import 'package:easypodcast/core/sync.dart';

import 'demo_library.dart';

class DemoSyncService extends SyncService {
  DemoSyncService(this._api, this._library, {required bool loggedIn})
    : serverUrl = loggedIn ? 'https://podcast.example' : '',
      deviceName = loggedIn ? 'Demo' : '',
      _status = ValueNotifier(
        SyncStatus(
          phase: loggedIn ? SyncPhase.idle : SyncPhase.loggedOut,
          lastSuccess: loggedIn ? nowUtc() : null,
        ),
      );

  final ApiClient _api;
  final DemoLibrary _library;
  @override
  String serverUrl;
  @override
  String deviceName;
  final ValueNotifier<SyncStatus> _status;
  Future<void> Function(int id)? beforePlay;

  void setOffline() {
    _status.value = SyncStatus(
      phase: SyncPhase.offline,
      lastSuccess: _status.value.lastSuccess,
      pending: 1,
    );
  }

  @override
  ValueListenable<SyncStatus> get status => _status;

  @override
  bool get isLoggedIn => _status.value.phase != SyncPhase.loggedOut;

  @override
  Future<void> login({
    required String serverUrl,
    required String username,
    required String password,
    required String deviceName,
  }) async {
    await _api.login(
      serverUrl: serverUrl,
      username: username,
      password: password,
      deviceName: deviceName,
    );
    this.serverUrl = serverUrl;
    this.deviceName = deviceName;
    _setIdle();
  }

  @override
  Future<void> logout() async {
    await _api.logout();
    _status.value = const SyncStatus(phase: SyncPhase.loggedOut);
  }

  @override
  Future<void> start() => syncNow();

  @override
  Future<void> stop() async {}

  @override
  Future<void> syncNow() async {
    if (isLoggedIn) _setIdle();
  }

  void _setIdle() {
    _status.value = SyncStatus(phase: SyncPhase.idle, lastSuccess: nowUtc());
  }

  @override
  Future<void> freshStateBeforePlay(int episodeId) async {
    await beforePlay?.call(episodeId);
  }

  @override
  void setPlayingEpisode(int? episodeId) {
    _library.playingEpisodeId = episodeId;
  }
}
