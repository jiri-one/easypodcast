import 'package:easypodcast/core/api.dart';
import 'package:easypodcast/core/models.dart';
import 'package:easypodcast/core/services.dart';
import 'package:easypodcast/core/sync.dart';
import 'package:easypodcast/ui/app_root.dart';
import 'package:easypodcast/ui/eink_widgets.dart';
import 'package:easypodcast/ui/episode_page.dart';
import 'package:easypodcast/ui/episode_text.dart';
import 'package:easypodcast/ui/library_views.dart';
import 'package:easypodcast/ui/settings_pages.dart';
import 'package:easypodcast/ui/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'fixtures/demo_api.dart';
import 'fixtures/demo_library.dart';
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
      final library = _StaleFeedLibrary();
      final app = await _phone(tester, library: library);
      final l = app.strings;
      final podcast = library.podcast(7)!;
      final date = l.loadedOn(dateText(l, podcast.lastSuccessAt!));
      Finder subtitle(String text) => find.descendant(
        of: find.byType(EinkHeader),
        matching: find.text(text),
      );
      try {
        await app.section(LibrarySection.podcasts);
        final podcasts = find.byType(PodcastList);
        await app.section(LibrarySection.settings);
        expect(podcasts, findsNothing);
        await app.back();
        expect(podcasts, findsOneWidget);
        await app.scrollToRow(podcast.title, podcasts);

        expect(subtitle(date), findsOneWidget);
        expect(find.textContaining(podcast.lastError!), findsOneWidget);
        await app.tap(find.byTooltip(l.refresh));
        expect(library.refreshes, 1);
        expect(subtitle(l.refreshing), findsOneWidget);
        expect(subtitle(date), findsNothing);
        for (final seconds in [2, 4, 8]) {
          await tester.pump(Duration(seconds: seconds));
          await tester.pump();
        }
        expect(subtitle(l.refreshRequested), findsNothing);
        expect(subtitle(date), findsOneWidget);
        library.finishRefresh();
        await tester.pumpAndSettle();
        final updated = library.podcast(podcast.id)!.lastSuccessAt!;
        expect(subtitle(l.loadedAt(clockText(l, updated))), findsOneWidget);
        expect(find.textContaining(podcast.lastError!), findsNothing);
      } finally {
        await app.finish();
      }
    },
  );

  for (final section in [LibrarySection.newEpisodes, LibrarySection.podcasts]) {
    testWidgets('${section.name} refreshes once when a long pull is released', (
      tester,
    ) async {
      final library = _StaleFeedLibrary();
      final app = await _phone(tester, library: library);
      final l = app.strings;
      try {
        await app.section(section);
        if (section == LibrarySection.podcasts) {
          await app.scrollToRow(
            library.podcast(1)!.title,
            find.byType(PodcastList),
          );
        }
        expect(find.byTooltip(l.refresh), findsOneWidget);
        final list = find.byType(EpisodeList);
        final scrollable = find.descendant(
          of: list,
          matching: find.byType(Scrollable),
        );
        final position = tester.state<ScrollableState>(scrollable).position;
        final height = tester.getSize(list).height;
        await tester.drag(list, Offset(0, height / 8));
        await tester.pumpAndSettle();
        expect(library.refreshes, 0);

        // A finger rarely moves straight: the small step back must not cancel.
        final gesture = await tester.startGesture(tester.getCenter(list));
        for (final distance in [25.0, height / 6, -2.0, height / 6]) {
          await gesture.moveBy(Offset(0, distance));
        }
        await tester.pump();
        expect(position.pixels, position.minScrollExtent);
        expect(library.refreshes, 0);
        await gesture.up();
        await tester.pumpAndSettle();
        expect(library.refreshes, 1);
        expect(find.widgetWithText(EinkHeader, l.refreshing), findsOneWidget);

        library.finishRefresh();
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        final updated = library.podcast(1)!.lastSuccessAt!;
        expect(
          find.widgetWithText(EinkHeader, l.loadedAt(clockText(l, updated))),
          findsOneWidget,
        );
        expect(library.refreshes, 1);
      } finally {
        await app.finish();
      }
    });
  }

  testWidgets('Linux list header can refresh and shows a failed request', (
    tester,
  ) async {
    final library = _StaleFeedLibrary()..failRefresh = true;
    final app = await UiHarness.open(
      tester,
      size: const Size(1000, 700),
      desktopFont: font,
      library: library,
    );
    final l = app.strings;
    try {
      await app.section(LibrarySection.newEpisodes);
      final refresh = find.descendant(
        of: find.byType(EinkHeader),
        matching: find.byTooltip(l.refresh),
      );
      final target = tester.getSize(refresh);
      expect(target.width, greaterThanOrEqualTo(48));
      expect(target.height, greaterThanOrEqualTo(48));
      await tester.tap(refresh, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(library.refreshes, 1);
      expect(find.widgetWithText(EinkError, l.refreshFailed), findsOneWidget);

      await app.section(LibrarySection.podcasts);
      await app.scrollToRow(
        library.podcast(1)!.title,
        find.byType(PodcastList),
      );
      expect(find.widgetWithText(EinkError, l.refreshFailed), findsNothing);
      await tester.tap(refresh, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(library.refreshes, 2);
      expect(find.widgetWithText(EinkError, l.refreshFailed), findsOneWidget);
    } finally {
      await app.finish();
    }
  });

  for (final (size, textScale) in const [
    (Size(392, 785), 1.8),
    (palmaSize, palmaTextScale),
  ]) {
    testWidgets('header buttons grow with the text at ${size.width} dp', (
      tester,
    ) async {
      final app = await UiHarness.open(
        tester,
        size: size,
        textScale: textScale,
      );
      final l = app.strings;
      try {
        await app.section(LibrarySection.podcasts);
        await app.scrollToRow(
          app.services.library.podcast(1)!.title,
          find.byType(PodcastList),
        );
        for (final label in [l.refresh, l.aboutPodcast]) {
          final button = find.byTooltip(label);
          final icon = find.descendant(of: button, matching: find.byType(Icon));
          expect(tester.getSize(icon).height, closeTo(24 * textScale, 0.01));
          expect(tester.getSize(button).shortestSide, greaterThanOrEqualTo(48));
        }
      } finally {
        await app.finish();
      }
    });
  }

  testWidgets('an empty list of new episodes can still be pulled', (
    tester,
  ) async {
    final library = _NoNewEpisodesLibrary();
    final app = await _phone(tester, library: library);
    try {
      await app.section(LibrarySection.newEpisodes);
      final list = find.byType(EpisodeList);
      expect(find.text(app.strings.newEmpty), findsOneWidget);
      await tester.drag(list, Offset(0, tester.getSize(list).height / 2));
      await tester.pumpAndSettle();
      expect(library.refreshes, 1);
    } finally {
      await app.finish();
    }
  });

  testWidgets(
    'open episode notes reload after a podcast update and a same-version reset',
    (tester) async {
      final library = _UpdatedNotesLibrary();
      final app = await _phone(tester, library: library);
      Finder notes(String text) => find.text(text, findRichText: true);
      try {
        await app.openEpisode(101);
        final page = tester.state(find.byType(EpisodePage));
        expect(notes('Original notes'), findsOneWidget);

        library.update('2', 'Revised notes');
        await tester.pumpAndSettle();
        expect(notes('Revised notes'), findsOneWidget);
        expect(notes('Original notes'), findsNothing);

        library.update(null, '');
        library.update('2', 'Restored notes');
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(EpisodePage)), same(page));
        expect(notes('Restored notes'), findsOneWidget);
        expect(notes('Revised notes'), findsNothing);
      } finally {
        await app.finish();
      }
    },
  );

  testWidgets(
    'Back restores the podcast scroll position and long headings wrap',
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
        final restored = tester.state<ScrollableState>(scroll);
        expect(restored, isNot(same(state)));
        expect(restored.position.pixels, offset);
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
      final library = _StaleFeedLibrary();
      final app = await _phone(tester, library: library);
      final l = app.strings;
      try {
        await app.section(LibrarySection.podcasts);
        await app.scrollToRow(
          library.podcast(1)!.title,
          find.byType(PodcastList),
        );
        await app.tap(find.byTooltip(l.aboutPodcast));
        expect(find.byType(AboutPodcastPage), findsOneWidget);
        await app.tapText(l.unsubscribe);
        expect(library.podcast(1)!.subscribed, isTrue);
        await app.dialog(l.cancel);
        expect(library.podcast(1)!.subscribed, isTrue);

        await tester.pump(const Duration(milliseconds: 601));
        await app.tapText(l.unsubscribe);
        await app.dialog(l.unsubscribe);
        expect(library.podcast(1)!.subscribed, isFalse);
        expect(find.text(l.resubscribe), findsOneWidget);
        await app.back();
        expect(find.byTooltip(l.refresh), findsNothing);
        await tester.drag(find.byType(EpisodeList), const Offset(0, 400));
        await tester.pumpAndSettle();
        expect(library.refreshes, 0);
        await app.tap(find.byTooltip(l.aboutPodcast));
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
      final app = await UiHarness.open(tester, loggedIn: false);
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

  testWidgets('Escape dismisses a named dialog on Linux', (tester) async {
    final semantics = tester.ensureSemantics();
    final app = await UiHarness.open(
      tester,
      size: const Size(760, 700),
      desktopFont: font,
    );
    final l = app.strings;
    try {
      app.services.settings.showSpeedAndSleep = true;
      await app.section(LibrarySection.settings);
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
  });

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
}) => UiHarness.open(tester, library: library, configure: configure);

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
  int refreshes = 0;
  bool failRefresh = false;

  @override
  void refreshFeeds() {
    refreshes++;
    if (failRefresh) throw ApiException(500, 'Demo refresh error');
  }

  void finishRefresh() => super.refreshFeeds();
}

class _NoNewEpisodesLibrary extends _StaleFeedLibrary {
  @override
  List<Episode> newEpisodes({required DateTime since}) => const [];
}

class _UpdatedNotesLibrary extends DemoLibrary {
  String? _version = '1';
  String _notes = 'Original notes';

  void update(String? version, String notes) {
    _version = version;
    _notes = notes;
    notifyListeners();
  }

  @override
  Episode? episode(int id) => _version == null ? null : super.episode(id);

  @override
  Podcast? podcast(int id) => _version == null
      ? null
      : super.podcast(id)?.copyWith(episodesVersion: _version);

  @override
  Future<String> description(int id) async => _notes;
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
