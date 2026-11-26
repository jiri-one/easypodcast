import 'package:flutter/foundation.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/settings.dart';
import '../../core/sync.dart';
import 'demo_library.dart';

class DemoSyncService implements SyncService {
  DemoSyncService(this._api, this._library, this._settings);

  final ApiClient _api;
  final DemoLibrary _library;
  final Settings _settings;
  final _status = ValueNotifier(
    SyncStatus(phase: SyncPhase.idle, lastSuccess: nowUtc()),
  );

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
    _settings.serverUrl = serverUrl;
    _settings.deviceName = deviceName;
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
  Future<void> freshStateBeforePlay(int episodeId) async {}

  @override
  void setPlayingEpisode(int? episodeId) {
    _library.playingEpisodeId = episodeId;
  }
}
