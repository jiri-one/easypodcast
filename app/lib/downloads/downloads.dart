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
import '../platform/command_queue.dart';

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
  if (Platform.isLinux) return _NoDownloads();
  final documents = await getApplicationDocumentsDirectory();
  final connectivity = Connectivity();
  bool hasWifi(List<ConnectivityResult> results) =>
      results.contains(ConnectivityResult.wifi);

  return EpisodeDownloads.open(
    library: library,
    settings: settings,
    downloader: FileDownloader(),
    documents: documents,
    wifiCheck: () async => hasWifi(await connectivity.checkConnectivity()),
    wifiChanges: connectivity.onConnectivityChanged.map(hasWifi).distinct(),
  );
}

class _NoDownloads extends DownloadService {
  @override
  DownloadInfo statusOf(int episodeId) => DownloadInfo.none;

  @override
  String? localFileOf(int episodeId) => null;

  @override
  List<int> get downloadedEpisodeIds => const [];

  @override
  Future<void> download(int episodeId) async {}

  @override
  Future<void> delete(int episodeId) async {}
}

class EpisodeDownloads extends DownloadService {
  EpisodeDownloads._({
    required this._library,
    required this._settings,
    required this._downloader,
    required this._documents,
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
      background(_commands.run(() => _onUpdate(update)));
    });
    _finished = _library.finishedEpisodes.listen((id) {
      background(
        _commands.run(() async {
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
    Future<bool> Function()? wifiCheck,
    Stream<bool>? wifiChanges,
    Future<int?> Function()? availableBytes,
  }) async {
    final service = EpisodeDownloads._(
      library: library,
      settings: settings,
      downloader: downloader,
      documents: documents,
      availableBytes: availableBytes ?? _freeDiskBytes,
      prefs: await SharedPreferences.getInstance(),
    );
    try {
      await service._commands.run(() async {
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
        service._library.addListener(service._onLibraryChanged);
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
  final _commands = CommandQueue();
  Timer? _storageRetry;
  List<int> _window = const [];
  int? _currentEpisodeId;
  bool _autoEnabled = false;
  late bool _wifiOnly;
  bool _restoring = true;
  bool _wifi = true;

  bool get _disposed => _commands.isClosed;

  List<int> get _queueWindow => [
    for (final episode in _library.queue.take(2)) episode.id,
  ];

  void setCurrentEpisode(int? id) {
    final previous = _currentEpisodeId;
    if (id == previous) return;
    _currentEpisodeId = id;
    if (previous != null) background(_commands.run(_reconcile));
  }

  @override
  DownloadInfo statusOf(int episodeId) {
    final entry = _entries[episodeId];
    if (entry == null || _isStale(episodeId, entry.task)) {
      return DownloadInfo.none;
    }
    if (entry.completedAt != null) {
      return DownloadInfo(
        DownloadStatus.done,
        progress: 1,
        filePath: _file(entry.task).path,
      );
    }
    final wifiBlocked = !_wifi && entry.task.requiresWiFi;
    final status = switch (entry.status) {
      TaskStatus.running when !wifiBlocked => DownloadStatus.running,
      final taskStatus when taskStatus.isNotFinalState => DownloadStatus.queued,
      TaskStatus.canceled => DownloadStatus.none,
      _ => DownloadStatus.failed,
    };
    return DownloadInfo(
      status,
      progress: entry.progress.clamp(0.0, 1.0),
      waitingForWifi: wifiBlocked && status == DownloadStatus.queued,
    );
  }

  @override
  String? localFileOf(int episodeId) =>
      _library.episode(episodeId) == null ? null : statusOf(episodeId).filePath;

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

  @override
  List<int> get episodeIds => [
    for (final entry in _entries.entries)
      if (entry.value.completedAt == null) entry.key,
    ...downloadedEpisodeIds,
  ];

  Future<void> _restore() async {
    await _downloader.start();
    final records = await _downloader.database.allRecords(group: _downloadGroup)
      ..sort((a, b) => b.task.creationTime.compareTo(a.task.creationTime));
    for (final record in records) {
      if (record.task case final DownloadTask task) {
        final id = _episodeId(task);
        if (id == null) continue;
        if (_entries.containsKey(id) ||
            record.status == TaskStatus.canceled ||
            _isStale(id, task) ||
            _shouldDelete(id, downloadCreatedAt: task.creationTime)) {
          await _discard(task, cancel: record.status.isNotFinalState);
          continue;
        }
        // A persisted running task may be in WorkManager backoff.
        final status = record.status == TaskStatus.running
            ? TaskStatus.enqueued
            : record.status;
        final entry = await _entry(task, status, record.progress);
        if (record.status == TaskStatus.complete && entry.completedAt == null) {
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
  Future<void> download(int episodeId) => _commands.run(() async {
    final episode = _library.episode(episodeId);
    if (episode == null || _library.stateOf(episodeId).isDismissed) return;
    if (_suppressed.remove(episodeId)) await _saveSuppressed();
    final existing = _entries[episodeId];
    final status = statusOf(episodeId).status;
    if (existing != null &&
        status != DownloadStatus.none &&
        status != DownloadStatus.failed) {
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
      retries: 2,
      metaData: automatic ? '$_autoPrefix$episodeId' : '$episodeId',
      displayName: episode.title,
    );
    _entries[episodeId] = _Download(task, TaskStatus.enqueued);
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
    _entries[id] = _Download(task, TaskStatus.failed);
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

  bool _isStale(int id, DownloadTask task) {
    final episode = _library.episode(id);
    if (episode == null) return _library.podcasts.isNotEmpty;
    return Uri.tryParse(episode.enclosureUrl)?.toString() != task.url;
  }

  void _onLibraryChanged() {
    final window = _queueWindow;
    if (listEquals(window, _window) &&
        !_entries.entries.any(
          (entry) => _isStale(entry.key, entry.value.task),
        )) {
      return;
    }
    _window = window;
    background(
      _commands.run(() async {
        await _pruneSuppressed(window);
        await _reconcile();
      }),
    );
  }

  void _onSettingsChanged() {
    final enabled = _settings.keepQueueDownloaded;
    if (enabled != _autoEnabled) {
      _autoEnabled = enabled;
      background(_commands.run(_reconcile));
    }
    final wifiOnly = _settings.downloadOnWifiOnly;
    if (_wifiOnly && !wifiOnly) background(_commands.run(_requeueWithoutWifi));
    _wifiOnly = wifiOnly;
  }

  Future<void> _requeueWithoutWifi() async {
    for (final entry in _entries.entries.toList()) {
      if (_settings.downloadOnWifiOnly) return;
      final download = entry.value;
      if (statusOf(entry.key).status != DownloadStatus.queued ||
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
    background(
      _commands.run(() async {
        if (_wifi == wifi) return;
        _wifi = wifi;
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
      if (_isStale(id, entry.value.task) ||
          (_isAutomatic(entry.value.task) &&
              id != _currentEpisodeId &&
              _library.stateOf(id).positionMs == 0 &&
              (!_autoEnabled ||
                  !window.contains(id) ||
                  _suppressed.contains(id)))) {
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
          entry.value.status.isNotFinalState) {
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
          () => background(_commands.run(_reconcile)),
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
  Future<void> delete(int episodeId) => _commands.run(() async {
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

  Future<void> _delete(int id) async {
    final entry = _entries[id];
    if (entry == null) return;
    await _discard(entry.task, cancel: entry.status.isNotFinalState);
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
    DateTime? completedAt;
    if (status == TaskStatus.complete) {
      final stat = await _file(task).stat();
      if (stat.type == FileSystemEntityType.file) completedAt = stat.modified;
    }
    return _Download(
      task,
      status,
      progress: progress,
      completedAt: completedAt,
    );
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
    if (previous!.completedAt != null) return;

    switch (update) {
      case TaskStatusUpdate(status: TaskStatus.canceled):
        await _discard(task, cancel: false);
        _entries.remove(id);
      case TaskStatusUpdate(:final status):
        _entries[id] = await _entry(task, status, previous.progress);
      case TaskProgressUpdate(:final progress)
          when progress >= 0 && progress < 1:
        _entries[id] = _Download(task, TaskStatus.running, progress: progress);
      default:
        return;
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_commands.close());
    _storageRetry?.cancel();
    _library.removeListener(_onLibraryChanged);
    _settings.removeListener(_onSettingsChanged);
    unawaited(_wifiChanges?.cancel());
    unawaited(_updates.cancel());
    unawaited(_finished.cancel());
    super.dispose();
  }
}

class _Download {
  const _Download(
    this.task,
    this.status, {
    this.progress = 0,
    this.completedAt,
  });

  final DownloadTask task;
  final TaskStatus status;
  final double progress;
  final DateTime? completedAt;
}

Future<int?> _freeDiskBytes() async {
  try {
    return await androidPlatform.invokeMethod<int>('availableBytes');
  } on Object {
    return null;
  }
}
