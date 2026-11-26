import 'package:flutter/foundation.dart';

enum DownloadStatus { none, queued, running, done, failed }

class DownloadInfo {
  const DownloadInfo(
    this.status, {
    this.progress = 0,
    this.filePath,
    this.waitingForWifi = false,
  });

  static const none = DownloadInfo(DownloadStatus.none);

  final DownloadStatus status;

  /// 0 to 1.
  final double progress;
  final String? filePath;
  final bool waitingForWifi;
}

abstract class DownloadService extends ChangeNotifier {
  DownloadInfo statusOf(int episodeId);

  String? localFileOf(int episodeId);

  /// Finished downloads, newest first.
  List<int> get downloadedEpisodeIds;

  /// Pending and failed downloads followed by finished downloads.
  List<int> get episodeIds => downloadedEpisodeIds;

  Future<void> download(int episodeId);

  Future<void> delete(int episodeId);
}
