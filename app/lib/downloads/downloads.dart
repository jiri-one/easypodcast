import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:background_downloader/background_downloader.dart';
// ignore: depend_on_referenced_packages
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../core/downloads.dart';
import '../core/library.dart';
import '../core/settings.dart';

const _downloadGroup = 'easypodcast.episodes';
const _downloadDirectory = 'easypodcast/episodes';

Future<DownloadService> openDownloads({
  required Library library,
  required Settings settings,
}) async {
  return EpisodeDownloads.open(
    library: library,
    settings: settings,
    downloader: FileDownloader(),
    documents: await getApplicationDocumentsDirectory(),
    linuxHasWifi: Platform.isLinux ? _linuxHasWifi : null,
  );
}

class EpisodeDownloads extends DownloadService {
  EpisodeDownloads._(
    this._library,
    this._settings,
    this._downloader,
    this._documents,
    this._linuxWifiCheck,
  ) {
    _updates = _downloader.updates.listen((update) {
      if (update.task.group == _downloadGroup) {
        _background(_run(() => _onUpdate(update)));
      }
    });
    _finished = _library.finishedEpisodes.listen((id) {
      _background(
        _run(() async {
          if (_shouldDelete(id)) await _delete(id);
        }),
      );
    });
  }

  static Future<EpisodeDownloads> open({
    required Library library,
    required Settings settings,
    required FileDownloader downloader,
    required Directory documents,
    Future<bool> Function()? linuxHasWifi,
  }) async {
    final service = EpisodeDownloads._(
      library,
      settings,
      downloader,
      documents,
      linuxHasWifi,
    );
    try {
      await service._run(service._restore);
      return service;
    } catch (_) {
      service.dispose();
      rethrow;
    }
  }

  final Library _library;
  final Settings _settings;
  final FileDownloader _downloader;
  final Directory _documents;
  final Future<bool> Function()? _linuxWifiCheck;
  final _entries = <int, _Download>{};
  late final StreamSubscription<TaskUpdate> _updates;
  late final StreamSubscription<int> _finished;
  Future<void> _commands = Future.value();
  bool _disposed = false;

  @override
  DownloadInfo statusOf(int episodeId) =>
      _entries[episodeId]?.info ?? DownloadInfo.none;

  @override
  String? localFileOf(int episodeId) => statusOf(episodeId).filePath;

  @override
  List<int> get downloadedEpisodeIds {
    final finished =
        _entries.entries
            .where((entry) => entry.value.completedAt != null)
            .toList()
          ..sort(
            (a, b) => b.value.completedAt!.compareTo(a.value.completedAt!),
          );
    return [for (final entry in finished) entry.key];
  }

  Future<void> _restore() async {
    final desktop = _linuxWifiCheck != null;
    await _downloader.start(doRescheduleKilledTasks: !desktop);
    final records = await _downloader.database.allRecords(group: _downloadGroup)
      ..sort((a, b) => b.task.creationTime.compareTo(a.task.creationTime));
    for (final record in records) {
      if (record.task case final DownloadTask task) {
        final id = int.tryParse(task.metaData);
        if (id == null) continue;
        if (_entries.containsKey(id) ||
            record.status == TaskStatus.canceled ||
            _shouldDelete(id, downloadCreatedAt: task.creationTime)) {
          await _discard(task, cancel: record.status.isNotFinalState);
          continue;
        }
        final status = desktop && record.status.isNotFinalState
            ? TaskStatus.failed
            : record.status;
        final entry = await _entry(task, status, record.progress);
        if (record.status == TaskStatus.complete &&
            entry.info.status != DownloadStatus.done) {
          await _discard(task, cancel: false);
        } else {
          _entries[id] = entry;
        }
      }
    }
  }

  @override
  Future<void> download(int episodeId) => _run(() async {
    final episode = _library.episode(episodeId);
    final existing = _entries[episodeId];
    if (episode == null ||
        _library.stateOf(episodeId).isDismissed ||
        (existing != null && existing.info.status != DownloadStatus.failed)) {
      return;
    }
    if (existing != null) await _delete(episodeId);

    final url = Uri.parse(episode.enclosureUrl);
    final suffix = path.extension(url.path).toLowerCase();
    final extension =
        const {
          '.aac',
          '.flac',
          '.m4a',
          '.m4b',
          '.mp3',
          '.mp4',
          '.oga',
          '.ogg',
          '.opus',
          '.wav',
          '.webm',
        }.contains(suffix)
        ? suffix
        : '.audio';
    final taskId = '$episodeId-${Random.secure().nextInt(1 << 32)}';
    final wifiOnly = _settings.downloadOnWifiOnly;
    final task = DownloadTask(
      taskId: taskId,
      url: url.toString(),
      filename: '$taskId$extension',
      directory: _downloadDirectory,
      baseDirectory: BaseDirectory.applicationDocuments,
      group: _downloadGroup,
      updates: Updates.statusAndProgress,
      requiresWiFi: wifiOnly,
      retries: _linuxWifiCheck != null && wifiOnly ? 0 : 2,
      metaData: '$episodeId',
      displayName: episode.title,
    );
    if (wifiOnly && _linuxWifiCheck != null && !await _linuxWifiCheck()) {
      _setFailed(episodeId, task);
      return;
    }
    _entries[episodeId] = _Download(
      task,
      const DownloadInfo(DownloadStatus.queued),
    );
    _notify();
    try {
      if (await _downloader.enqueue(task)) return;
    } catch (_) {
      _setFailed(episodeId, task);
      rethrow;
    }
    _setFailed(episodeId, task);
  });

  void _setFailed(int id, DownloadTask task) {
    _entries[id] = _Download(task, const DownloadInfo(DownloadStatus.failed));
    _notify();
  }

  @override
  Future<void> delete(int episodeId) => _run(() => _delete(episodeId));

  bool _shouldDelete(int id, {DateTime? downloadCreatedAt}) {
    final state = _library.stateOf(id);
    return state.isDismissed ||
        (state.isPlayed &&
            _settings.deleteAfterPlayed &&
            (downloadCreatedAt == null ||
                !state.updatedAt.isBefore(downloadCreatedAt)));
  }

  Future<void> _delete(int id) async {
    final entry = _entries[id];
    if (entry == null) return;
    final status = entry.info.status;
    await _discard(
      entry.task,
      cancel:
          status == DownloadStatus.queued || status == DownloadStatus.running,
    );
    _entries.remove(id);
    _notify();
  }

  Future<void> _discard(DownloadTask task, {required bool cancel}) async {
    if (cancel) await _downloader.cancelTaskWithId(task.taskId);
    final file = _file(task);
    try {
      await file.delete();
    } on FileSystemException {
      if (await file.exists()) rethrow;
    }
    await _downloader.database.deleteRecordWithId(task.taskId);
  }

  File _file(DownloadTask task) =>
      File(path.join(_documents.path, _downloadDirectory, task.filename));

  Future<_Download> _entry(
    DownloadTask task,
    TaskStatus status,
    double progress,
  ) async {
    final bounded = progress.clamp(0.0, 1.0);
    if (status == TaskStatus.complete) {
      final file = _file(task);
      final stat = await file.stat();
      if (stat.type == FileSystemEntityType.file) {
        return _Download(
          task,
          DownloadInfo(DownloadStatus.done, progress: 1, filePath: file.path),
          completedAt: stat.modified,
        );
      }
    }
    final downloadStatus = switch (status) {
      TaskStatus.enqueued ||
      TaskStatus.waitingToRetry ||
      TaskStatus.paused => DownloadStatus.queued,
      TaskStatus.running => DownloadStatus.running,
      TaskStatus.canceled => DownloadStatus.none,
      TaskStatus.complete ||
      TaskStatus.failed ||
      TaskStatus.notFound => DownloadStatus.failed,
    };
    return _Download(task, DownloadInfo(downloadStatus, progress: bounded));
  }

  Future<void> _onUpdate(TaskUpdate update) async {
    final task = update.task;
    if (task is! DownloadTask) return;
    final id = int.tryParse(task.metaData);
    if (id == null) return;
    final previous = _entries[id];
    if (previous?.task.taskId != task.taskId) {
      if (update is TaskStatusUpdate && update.status.isFinalState) {
        await _discard(task, cancel: false);
      }
      return;
    }
    if (previous!.info.status == DownloadStatus.done) return;

    switch (update) {
      case TaskStatusUpdate(status: TaskStatus.canceled):
        await _discard(task, cancel: false);
        _entries.remove(id);
      case TaskStatusUpdate(:final status):
        _entries[id] = await _entry(task, status, previous.info.progress);
      case TaskProgressUpdate(:final progress)
          when progress >= 0 && progress < 1:
        _entries[id] = _Download(
          task,
          DownloadInfo(DownloadStatus.running, progress: progress),
        );
      default:
        return;
    }
    _notify();
  }

  Future<void> _run(Future<void> Function() command) {
    final result = _commands.then((_) async {
      if (!_disposed) await command();
    });
    _commands = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_updates.cancel());
    unawaited(_finished.cancel());
    super.dispose();
  }
}

class _Download {
  const _Download(this.task, this.info, {this.completedAt});

  final DownloadTask task;
  final DownloadInfo info;
  final DateTime? completedAt;
}

void _background(Future<void> work) {
  unawaited(
    work.catchError((Object error, StackTrace stack) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stack),
      );
    }),
  );
}

// The desktop downloader does not enforce requiresWiFi when it starts a task.
Future<bool> _linuxHasWifi() async {
  try {
    final connections = await Connectivity().checkConnectivity().timeout(
      const Duration(seconds: 5),
    );
    return connections.contains(ConnectivityResult.wifi);
  } catch (_) {
    return false;
  }
}
