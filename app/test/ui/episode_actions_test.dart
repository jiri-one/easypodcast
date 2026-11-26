import 'dart:async';

import 'package:easypodcast/core/downloads.dart';
import 'package:easypodcast/core/models.dart';
import 'package:easypodcast/ui/eink_widgets.dart';
import 'package:easypodcast/ui/episode_page.dart';
import 'package:easypodcast/ui/library_views.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'fixtures/demo_downloads.dart';
import 'fixtures/demo_library.dart';
import 'fixtures/demo_sync.dart';
import 'ui_test_support.dart';

final _dialog = find.byType(EinkDialogPanel);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadTestFonts);

  testWidgets(
    'in-progress menu plays from the saved position and confirms dismissal',
    (tester) async {
      final app = await _phone(tester);
      final l = app.strings;
      final library = app.services.library;
      final player = app.services.player;
      try {
        await app.holdRow(app.episode(204));
        expect(_labels(tester), [
          l.playFrom('41:00'),
          l.addToQueue,
          l.markPlayed,
          l.dismiss,
          l.deleteFile,
        ]);
        await app.dialog(l.dismiss);
        expect(find.text(l.dismissPositionAndFile('41:00')), findsOneWidget);
        await app.dialog(l.cancel);
        expect(library.stateOf(204).isInProgress, isTrue);

        await app.holdRow(app.episode(204));
        await app.dialog(l.playFrom('41:00'));
        expect(player.current?.id, 204);
        expect(player.position.value, const Duration(minutes: 41));
        expect(_dialog, findsNothing);
        expect(find.byType(EpisodePage), findsNothing);

        await app.holdRow(app.episode(204));
        await app.dialog(l.dismiss);
        await app.dialog(l.dismiss);
        expect(library.stateOf(204).isDismissed, isTrue);
        expect(player.current, isNull);
        expect(
          app.services.downloads.statusOf(204).status,
          DownloadStatus.none,
        );
      } finally {
        await app.finish();
      }
    },
  );

  testWidgets(
    'new-episode menu adds and removes queue entries and dismisses older episodes',
    (tester) async {
      final app = await _phone(tester);
      final l = app.strings;
      final library = app.services.library;
      final initialQueue = library.queue;
      try {
        await app.section(LibrarySection.newEpisodes);
        final title = app.episode(201);
        await app.holdRow(title);
        expect(_labels(tester), [
          l.play,
          l.addToQueue,
          l.markPlayed,
          l.dismiss,
          l.download,
          l.dismissOlder,
        ]);
        await app.dialog(l.addToQueue);
        expect(library.queue.last.id, 201);
        expect(_dialog, findsNothing);

        await app.holdRow(title);
        expect(_labels(tester), contains(l.removeFromQueue));
        expect(_labels(tester), isNot(contains(l.dismissOlder)));
        await app.dialog(l.removeFromQueue);
        expect(library.queue, initialQueue);

        final eligible = library
            .episodesOf(2)
            .where(
              (episode) =>
                  library.stateOf(episode.id).isNew &&
                  !initialQueue.contains(episode),
            )
            .length;
        await app.holdRow(title);
        await app.dialog(l.dismissOlder);
        expect(find.text(l.dismissCountTitle(eligible)), findsOneWidget);
        await app.dialog(l.dismissCount(eligible));
        expect(library.stateOf(201).isDismissed, isTrue);
        expect(library.stateOf(203).isNew, isTrue);
        expect(library.stateOf(204).isInProgress, isTrue);
        expect(library.queue, initialQueue);
      } finally {
        await app.finish();
      }
    },
  );

  testWidgets(
    'podcast episodes can be marked played, returned to new, and dismissed',
    (tester) async {
      final app = await _phone(tester);
      final l = app.strings;
      final library = app.services.library;
      try {
        await app.section(LibrarySection.podcasts);
        await app.scrollToRow(
          library.podcast(2)!.title,
          find.byType(PodcastList),
        );
        final title = app.episode(201);

        await app.holdRow(title);
        await app.dialog(l.markPlayed);
        expect(library.stateOf(201).isPlayed, isTrue);

        await app.holdRow(title);
        expect(_labels(tester), [l.play, l.addToQueue, l.markNew, l.download]);
        await app.dialog(l.markNew);
        expect(library.stateOf(201).isNew, isTrue);

        await app.holdRow(title);
        await app.dialog(l.dismiss);
        expect(library.stateOf(201).isDismissed, isTrue);
        expect(_dialog, findsNothing);

        await app.holdRow(title);
        expect(_labels(tester), [
          l.play,
          l.addToQueue,
          l.markPlayed,
          l.markNew,
        ]);
      } finally {
        await app.finish();
      }
    },
  );

  testWidgets('download actions add and delete a file through the list menu', (
    tester,
  ) async {
    final app = await _phone(tester);
    final l = app.strings;
    final downloads = app.services.downloads;
    final title = app.episode(201);
    try {
      await app.section(LibrarySection.newEpisodes);
      await app.holdRow(title);
      await app.dialog(l.download);
      expect(downloads.statusOf(201).status, DownloadStatus.done);
      expect(_dialog, findsNothing);
      _expectDownloadMarker(tester, title, l.stateDownloaded);

      await app.section(LibrarySection.downloads);
      _expectDownloadMarker(tester, title, l.stateDownloaded);
      await app.holdRow(title);
      await app.dialog(l.deleteFile);
      expect(downloads.statusOf(201).status, DownloadStatus.none);
      expect(find.widgetWithText(EinkRow, title), findsNothing);
      expect(_dialog, findsNothing);
    } finally {
      await app.finish();
    }
  });

  testWidgets(
    'the episode download button keeps its outline and updates in 10% steps',
    (tester) async {
      final app = await _phone(tester);
      final downloads = app.services.downloads as DemoDownloadService;
      final l = app.strings;
      try {
        await app.section(LibrarySection.queue);
        await app.row(l.numberedTitle(1, app.episode(203)));
        final original = tester.getRect(
          find.widgetWithText(EinkButton, l.download),
        );

        (app.services.sync as DemoSyncService).setOffline();
        downloads.queueDownload(203, waitingForWifi: true);
        await tester.pumpAndSettle();
        expect(find.text(l.waitingForWifi), findsOneWidget);
        expect(
          tester.getRect(find.widgetWithText(EinkButton, l.waitingForWifi)),
          original,
        );

        _reportProgress(downloads, 203, 0.41);
        await tester.pumpAndSettle();
        final forty = find.widgetWithText(EinkButton, l.downloadProgress(40));
        final button = tester.widget<EinkButton>(forty);
        expect(button.progress, 40);
        expect(tester.getRect(forty), original);
        expect(
          find.descendant(of: forty, matching: find.byType(OutlinedButton)),
          findsOneWidget,
        );

        _reportProgress(downloads, 203, 0.49);
        await tester.pumpAndSettle();
        expect(tester.widget<EinkButton>(forty), same(button));

        _reportProgress(downloads, 203, 0.50);
        await tester.pumpAndSettle();
        expect(find.text(l.downloadProgress(50)), findsOneWidget);
        expect(forty, findsNothing);

        downloads.setDownloadInfo(
          203,
          const DownloadInfo(DownloadStatus.failed),
        );
        await tester.pumpAndSettle();
        final failed = tester.widget<EinkButton>(
          find.widgetWithText(EinkButton, l.retryDownload),
        );
        expect(failed.error, isTrue);
        await app.tapText(l.retryDownload);
        expect(find.widgetWithText(EinkButton, l.deleteFile), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await app.finish();
      }
    },
  );

  testWidgets('list and menu share progress steps and cancellation', (
    tester,
  ) async {
    final app = await _phone(tester);
    final downloads = app.services.downloads as DemoDownloadService;
    final l = app.strings;
    final title = app.episode(704);
    try {
      _reportProgress(downloads, 704, 0.42);
      await tester.pumpAndSettle();
      final row = find.widgetWithText(EinkRow, title);
      final forty = find.descendant(
        of: row,
        matching: find.textContaining(l.stateDownloading(40)),
      );
      final status = tester.widget<Text>(forty);
      _expectDownloadMarker(tester, app.episode(101), l.stateDownloaded);

      _reportProgress(downloads, 704, 0.48);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(forty), same(status));
      await app.holdRow(title);
      expect(_labels(tester), contains(l.downloadProgress(40)));

      _reportProgress(downloads, 704, 0.51);
      await tester.pumpAndSettle();
      expect(_labels(tester), contains(l.downloadProgress(50)));
      expect(find.textContaining(l.stateDownloading(50)), findsOneWidget);

      await app.dialog(l.downloadProgress(50));
      expect(find.text(l.cancelDownloadTitle), findsOneWidget);
      await app.dialog(l.cancel);
      expect(downloads.statusOf(704).status, DownloadStatus.running);

      await app.holdRow(title);
      await app.dialog(l.downloadProgress(50));
      await app.dialog(l.cancelDownload);
      expect(downloads.statusOf(704).status, DownloadStatus.none);
      expect(_dialog, findsNothing);
      expect(find.textContaining(l.stateDownloading(50)), findsNothing);
    } finally {
      await app.finish();
    }
  });

  testWidgets('the download service controls the Wi-Fi wait label', (
    tester,
  ) async {
    final app = await _phone(tester);
    final downloads = app.services.downloads as DemoDownloadService;
    final l = app.strings;
    try {
      downloads.queueDownload(704, waitingForWifi: true);
      await tester.pumpAndSettle();
      expect(find.textContaining(l.stateWaitingForWifi), findsOneWidget);
      await app.holdRow(app.episode(704));
      expect(_labels(tester), contains(l.waitingForWifi));

      (app.services.sync as DemoSyncService).setOffline();
      downloads.queueDownload(704);
      await tester.pumpAndSettle();
      expect(find.textContaining(l.stateWaitingForDownload), findsOneWidget);
      expect(_labels(tester), contains(l.waitingForDownload));
    } finally {
      await app.finish();
    }
  });

  testWidgets('episode actions stay in place and ignore taps for 600 ms', (
    tester,
  ) async {
    final app = await _phone(tester);
    final l = app.strings;
    final library = app.services.library;
    Finder button(String label) => find.widgetWithText(EinkButton, label);

    try {
      await app.openEpisode(204);
      final dismiss = tester.getRect(button(l.dismiss));
      final markPlayed = tester.getRect(button(l.markPlayed));
      await app.tapText(l.dismiss);
      final confirm = tester.getCenter(
        find.descendant(of: _dialog, matching: find.text(l.dismiss)),
      );
      await tester.pump(doubleTapGuard);
      await tester.tapAt(confirm);
      await tester.pumpAndSettle(const Duration(milliseconds: 1));
      expect(tester.getRect(button(l.markNew)), dismiss);
      expect(tester.getRect(button(l.markPlayed)), markPlayed);

      await tester.pump(const Duration(milliseconds: 300));
      await tester.tapAt(confirm);
      await tester.pump();
      await tester.tap(button(l.markNew));
      await tester.pump();
      expect(library.stateOf(204).isDismissed, isTrue);

      await tester.pump(const Duration(milliseconds: 301));
      await app.tapText(l.markNew);
      expect(library.stateOf(204).isNew, isTrue);
      final download = tester.getRect(button(l.download));
      await tester.pump(const Duration(milliseconds: 601));
      await app.tapText(l.markPlayed);
      expect(tester.getRect(button(l.markNew)), markPlayed);
      expect(tester.getRect(button(l.download)), download);
      await app.tapText(l.markNew);
      expect(library.stateOf(204).isPlayed, isTrue);
    } finally {
      await app.finish();
    }
  });

  testWidgets('queue label flips while saving and rolls back on failure', (
    tester,
  ) async {
    final library = _FailingQueueLibrary();
    final app = await _phone(tester, library: library);
    final l = app.strings;
    try {
      await app.openEpisode(204);
      final queueButton = find.widgetWithText(EinkButton, l.addToQueue);
      final bounds = tester.getRect(queueButton);
      await app.tap(queueButton);
      expect(
        tester.getRect(find.widgetWithText(EinkButton, l.removeFromQueue)),
        bounds,
      );
      expect(library.queue.any((item) => item.id == 204), isFalse);
      await app.tapText(l.removeFromQueue);
      expect(library.attempts, 1);
      library.save.completeError(Exception('Queue write failed'));
      await tester.pumpAndSettle();
      expect(tester.getRect(queueButton), bounds);
      expect(find.text(l.actionFailed), findsOneWidget);
    } finally {
      if (!library.save.isCompleted) library.save.complete();
      await app.finish();
    }
  });

  testWidgets(
    'bulk dismissal reports when the server snapshot is unavailable',
    (tester) async {
      final library = _UnavailableBulkLibrary();
      final app = await _phone(tester, library: library);
      final l = app.strings;
      final count = library.dismissOlderCandidates(201).length;
      try {
        await app.section(LibrarySection.newEpisodes);
        await app.openEpisode(201);
        await app.tapText(l.dismissOlder);
        await app.dialog(l.dismissCount(count));
        expect(find.text(l.dismissOlderOffline), findsOneWidget);
        expect(library.stateOf(201).isNew, isTrue);

        await app.back();
        await app.holdRow(app.episode(201));
        await app.dialog(l.dismissOlder);
        await app.dialog(l.dismissCount(count));
        expect(
          find.widgetWithText(EinkDialogPanel, l.dismissOlderOffline),
          findsOneWidget,
        );
        expect(library.stateOf(201).isNew, isTrue);
      } finally {
        await app.finish();
      }
    },
  );
}

Future<UiHarness> _phone(WidgetTester tester, {DemoLibrary? library}) =>
    UiHarness.open(tester, library: library);

class _FailingQueueLibrary extends DemoLibrary {
  final save = Completer<void>();
  int attempts = 0;
  Episode? _adding;

  @override
  bool get queueSaving => _adding != null;

  @override
  List<Episode> get projectedQueue => [...queue, ?_adding];

  @override
  Future<void> enqueue(int episodeId, {bool next = false}) async {
    attempts++;
    _adding = episode(episodeId);
    notifyListeners();
    try {
      await save.future;
      await super.enqueue(episodeId, next: next);
    } finally {
      _adding = null;
      notifyListeners();
    }
  }
}

class _UnavailableBulkLibrary extends DemoLibrary {
  @override
  Future<void> dismissOlder(int episodeId) async =>
      throw StateError('Stale snapshot');
}

List<String> _labels(WidgetTester tester) => [
  for (final button in tester.widgetList<EinkButton>(
    find.descendant(of: _dialog, matching: find.byType(EinkButton)),
  ))
    button.label,
];

void _expectDownloadMarker(WidgetTester tester, String title, String label) {
  final row = find.widgetWithText(EinkRow, title);
  final marker = tester.widget<Icon>(
    find.descendant(of: row, matching: find.byIcon(Icons.download_outlined)),
  );
  expect(marker.color, Colors.black);
  final caption = find.descendant(of: row, matching: find.text(label));
  if (marker.semanticLabel == null) {
    expect(caption, findsOneWidget);
  } else {
    expect(marker.semanticLabel, label);
    expect(caption, findsNothing);
  }
}

void _reportProgress(DemoDownloadService downloads, int id, double progress) {
  downloads.setDownloadInfo(
    id,
    DownloadInfo(DownloadStatus.running, progress: progress),
  );
}
