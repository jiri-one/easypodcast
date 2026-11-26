import 'dart:async';

import '../../core/downloads.dart';
import '../../core/library.dart';
import '../../core/settings.dart';

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
  final _queued = <int>{};

  void queueDownload(int episodeId) {
    if (!_completed.contains(episodeId) && _queued.add(episodeId)) {
      notifyListeners();
    }
  }

  @override
  DownloadInfo statusOf(int episodeId) {
    if (_queued.contains(episodeId)) {
      return const DownloadInfo(DownloadStatus.queued);
    }
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
  Future<void> download(int episodeId) async {
    if (_library.episode(episodeId) == null ||
        _library.stateOf(episodeId).isDismissed) {
      return;
    }
    _queued.remove(episodeId);
    if (_completed.add(episodeId)) notifyListeners();
  }

  @override
  Future<void> delete(int episodeId) async {
    final queued = _queued.remove(episodeId);
    if (_completed.remove(episodeId) || queued) notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_finished.cancel());
    super.dispose();
  }
}
