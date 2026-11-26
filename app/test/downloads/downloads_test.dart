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

  Future<EpisodeDownloads> open({Future<bool> Function()? linuxHasWifi}) =>
      EpisodeDownloads.open(
        library: library,
        settings: settings,
        downloader: downloader,
        documents: documents,
        linuxHasWifi: linuxHasWifi,
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = await Settings.load();
    library = _Library();
    downloader = _Downloader();
    documents = await Directory.systemTemp.createTemp('easypodcast-downloads-');
    downloads = await open();
  });
  tearDown(() async {
    downloads.dispose();
    await downloader.events.close();
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

  Future<File> saveDownload(int id) async {
    await downloads.download(id);
    final task = downloader.enqueued.last;
    final file = File(path.join(documents.path, task.directory, task.filename));
    await file.create(recursive: true);
    await file.writeAsBytes([1, 2, 3]);
    downloader.emitStatus(task, TaskStatus.complete);
    await waitFor(() => downloads.statusOf(id).status == DownloadStatus.done);
    return file;
  }

  test(
    'reports progress, respects Wi-Fi preference and restores a file',
    () async {
      await downloads.download(1);
      final task = downloader.enqueued.single;
      expect(task.requiresWiFi, isTrue);
      expect(task.baseDirectory, BaseDirectory.applicationDocuments);
      expect(downloads.statusOf(1).status, DownloadStatus.queued);

      downloader.events.add(TaskProgressUpdate(task, 0.4));
      await waitFor(() => downloads.statusOf(1).progress == 0.4);
      expect(downloads.statusOf(1).status, DownloadStatus.running);

      settings.downloadOnWifiOnly = false;
      final file = await saveDownload(2);
      expect(downloader.enqueued.last.requiresWiFi, isFalse);
      expect(downloads.downloadedEpisodeIds, [2]);

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

  test('Linux blocks new Wi-Fi-only downloads on other connections', () async {
    downloads.dispose();
    downloads = await open(linuxHasWifi: () async => false);

    await downloads.download(1);
    expect(downloader.enqueued, isEmpty);
    expect(downloads.statusOf(1).status, DownloadStatus.failed);

    settings.downloadOnWifiOnly = false;
    await downloads.download(1);
    expect(downloader.enqueued.single.requiresWiFi, isFalse);
  });

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
}

class _Library extends Library {
  final finished = StreamController<int>.broadcast(sync: true);
  final states = <int, EpisodeState>{};

  @override
  Stream<int> get finishedEpisodes => finished.stream;

  @override
  Episode episode(int id) => Episode(
    id: id,
    podcastId: 1,
    guid: '$id',
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

  @override
  Future<void> start({
    bool doTrackTasks = true,
    bool markDownloadedComplete = true,
    bool doRescheduleKilledTasks = true,
    bool autoCleanDatabase = false,
  }) async {}

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
