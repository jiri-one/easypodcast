import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../core/services.dart';
import '../core/sync.dart';

class FeedRefresh extends ChangeNotifier {
  FeedRefresh(this.services);

  final AppServices services;
  bool running = false;
  bool failed = false;
  int? _podcastId;
  bool _noNewLoad = false;
  DateTime? _previousLoad;
  bool _disposed = false;
  Timer? _poll;
  Completer<void>? _waiting;

  DateTime? lastLoadedFor(int? podcastId) {
    if (podcastId != null) {
      return services.library.podcast(podcastId)?.lastSuccessAt;
    }
    DateTime? latest;
    for (final podcast in services.library.podcasts) {
      final time = podcast.lastSuccessAt;
      if (time != null && (latest == null || time.isAfter(latest))) {
        latest = time;
      }
    }
    return latest;
  }

  (DateTime?, String?) _resultOf(Podcast? podcast) =>
      (podcast?.lastSuccessAt, podcast?.lastError);

  bool runningFor(int? podcastId) => running && podcastId == _podcastId;
  bool failedFor(int? podcastId) => failed && podcastId == _podcastId;
  bool requestedFor(int? podcastId) =>
      _noNewLoad &&
      podcastId == _podcastId &&
      lastLoadedFor(podcastId) == _previousLoad;

  Future<void> request({int? podcastId}) async {
    if (running || _disposed) return;
    final before = {
      for (final podcast in services.library.podcasts)
        if (podcastId == null || podcast.id == podcastId)
          podcast.id: _resultOf(podcast),
    };
    running = true;
    failed = false;
    _noNewLoad = false;
    _podcastId = podcastId;
    _previousLoad = lastLoadedFor(podcastId);
    notifyListeners();

    try {
      await services.api.refresh();
      // A refresh is accepted before the server fetches the feeds.
      for (final delay in [0, 2, 4, 8]) {
        if (_disposed) return;
        if (delay > 0) await _wait(Duration(seconds: delay));
        if (_disposed) return;
        await services.sync.syncNow();
        if (!services.sync.isLoggedIn || _disposed) return;
        final phase = services.sync.status.value.phase;
        if (phase == SyncPhase.error || phase == SyncPhase.offline) {
          failed = true;
          return;
        }
        if (before.entries.every(
          (entry) =>
              _resultOf(services.library.podcast(entry.key)) != entry.value,
        )) {
          return;
        }
      }
      _noNewLoad = true;
    } on Exception {
      failed = true;
    } finally {
      running = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _wait(Duration delay) {
    final waiting = _waiting = Completer<void>();
    _poll = Timer(delay, () {
      _waiting = null;
      waiting.complete();
    });
    return waiting.future;
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _waiting?.complete();
    super.dispose();
  }
}
