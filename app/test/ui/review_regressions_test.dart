import 'package:easypodcast/core/api.dart';
import 'package:easypodcast/core/models.dart';
import 'package:easypodcast/core/services.dart';
import 'package:easypodcast/core/sync.dart';
import 'package:easypodcast/ui/app_root.dart';
import 'package:easypodcast/ui/demo/demo_api.dart';
import 'package:easypodcast/ui/demo/demo_library.dart';
import 'package:easypodcast/ui/eink_widgets.dart';
import 'package:easypodcast/ui/episode_page.dart';
import 'package:easypodcast/ui/episode_text.dart';
import 'package:easypodcast/ui/library_views.dart';
import 'package:easypodcast/ui/settings_pages.dart';
import 'package:easypodcast/ui/theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_test_support.dart';

const _settings = PageStorageKey('settings-list');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String font;
  setUpAll(() async => font = await loadTestFonts());

  testWidgets(
    'sync problems survive retries and Settings can send pending changes',
    (tester) async {
      final app = await _phone(tester);
      final l = app.strings;
      final status = app.services.sync.status as ValueNotifier<SyncStatus>;
      final lastSync = DateTime.now();
      try {
        void setPhase(SyncPhase phase, {bool syncing = false}) {
          status.value = SyncStatus(
            phase: phase,
            syncing: syncing,
            lastSuccess: lastSync,
            pending: 2,
          );
        }

        final row = find.widgetWithText(EinkRow, app.episode(101));
        setPhase(SyncPhase.offline);
        await tester.pumpAndSettle();
        final position = tester.getTopLeft(row);
        expect(find.text(l.offline), findsOneWidget);
        setPhase(status.value.phase, syncing: true);
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(row), position);
        expect(find.text(l.offline), findsOneWidget);

        await app.section(LibrarySection.settings);
        final pending = find.text(
          l.pendingChanges(2) + metadataSeparator + l.sendNow,
        );
        expect(pending, findsOneWidget);
        expect(find.text(l.offline), findsOneWidget);
        setPhase(SyncPhase.error);
        await tester.pumpAndSettle();
        final problem = find.widgetWithText(EinkError, l.syncError);
        final bounds = tester.getRect(problem);
        setPhase(status.value.phase, syncing: true);
        await tester.pumpAndSettle();
        expect(tester.getRect(problem), bounds);

        await app.tap(pending);
        expect(status.value.pending, 0);
        expect(pending, findsNothing);
        expect(
          find.text(l.serverLastSync(clockText(l, status.value.lastSuccess!))),
          findsOneWidget,
        );
        expect(problem, findsNothing);

        await app.scrollToRow(l.keepQueueDownloaded, find.byKey(_settings));
        expect(app.services.settings.keepQueueDownloaded, isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        await app.finish();
      }
    },
  );

  testWidgets('the first sync reports loading on each empty list', (
    tester,
  ) async {
    final app = await _phone(tester, library: _EmptyLibrary());
    final status = app.services.sync.status as ValueNotifier<SyncStatus>;
    final l = app.strings;
    try {
      status.value = const SyncStatus(phase: SyncPhase.idle, syncing: true);
      await tester.pumpAndSettle();
      expect(find.text(l.syncLoading), findsOneWidget);
      expect(find.text(l.inProgressEmpty), findsNothing);
      for (final section in [
        LibrarySection.queue,
        LibrarySection.newEpisodes,
        LibrarySection.downloads,
        LibrarySection.podcasts,
      ]) {
        await app.section(section);
        expect(find.text(l.syncLoading), findsOneWidget, reason: section.name);
      }
      status.value = SyncStatus(
        phase: SyncPhase.idle,
        lastSuccess: DateTime.now(),
      );
      await tester.pumpAndSettle();
      expect(find.text(l.podcastsEmpty), findsOneWidget);
    } finally {
      await app.finish();
    }
  });

  testWidgets(
    'podcast shows a stale feed error and a refresh that is still pending',
    (tester) async {
      final app = await _phone(tester, library: _StaleFeedLibrary());
      final l = app.strings;
      final podcast = app.services.library.podcast(7)!;
      final date = l.loadedOn(dateText(l, podcast.lastSuccessAt!));
      try {
        await app.section(LibrarySection.podcasts);
        final podcasts = find.byType(PodcastList);
        final state = tester.state<ScrollableState>(
          find.descendant(of: podcasts, matching: find.byType(Scrollable)),
        );
        await app.section(LibrarySection.settings);
        await app.back();
        expect(
          tester.state<ScrollableState>(
            find.descendant(of: podcasts, matching: find.byType(Scrollable)),
          ),
          same(state),
        );
        await app.scrollToRow(podcast.title, podcasts);

        expect(find.text(date), findsOneWidget);
        expect(find.textContaining(podcast.lastError!), findsOneWidget);
        await app.row(l.refresh);
        expect(find.text(l.refreshing), findsOneWidget);
        for (final seconds in [2, 4, 8]) {
          await tester.pump(Duration(seconds: seconds));
          await tester.pump();
        }
        expect(find.text(l.refreshRequested), findsOneWidget);
        expect(find.text(date), findsOneWidget);
        (app.services.library as _StaleFeedLibrary).finishRefresh();
        await tester.pumpAndSettle();
        expect(find.text(l.refreshRequested), findsNothing);
        expect(find.textContaining(podcast.lastError!), findsNothing);
      } finally {
        await app.finish();
      }
    },
  );

  testWidgets(
    'Back restores the live podcast scroll position and long headings wrap',
    (tester) async {
      final library = _LongPodcastLibrary();
      final app = await _phone(tester, library: library);
      try {
        await app.section(LibrarySection.podcasts);
        await app.scrollToRow(
          _LongPodcastLibrary.title,
          find.byType(PodcastList),
        );
        final header = find.widgetWithText(
          EinkHeader,
          _LongPodcastLibrary.title,
        );
        expect(tester.getSize(header).height, greaterThan(52));
        final label = find.descendant(
          of: header,
          matching: find.text(_LongPodcastLibrary.title),
        );
        expect(
          tester.widget<Text>(label).style!.fontSize,
          greaterThanOrEqualTo(rowTitleStyle.fontSize!),
        );
        expect(
          find.descendant(of: header, matching: find.byType(FittedBox)),
          findsNothing,
        );

        final view = find.byType(EpisodeList);
        final scroll = find.descendant(
          of: view,
          matching: find.byType(Scrollable),
        );
        final state = tester.state<ScrollableState>(scroll);
        final rows = find.descendant(of: view, matching: find.byType(EinkRow));
        expect(rows.evaluate().length, lessThan(25));
        for (var i = 0; i < 10; i++) {
          await tester.drag(view, const Offset(0, -420));
          await tester.pumpAndSettle();
        }
        final offset = state.position.pixels;
        expect(offset, greaterThan(3000));
        final visible = rows.hitTestable().last;
        await tester.tap(visible);
        await tester.pumpAndSettle();
        expect(find.byType(EpisodePage), findsOneWidget);
        await app.back();
        expect(tester.state<ScrollableState>(scroll), same(state));
        expect(state.position.pixels, offset);
        expect(rows.evaluate().length, lessThan(25));
        expect(tester.takeException(), isNull);
      } finally {
        await app.finish();
      }
    },
  );

  testWidgets(
    'New lists the past 30 days and links the reader back to the catalogue',
    (tester) async {
      final app = await _phone(tester);
      final l = app.strings;
      final old = app.episode(118);
      final recent = app.episode(201);
      try {
        await app.section(LibrarySection.newEpisodes);
        expect(find.text(recent), findsOneWidget);
        final view = find.byType(EpisodeList);
        await tester.scrollUntilVisible(
          find.text(l.olderEpisodesInPodcasts),
          450,
          scrollable: find.descendant(
            of: view,
            matching: find.byType(Scrollable),
          ),
        );
        expect(
          find.text(l.olderEpisodesInPodcasts).hitTestable(),
          findsOneWidget,
        );
        expect(find.text(old), findsNothing);
        final episodes = tester.widget<EpisodeList>(view).episodes;
        final cutoff = DateTime.now().subtract(const Duration(days: 30));
        expect(episodes, isNotEmpty);
        expect(
          episodes.every((episode) => !episode.publishedAt!.isBefore(cutoff)),
          isTrue,
        );

        await app.section(LibrarySection.podcasts);
        await app.scrollToRow(
          app.services.library.podcast(1)!.title,
          find.byType(PodcastList),
        );
        await app.scrollToRow(old, find.byType(EpisodeList));
        expect(find.byType(EpisodePage), findsOneWidget);
      } finally {
        await app.finish();
      }
    },
  );

  testWidgets(
    'unsubscribe requires confirmation and the same button restores the subscription',
    (tester) async {
      final app = await _phone(tester);
      final l = app.strings;
      final library = app.services.library;
      try {
        await app.section(LibrarySection.podcasts);
        await app.scrollToRow(
          library.podcast(1)!.title,
          find.byType(PodcastList),
        );
        await app.row(l.aboutPodcast);
        await app.tapText(l.unsubscribe);
        expect(library.podcast(1)!.subscribed, isTrue);
        await app.dialog(l.cancel);
        expect(library.podcast(1)!.subscribed, isTrue);

        await tester.pump(const Duration(milliseconds: 601));
        await app.tapText(l.unsubscribe);
        await app.dialog(l.unsubscribe);
        expect(library.podcast(1)!.subscribed, isFalse);
        expect(find.text(l.resubscribe), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 601));
        await app.tapText(l.resubscribe);
        expect(library.podcast(1)!.subscribed, isTrue);
        expect(find.text(l.unsubscribe), findsOneWidget);
      } finally {
        await app.finish();
      }
    },
  );

  testWidgets('OPML import shows failure reasons with credentials removed', (
    tester,
  ) async {
    final app = await _phone(
      tester,
      configure: (demo) => AppServices(
        settings: demo.settings,
        api: _FailedOpmlApi(demo.library as DemoLibrary),
        library: demo.library,
        sync: demo.sync,
        player: demo.player,
        downloads: demo.downloads,
      ),
    );
    final l = app.strings;
    try {
      await app.section(LibrarySection.settings);
      await app.scrollToRow(l.opml, find.byKey(_settings));
      await tester.enterText(find.byType(TextField), '<opml><body/></opml>');
      await app.tapText(l.opmlImport);
      final reason = find.text('HTTP 401 for https://feed.example/rss');
      await app.scrollTo(reason, find.byType(OpmlPage));
      expect(reason, findsOneWidget);
      expect(find.text('https://feed.example/rss'), findsOneWidget);
      expect(find.textContaining('test-user'), findsNothing);
      expect(find.textContaining('test-pass'), findsNothing);
    } finally {
      await app.finish();
    }
  });

  testWidgets(
    'a new login keeps the last address even after the page is rebuilt',
    (tester) async {
      final app = await UiHarness.open(
        tester,
        size: const Size(360, 720),
        locale: const Locale('cs'),
        loggedIn: false,
      );
      final server = find.descendant(
        of: find.byKey(const ValueKey('login-address')),
        matching: find.byType(TextField),
      );
      const address = 'https://my-podcast.example';
      try {
        expect(tester.widget<TextField>(server).controller!.text, isEmpty);
        await tester.enterText(server, address);
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(EasyPodcastApp(services: app.services));
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(server).controller!.text, address);
      } finally {
        await app.finish();
      }
    },
  );

  testWidgets(
    'Linux Settings expose both redraw intervals and Escape dismisses a named dialog',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final app = await UiHarness.open(
        tester,
        size: const Size(760, 700),
        locale: const Locale('cs'),
        desktopFont: font,
      );
      final l = app.strings;
      try {
        await app.section(LibrarySection.settings);
        Future<void> setSeconds(String title, int from, int to) async {
          final row = find.widgetWithText(EinkRow, title);
          await tester.scrollUntilVisible(
            row,
            120,
            scrollable: find.descendant(
              of: find.byKey(_settings),
              matching: find.byType(Scrollable),
            ),
          );
          final control = find.descendant(
            of: row,
            matching: find.byType(SegmentedButton<int>),
          );
          expect(tester.widget<SegmentedButton<int>>(control).selected, {from});
          await app.tap(
            find.descendant(of: control, matching: find.text(l.seconds(to))),
          );
          expect(tester.widget<SegmentedButton<int>>(control).selected, {to});
        }

        await setSeconds(l.playerRedraw, 1, 10);
        await setSeconds(l.listRedraw, 10, 1);
        expect(app.services.settings.positionRedrawSeconds, 1);
        await app.tapText(l.desktopSpeed(speedText(l, 1)));
        final route = find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.scopesRoute == true &&
              widget.properties.namesRoute == true &&
              widget.properties.label == l.speed,
        );
        expect(route, findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(EinkDialogPanel), findsNothing);
        expect(find.byKey(_settings), findsOneWidget);
      } finally {
        semantics.dispose();
        await app.finish();
      }
    },
  );

  testWidgets(
    'long durations use hours and a stale short duration falls back to elapsed time',
    (tester) async {
      final app = await _phone(tester);
      final l = app.strings;
      try {
        expect(
          playbackTime(
            l,
            const Duration(minutes: 31),
            const Duration(minutes: 95),
            showTotal: true,
          ),
          'zbývá 1\u00a0h 4\u00a0min z 1\u00a0h 35\u00a0min',
        );
        expect(
          playbackTime(
            l,
            const Duration(minutes: 47),
            const Duration(minutes: 40),
          ),
          'přehráno 47\u00a0min',
        );
        final weekday = dayGroup(
          l,
          DateTime.now().subtract(const Duration(days: 3)),
        );
        expect(weekday[0], weekday[0].toUpperCase());
        expect(l.storageUsed('119 MB'), 'Staženo 119 MB');
        expect(l.loggingOut, 'Odhlašuji…');
        final tooltip = einkTheme().tooltipTheme;
        expect((tooltip.decoration! as BoxDecoration).color, Colors.black);
        expect(tooltip.textStyle!.color, Colors.white);
      } finally {
        await app.finish();
      }
    },
  );
}

Future<UiHarness> _phone(
  WidgetTester tester, {
  DemoLibrary? library,
  AppServices Function(AppServices)? configure,
}) => UiHarness.open(
  tester,
  size: const Size(360, 720),
  locale: const Locale('cs'),
  library: library,
  configure: configure,
);

class _EmptyLibrary extends DemoLibrary {
  @override
  Episode? episode(int id) => null;

  @override
  List<Podcast> get podcasts => const [];

  @override
  List<Episode> get inProgress => const [];

  @override
  List<Episode> get queue => const [];

  @override
  List<Episode> newEpisodes({required DateTime since}) => const [];
}

class _StaleFeedLibrary extends DemoLibrary {
  @override
  void refreshFeeds() {}

  void finishRefresh() => super.refreshFeeds();
}

class _LongPodcastLibrary extends DemoLibrary {
  static const title =
      'Rozhovory s lidmi, kteří v historických archivech nacházejí zapomenuté příběhy plné překvapení';

  late final _older = [
    for (var i = 0; i < 300; i++)
      Episode(
        id: 10000 + i,
        podcastId: 1,
        title: 'Starší díl číslo $i',
        enclosureUrl: 'https://podcast.example/past/$i',
        publishedAt: nowUtc().subtract(Duration(days: 365 + i)),
      ),
  ];

  @override
  List<Podcast> get podcasts => [
    for (final podcast in super.podcasts)
      podcast.id == 1 ? _withTitle(podcast) : podcast,
  ];

  @override
  Podcast? podcast(int id) {
    final show = super.podcast(id);
    return id == 1 && show != null ? _withTitle(show) : show;
  }

  Podcast _withTitle(Podcast show) => show.copyWith(title: title);

  @override
  Episode? episode(int id) =>
      id >= 10000 ? _older[id - 10000] : super.episode(id);

  @override
  List<Episode> episodesOf(int podcastId) => podcastId == 1
      ? [...super.episodesOf(1), ..._older]
      : super.episodesOf(podcastId);
}

class _FailedOpmlApi extends DemoApiClient {
  _FailedOpmlApi(super.library);

  @override
  Future<OpmlImportResult> importOpml(String opml, {Duration? timeout}) async =>
      const OpmlImportResult(
        added: 0,
        existing: 0,
        failed: [
          (
            feedUrl: 'https://test-user:test-pass@feed.example/rss',
            error: 'HTTP 401 for https://test-user:test-pass@feed.example/rss',
          ),
        ],
      );
}
