import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:easypodcast/core/downloads.dart';
import 'package:easypodcast/core/library.dart';
import 'package:easypodcast/core/models.dart';
import 'package:easypodcast/core/settings.dart';
import 'package:easypodcast/downloads/downloads.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Settings settings;
  late _Library library;
  late _Downloader downloader;
  late Directory documents;
  late EpisodeDownloads downloads;
  late StreamController<bool> wifiChanges;
  late bool wifi;
  late int availableBytes;

  Future<EpisodeDownloads> open() => EpisodeDownloads.open(
    library: library,
    settings: settings,
    downloader: downloader,
    documents: documents,
    wifiCheck: () async => wifi,
    wifiChanges: wifiChanges.stream,
    availableBytes: () async => availableBytes,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = await Settings.load();
    library = _Library();
    downloader = _Downloader();
    documents = await Directory.systemTemp.createTemp('easypodcast-downloads-');
    wifi = true;
    wifiChanges = StreamController<bool>.broadcast();
    availableBytes = 1 << 30;
    downloads = await open();
  });
  tearDown(() async {
    downloads.dispose();
    await downloader.events.close();
    await wifiChanges.close();
    await library.finished.close();
    library.dispose();
    settings.dispose();
    await documents.delete(recursive: true);
  });

  Future<void> waitFor(bool Function() condition) async {
    if (condition()) return;
    final changed = Completer<void>();
    void check() {
      if (condition() && !changed.isCompleted) changed.complete();
    }

    downloads.addListener(check);
    try {
      await changed.future.timeout(const Duration(seconds: 3));
    } finally {
      downloads.removeListener(check);
    }
  }

  Future<File> completeDownload(int id, DownloadTask task) async {
    final file = File(path.join(documents.path, task.directory, task.filename));
    await file.create(recursive: true);
    await file.writeAsBytes([1, 2, 3]);
    downloader.emitStatus(task, TaskStatus.complete);
    await waitFor(() => downloads.statusOf(id).status == DownloadStatus.done);
    return file;
  }

  Future<File> saveDownload(int id) async {
    await downloads.download(id);
    return completeDownload(id, downloader.enqueued.last);
  }

  test(
    'reports progress, respects Wi-Fi preference and restores a file',
    () async {
      await downloads.download(1);
      final task = downloader.enqueued.single;
      expect(task.requiresWiFi, isTrue);
      expect(task.allowPause, isTrue);
      expect(task.baseDirectory, BaseDirectory.applicationDocuments);
      expect(downloads.statusOf(1).status, DownloadStatus.queued);
      expect(downloads.episodeIds, [1]);

      downloader.events.add(TaskProgressUpdate(task, 0.4));
      await waitFor(() => downloads.statusOf(1).progress == 0.4);
      expect(downloads.statusOf(1).status, DownloadStatus.running);

      settings.downloadOnWifiOnly = false;
      final file = await saveDownload(2);
      expect(downloader.enqueued.last.requiresWiFi, isFalse);
      expect(downloads.downloadedEpisodeIds, [2]);
      expect(downloads.episodeIds, [1, 2]);

      downloads.dispose();
      downloads = await open();
      expect(downloads.downloadedEpisodeIds, [2]);
      expect(downloads.localFileOf(2), file.path);
    },
  );

  test(
    'finished events delete played episodes only with the setting enabled',
    () async {
      settings.deleteAfterPlayed = false;
      final retained = await saveDownload(1);
      final removed = await saveDownload(2);

      library.finish(1, EpisodeStatus.played);
      await downloads.download(1);
      expect(await retained.exists(), isTrue);

      settings.deleteAfterPlayed = true;
      library.finish(2, EpisodeStatus.played);
      await waitFor(() => downloads.statusOf(2).status == DownloadStatus.none);
      expect(await removed.exists(), isFalse);
      expect(await retained.exists(), isTrue);
    },
  );

  test('Linux opens a no-op download service', () async {
    final service = await openDownloads(library: library, settings: settings);
    addTearDown(service.dispose);
    await service.download(1);
    await service.delete(1);
    expect(service.statusOf(1), DownloadInfo.none);
    expect(service.localFileOf(1), isNull);
    expect(service.episodeIds, isEmpty);
  }, skip: !Platform.isLinux);

  test('dismissal always deletes and cancels unfinished work', () async {
    settings.deleteAfterPlayed = false;
    final file = await saveDownload(1);
    await downloads.download(2);
    final pending = downloader.enqueued.last;

    library.finish(1, EpisodeStatus.dismissed);
    library.finish(2, EpisodeStatus.dismissed);
    await waitFor(() => downloads.statusOf(2).status == DownloadStatus.none);

    expect(downloads.downloadedEpisodeIds, isEmpty);
    expect(await file.exists(), isFalse);
    expect(downloader.canceled, [pending.taskId]);
  });

  test(
    'a restored running task and stale progress wait for a live worker',
    () async {
      await downloads.download(1);
      final task = downloader.enqueued.single;
      downloader.emitStatus(task, TaskStatus.running);
      await waitFor(
        () => downloads.statusOf(1).status == DownloadStatus.running,
      );
      downloads.dispose();
      downloader.onStart = () {
        downloader.events.add(TaskProgressUpdate(task, 0.2));
        downloader.emitStatus(task, TaskStatus.running);
      };

      downloads = await open();
      expect(downloads.statusOf(1).status, DownloadStatus.queued);
      downloader.events.add(TaskProgressUpdate(task, 0.4));
      await waitFor(() => downloads.statusOf(1).progress == 0.4);
      expect(downloads.statusOf(1).status, DownloadStatus.running);

      downloader.emitStatus(task, TaskStatus.paused);
      await waitFor(
        () => downloads.statusOf(1).status == DownloadStatus.queued,
      );
      downloader.events.add(TaskProgressUpdate(task, 0.6));
      await waitFor(() => downloads.statusOf(1).progress == 0.6);
      expect(downloads.statusOf(1).status, DownloadStatus.running);
      expect(downloader.enqueued, [task]);
    },
  );

  test(
    'Android Wi-Fi wait tracks connectivity and the task constraint',
    () async {
      downloads.dispose();
      wifi = false;
      downloads = await open();
      await downloads.download(1);
      expect(downloads.statusOf(1).status, DownloadStatus.queued);
      expect(downloads.statusOf(1).waitingForWifi, isTrue);

      wifiChanges.add(true);
      await waitFor(() => !downloads.statusOf(1).waitingForWifi);
      expect(downloads.statusOf(1).status, DownloadStatus.queued);
      final task = downloader.enqueued.first;
      downloader.emitStatus(task, TaskStatus.running);
      await waitFor(
        () => downloads.statusOf(1).status == DownloadStatus.running,
      );
      wifiChanges.add(false);
      await waitFor(() => downloads.statusOf(1).waitingForWifi);
      expect(downloads.statusOf(1).status, DownloadStatus.queued);
    },
  );

  test('turning off Wi-Fi only replaces waiting manual downloads', () async {
    settings.keepQueueDownloaded = true;
    library.updateQueue([2]);
    await waitFor(() => downloads.statusOf(2).status == DownloadStatus.queued);
    final automatic = downloader.enqueued.single;
    wifiChanges.add(false);
    await waitFor(() => downloads.statusOf(2).waitingForWifi);
    await downloads.download(1);
    final waiting = downloader.enqueued.last;
    expect(downloads.statusOf(1).waitingForWifi, isTrue);

    settings.downloadOnWifiOnly = false;
    await waitFor(
      () =>
          downloads.statusOf(1).status == DownloadStatus.queued &&
          !downloads.statusOf(1).waitingForWifi &&
          downloader.enqueued.length == 3,
    );
    final replacement = downloader.enqueued.last;
    expect(replacement.taskId, isNot(waiting.taskId));
    expect(replacement.requiresWiFi, isFalse);
    expect(downloader.canceled, [waiting.taskId]);
    expect(automatic.requiresWiFi, isTrue);
    expect(downloads.statusOf(2).waitingForWifi, isTrue);

    downloader.emitStatus(waiting, TaskStatus.canceled);
    downloader.emitStatus(replacement, TaskStatus.running);
    await waitFor(() => downloads.statusOf(1).status == DownloadStatus.running);
  });

  test(
    'queue download fills two slots on Wi-Fi and preserves manual copies',
    () async {
      final manual = await saveDownload(3);
      settings.downloadOnWifiOnly = false;
      expect(settings.keepQueueDownloaded, isFalse);
      settings.keepQueueDownloaded = true;
      expect((await Settings.load()).keepQueueDownloaded, isTrue);
      library.updateQueue([1, 2, 3]);
      await waitFor(
        () => downloads.statusOf(2).status == DownloadStatus.queued,
      );
      final firstTwo = downloader.enqueued.skip(1).toList();
      expect(firstTwo.map((task) => task.metaData), ['auto:1', 'auto:2']);
      expect(
        firstTwo.every((task) => task.requiresWiFi && task.allowPause),
        isTrue,
      );
      await downloads.download(2);
      downloads.dispose();
      downloads = await open();

      library.updateQueue([3, 4, 5]);
      await waitFor(
        () => downloads.statusOf(4).status == DownloadStatus.queued,
      );
      expect(downloader.canceled, [firstTwo.first.taskId]);
      expect(downloads.statusOf(2).status, DownloadStatus.queued);
      expect(await manual.exists(), isTrue);
      expect(downloads.statusOf(5).status, DownloadStatus.none);
      settings.keepQueueDownloaded = false;
      await waitFor(() => downloads.statusOf(4).status == DownloadStatus.none);
      expect(downloads.statusOf(2).status, DownloadStatus.queued);
      expect(await manual.exists(), isTrue);
    },
  );

  test(
    'queue prefetch keeps the current and in-progress files outside the window',
    () async {
      settings.keepQueueDownloaded = true;
      library.updateQueue([1, 2, 3]);
      await waitFor(
        () => downloads.statusOf(2).status == DownloadStatus.queued,
      );
      final first = await completeDownload(1, downloader.enqueued.first);
      final second = await completeDownload(2, downloader.enqueued[1]);
      library.states[2] = EpisodeState(
        episodeId: 2,
        positionMs: 10000,
        status: EpisodeStatus.none,
        updatedAt: DateTime.utc(2026),
      );
      downloads.setCurrentEpisode(1);
      library.updateQueue([3, 4]);
      await waitFor(
        () => downloads.statusOf(4).status == DownloadStatus.queued,
      );
      expect(await first.exists(), isTrue);
      expect(await second.exists(), isTrue);

      downloads.setCurrentEpisode(null);
      await waitFor(() => downloads.localFileOf(1) == null);
      expect(await first.exists(), isFalse);
      expect(await second.exists(), isTrue);
      library.finish(2, EpisodeStatus.played);
      await waitFor(() => downloads.localFileOf(2) == null);
      expect(await second.exists(), isFalse);
    },
  );

  test('manual queue deletion survives restart until its episode leaves the window', () async {
    settings.keepQueueDownloaded = true;
    library.updateQueue([1, 2, 3]);
    await waitFor(() => downloads.statusOf(2).status == DownloadStatus.queued);
    await downloads.delete(1);
    expect(downloads.statusOf(1).status, DownloadStatus.none);
    downloads.dispose();
    downloads = await open();
    expect(downloads.statusOf(1).status, DownloadStatus.none);
    library.updateQueue([2, 1, 3]);
    await downloads.delete(4);
    expect(
      downloader.enqueued.where((task) => task.metaData == 'auto:1'),
      hasLength(1),
    );
    library.updateQueue([2, 3, 1]);
    await waitFor(() => downloads.statusOf(3).status == DownloadStatus.queued);

    library.updateQueue([1, 2, 3]);
    await waitFor(() => downloads.statusOf(1).status == DownloadStatus.queued);
    expect(
      downloader.enqueued.where((task) => task.metaData == 'auto:1'),
      hasLength(2),
    );
  });

  test(
    'automatic work waits for both Wi-Fi and space above the storage reserve',
    () async {
      downloads.dispose();
      wifi = false;
      availableBytes = 12;
      library.updateQueue([1, 2]);
      settings.keepQueueDownloaded = true;
      downloads = await open();
      expect(downloader.enqueued, isEmpty);
      wifiChanges.add(true);
      await downloads.delete(4);
      expect(downloader.enqueued, isEmpty);

      availableBytes = 1 << 30;
      library.updateQueue([2, 1]);
      await waitFor(
        () => downloads.statusOf(1).status == DownloadStatus.queued,
      );
      expect(downloader.enqueued.map((task) => task.metaData), [
        'auto:2',
        'auto:1',
      ]);
    },
  );
}

class _Library extends Library {
  final finished = StreamController<int>.broadcast(sync: true);
  final states = <int, EpisodeState>{};
  List<int> _queued = [];

  @override
  List<Episode> get queue => [
    for (final id in _queued)
      if (stateOf(id).status == EpisodeStatus.none) episode(id),
  ];

  void updateQueue(List<int> ids) {
    _queued = ids;
    notifyListeners();
  }

  @override
  Stream<int> get finishedEpisodes => finished.stream;

  @override
  Episode episode(int id) => Episode(
    id: id,
    podcastId: 1,
    title: 'Field Notes $id',
    enclosureUrl: 'https://example.test/$id.mp3',
  );

  @override
  EpisodeState stateOf(int id) => states[id] ?? EpisodeState.initial(id);

  void finish(int id, EpisodeStatus status) {
    states[id] = EpisodeState(
      episodeId: id,
      positionMs: 0,
      status: status,
      updatedAt: DateTime.utc(2026),
    );
    finished.add(id);
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Downloader implements FileDownloader {
  final events = StreamController<TaskUpdate>.broadcast();

  @override
  Stream<TaskUpdate> get updates => events.stream;

  @override
  final _Database database = _Database();

  final enqueued = <DownloadTask>[];
  final canceled = <String>[];
  void Function()? onStart;

  @override
  Future<void> start({
    bool doTrackTasks = true,
    bool markDownloadedComplete = true,
    bool doRescheduleKilledTasks = true,
    bool autoCleanDatabase = false,
  }) async => onStart?.call();

  @override
  Future<bool> enqueue(Task task) async {
    enqueued.add(task as DownloadTask);
    emitStatus(task, TaskStatus.enqueued);
    return true;
  }

  @override
  Future<bool> cancelTaskWithId(String id) async {
    canceled.add(id);
    return true;
  }

  void emitStatus(DownloadTask task, TaskStatus status) {
    database.records[task.taskId] = TaskRecord(task, status, 0, -1);
    events.add(TaskStatusUpdate(task, status));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Database implements Database {
  final records = <String, TaskRecord>{};

  @override
  Future<List<TaskRecord>> allRecords({String? group}) async => records.values
      .where((record) => group == null || record.group == group)
      .toList();

  @override
  Future<void> deleteRecordWithId(String id) async => records.remove(id);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
