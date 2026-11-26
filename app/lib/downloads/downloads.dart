import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:background_downloader/background_downloader.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/downloads.dart';
import '../core/library.dart';
import '../core/models.dart';
import '../core/settings.dart';
import '../platform/android_platform.dart';

const _downloadGroup = 'easypodcast.episodes';
const _downloadDirectory = 'easypodcast/episodes';
const _autoPrefix = 'auto:';
const _manualCopiesKey = 'manualQueueDownloadTasks';
const _suppressedKey = 'suppressedQueueDownloads';
const _storageReserve = 256 * 1024 * 1024;

Future<DownloadService> openDownloads({
  required Library library,
  required Settings settings,
}) async {
  final documents = await getApplicationDocumentsDirectory();
  final connectivity = Connectivity();
  bool hasWifi(List<ConnectivityResult> results) =>
      results.contains(ConnectivityResult.wifi);

  return EpisodeDownloads.open(
    library: library,
    settings: settings,
    downloader: FileDownloader(),
    documents: documents,
    desktop: Platform.isLinux,
    wifiCheck: () async => hasWifi(await connectivity.checkConnectivity()),
    wifiChanges: connectivity.onConnectivityChanged.map(hasWifi).distinct(),
    availableBytes: () => _freeDiskBytes(documents),
  );
}

class EpisodeDownloads extends DownloadService {
  EpisodeDownloads._({
    required this._library,
    required this._settings,
    required this._downloader,
    required this._documents,
    required this._desktop,
    required this._availableBytes,
    required this._prefs,
  }) {
    _updates = _downloader.updates.listen((update) {
      if (update.task.group != _downloadGroup ||
          (_restoring &&
              (update is TaskProgressUpdate ||
                  (update is TaskStatusUpdate &&
                      update.status == TaskStatus.running)))) {
        return;
      }
      _background(_run(() => _onUpdate(update)));
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
    bool desktop = false,
    Future<bool> Function()? wifiCheck,
    Stream<bool>? wifiChanges,
    Future<int?> Function()? availableBytes,
  }) async {
    final service = EpisodeDownloads._(
      library: library,
      settings: settings,
      downloader: downloader,
      documents: documents,
      desktop: desktop,
      availableBytes: availableBytes ?? (() => _freeDiskBytes(documents)),
      prefs: await SharedPreferences.getInstance(),
    );
    try {
      await service._run(() async {
        if (wifiCheck != null) {
          try {
            service._wifi = await wifiCheck().timeout(
              const Duration(seconds: 2),
            );
          } on Object {
            service._wifi = false;
          }
        }
        await service._restore();
        service._restoring = false;
        service._window = service._queueWindow;
        service._autoEnabled = settings.keepQueueDownloaded;
        service._wifiOnly = settings.downloadOnWifiOnly;
        service._library.addListener(service._onQueueChanged);
        service._settings.addListener(service._onSettingsChanged);
        service._wifiChanges = wifiChanges?.listen(service._onWifiChanged);
        await service._reconcile();
      });
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
  final bool _desktop;
  final Future<int?> Function() _availableBytes;
  final SharedPreferences _prefs;
  final _entries = <int, _Download>{};
  late final _manualCopies = (_prefs.getStringList(_manualCopiesKey) ?? [])
      .toSet();
  late final _suppressed = (_prefs.getStringList(_suppressedKey) ?? [])
      .map(int.parse)
      .toSet();
  late final StreamSubscription<TaskUpdate> _updates;
  late final StreamSubscription<int> _finished;
  StreamSubscription<bool>? _wifiChanges;
  Future<void> _commands = Future.value();
  Timer? _storageRetry;
  List<int> _window = const [];
  int? _currentEpisodeId;
  bool _autoEnabled = false;
  late bool _wifiOnly;
  bool _restoring = true;
  bool _wifi = true;
  bool _disposed = false;

  List<int> get _queueWindow => [
    for (final episode in _library.queue.take(2)) episode.id,
  ];

  void setCurrentEpisode(int? id) {
    final previous = _currentEpisodeId;
    if (id == previous) return;
    _currentEpisodeId = id;
    if (previous != null) _background(_run(_reconcile));
  }

  @override
  DownloadInfo statusOf(int episodeId) {
    final entry = _entries[episodeId];
    if (entry == null) return DownloadInfo.none;
    if (!_wifi &&
        entry.task.requiresWiFi &&
        entry.info.status == DownloadStatus.queued) {
      return DownloadInfo(
        DownloadStatus.queued,
        progress: entry.info.progress,
        waitingForWifi: true,
      );
    }
    return entry.info;
  }

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
    await _downloader.start(doRescheduleKilledTasks: !_desktop);
    final records = await _downloader.database.allRecords(group: _downloadGroup)
      ..sort((a, b) => b.task.creationTime.compareTo(a.task.creationTime));
    for (final record in records) {
      if (record.task case final DownloadTask task) {
        final id = _episodeId(task);
        if (id == null) continue;
        if (_entries.containsKey(id) ||
            record.status == TaskStatus.canceled ||
            _shouldDelete(id, downloadCreatedAt: task.creationTime)) {
          await _discard(task, cancel: record.status.isNotFinalState);
          continue;
        }
        final status = switch (record.status) {
          final status when _desktop && status.isNotFinalState =>
            TaskStatus.failed,
          // A persisted running task may be in WorkManager backoff.
          TaskStatus.running => TaskStatus.enqueued,
          final status => status,
        };
        final entry = await _entry(task, status, record.progress);
        if (record.status == TaskStatus.complete &&
            entry.info.status != DownloadStatus.done) {
          await _discard(task, cancel: false);
        } else {
          _entries[id] = entry;
        }
      }
    }
    final taskIds = _entries.values.map((entry) => entry.task.taskId).toSet();
    if (!_manualCopies.every(taskIds.contains)) {
      _manualCopies.retainAll(taskIds);
      await _prefs.setStringList(_manualCopiesKey, _manualCopies.toList());
    }
  }

  @override
  Future<void> download(int episodeId) => _run(() async {
    final episode = _library.episode(episodeId);
    if (episode == null || _library.stateOf(episodeId).isDismissed) return;
    if (_suppressed.remove(episodeId)) await _saveSuppressed();
    final existing = _entries[episodeId];
    if (existing != null && existing.info.status != DownloadStatus.failed) {
      if (_isAutomatic(existing.task) &&
          _manualCopies.add(existing.task.taskId)) {
        await _prefs.setStringList(_manualCopiesKey, _manualCopies.toList());
      }
      return;
    }
    if (existing != null) await _delete(episodeId);
    await _enqueue(episode, automatic: false);
  });

  Future<void> _enqueue(Episode episode, {required bool automatic}) async {
    final episodeId = episode.id;
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
    final wifiOnly = automatic || _settings.downloadOnWifiOnly;
    final task = DownloadTask(
      taskId: taskId,
      url: url.toString(),
      filename: '$taskId$extension',
      directory: _downloadDirectory,
      baseDirectory: BaseDirectory.applicationDocuments,
      group: _downloadGroup,
      updates: Updates.statusAndProgress,
      requiresWiFi: wifiOnly,
      allowPause: true,
      retries: _desktop && wifiOnly ? 0 : 2,
      metaData: automatic ? '$_autoPrefix$episodeId' : '$episodeId',
      displayName: episode.title,
    );
    if (wifiOnly && _desktop && !_wifi) {
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
      if (!automatic) rethrow;
      return;
    }
    _setFailed(episodeId, task);
  }

  void _setFailed(int id, DownloadTask task) {
    _entries[id] = _Download(task, const DownloadInfo(DownloadStatus.failed));
    _notify();
  }

  bool _isAutomatic(DownloadTask task) =>
      task.metaData.startsWith(_autoPrefix) &&
      !_manualCopies.contains(task.taskId);

  int? _episodeId(DownloadTask task) => int.tryParse(
    task.metaData.startsWith(_autoPrefix)
        ? task.metaData.substring(_autoPrefix.length)
        : task.metaData,
  );

  void _onQueueChanged() {
    final window = _queueWindow;
    if (listEquals(window, _window)) return;
    _window = window;
    _background(
      _run(() async {
        await _pruneSuppressed(window);
        await _reconcile();
      }),
    );
  }

  void _onSettingsChanged() {
    final enabled = _settings.keepQueueDownloaded;
    if (enabled != _autoEnabled) {
      _autoEnabled = enabled;
      _background(_run(_reconcile));
    }
    final wifiOnly = _settings.downloadOnWifiOnly;
    if (_wifiOnly && !wifiOnly) _background(_run(_requeueWithoutWifi));
    _wifiOnly = wifiOnly;
  }

  Future<void> _requeueWithoutWifi() async {
    for (final entry in _entries.entries.toList()) {
      if (_settings.downloadOnWifiOnly) return;
      final download = entry.value;
      if (download.info.status != DownloadStatus.queued ||
          !download.task.requiresWiFi ||
          _isAutomatic(download.task)) {
        continue;
      }
      final episode = _library.episode(entry.key);
      if (episode == null) continue;
      await _delete(episode.id);
      await _enqueue(episode, automatic: false);
    }
  }

  void _onWifiChanged(bool wifi) {
    _background(
      _run(() async {
        if (_wifi == wifi) return;
        _wifi = wifi;
        if (!wifi) {
          for (final entry in _entries.entries.toList()) {
            final download = entry.value;
            if (download.task.requiresWiFi &&
                download.info.status == DownloadStatus.running) {
              _entries[entry.key] = _Download(
                download.task,
                DownloadInfo(
                  DownloadStatus.queued,
                  progress: download.info.progress,
                ),
              );
            }
          }
        }
        _notify();
        await _reconcile();
      }),
    );
  }

  Future<void> _reconcile() async {
    _storageRetry?.cancel();
    _storageRetry = null;
    final window = _window;
    await _pruneSuppressed(window);
    for (final entry in _entries.entries.toList()) {
      final id = entry.key;
      if (_isAutomatic(entry.value.task) &&
          id != _currentEpisodeId &&
          _library.stateOf(id).positionMs == 0 &&
          (!_autoEnabled || !window.contains(id) || _suppressed.contains(id))) {
        await _delete(id);
      }
    }
    if (!_autoEnabled || !_wifi || _disposed) return;
    final candidates = _window
        .where((id) => !_entries.containsKey(id) && !_suppressed.contains(id))
        .toList();
    if (candidates.isEmpty) return;

    final free = await _availableBytes();
    var budget = (free ?? 0) - _storageReserve;
    for (final entry in _entries.entries) {
      if (_isAutomatic(entry.value.task) &&
          _isPending(entry.value.info.status)) {
        budget -= _sizeOf(entry.key);
      }
    }
    for (final id in candidates) {
      if (!_window.contains(id) || !_autoEnabled || !_wifi || _disposed) return;
      final episode = _library.episode(id);
      if (episode == null ||
          _library.stateOf(id).status != EpisodeStatus.none) {
        continue;
      }
      final size = _sizeOf(id);
      if (budget <= 0 || size > budget) {
        _storageRetry ??= Timer(
          const Duration(minutes: 1),
          () => _background(_run(_reconcile)),
        );
        break;
      }
      await _enqueue(episode, automatic: true);
      budget -= size;
    }
  }

  int _sizeOf(int id) => max(0, _library.episode(id)?.enclosureLength ?? 0);

  Future<void> _pruneSuppressed(List<int> window) async {
    if (_suppressed.every(window.contains)) return;
    _suppressed.retainAll(window);
    await _saveSuppressed();
  }

  Future<void> _saveSuppressed() async {
    await _prefs.setStringList(_suppressedKey, [
      for (final id in _suppressed) '$id',
    ]);
  }

  @override
  Future<void> delete(int episodeId) => _run(() async {
    if (_window.contains(episodeId) && _suppressed.add(episodeId)) {
      await _saveSuppressed();
    }
    await _delete(episodeId);
    await _reconcile();
  });

  bool _shouldDelete(int id, {DateTime? downloadCreatedAt}) {
    final state = _library.stateOf(id);
    return state.isDismissed ||
        (state.isPlayed &&
            _settings.deleteAfterPlayed &&
            (downloadCreatedAt == null ||
                !state.updatedAt.isBefore(downloadCreatedAt)));
  }

  bool _isPending(DownloadStatus status) =>
      status == DownloadStatus.queued || status == DownloadStatus.running;

  Future<void> _delete(int id) async {
    final entry = _entries[id];
    if (entry == null) return;
    await _discard(entry.task, cancel: _isPending(entry.info.status));
    _entries.remove(id);
    if (_manualCopies.remove(entry.task.taskId)) {
      await _prefs.setStringList(_manualCopiesKey, _manualCopies.toList());
    }
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
      TaskStatus.running =>
        !_wifi && task.requiresWiFi
            ? DownloadStatus.queued
            : DownloadStatus.running,
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
    final id = _episodeId(task);
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
        _entries[id] = await _entry(task, TaskStatus.running, progress);
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
    _storageRetry?.cancel();
    _library.removeListener(_onQueueChanged);
    _settings.removeListener(_onSettingsChanged);
    unawaited(_wifiChanges?.cancel());
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

Future<int?> _freeDiskBytes(Directory directory) async {
  try {
    if (Platform.isAndroid) {
      return await androidPlatform.invokeMethod<int>('availableBytes');
    }
    while (!await directory.exists() &&
        directory.parent.path != directory.path) {
      directory = directory.parent;
    }
    final result = await Process.run('df', [
      '-P',
      '-k',
      directory.path,
    ]).timeout(const Duration(seconds: 2));
    if (result.exitCode != 0) return null;
    final available = RegExp(r'\s+\d+\s+\d+\s+(\d+)\s+\d+%\s')
        .firstMatch(result.stdout as String)
        ?.group(1);
    return available == null ? null : int.parse(available) * 1024;
  } on Object {
    return null;
  }
}
