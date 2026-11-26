import 'dart:async';

import 'package:easypodcast/core/downloads.dart';
import 'package:easypodcast/core/library.dart';
import 'package:easypodcast/core/settings.dart';

class DemoDownloadService extends DownloadService {
  DemoDownloadService(this._library, Settings settings) {
    _finished = _library.finishedEpisodes.listen((id) {
      if (_library.stateOf(id).isDismissed || settings.deleteAfterPlayed) {
        unawaited(delete(id));
      }
    });
  }

  final Library _library;
  late final StreamSubscription<int> _finished;
  final _completed = {204, 101};
  final _active = <int, DownloadInfo>{};

  void queueDownload(int episodeId, {bool waitingForWifi = false}) {
    if (_completed.contains(episodeId)) return;
    setDownloadInfo(
      episodeId,
      DownloadInfo(DownloadStatus.queued, waitingForWifi: waitingForWifi),
    );
  }

  void setDownloadInfo(int episodeId, DownloadInfo info) {
    _completed.remove(episodeId);
    _active[episodeId] = info;
    notifyListeners();
  }

  @override
  DownloadInfo statusOf(int episodeId) {
    final active = _active[episodeId];
    if (active != null) return active;
    final file = localFileOf(episodeId);
    return file == null
        ? DownloadInfo.none
        : DownloadInfo(DownloadStatus.done, progress: 1, filePath: file);
  }

  @override
  String? localFileOf(int episodeId) =>
      _completed.contains(episodeId) ? '/demo/episodes/$episodeId.mp3' : null;

  @override
  List<int> get downloadedEpisodeIds =>
      List.unmodifiable(_completed.toList().reversed);

  @override
  List<int> get episodeIds => [..._active.keys, ...downloadedEpisodeIds];

  @override
  Future<void> download(int episodeId) async {
    if (_library.episode(episodeId) == null ||
        _library.stateOf(episodeId).isDismissed) {
      return;
    }
    _active.remove(episodeId);
    if (_completed.add(episodeId)) notifyListeners();
  }

  @override
  Future<void> delete(int episodeId) async {
    final active = _active.remove(episodeId);
    if (_completed.remove(episodeId) || active != null) notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_finished.cancel());
    super.dispose();
  }
}
