import 'dart:async';

import 'package:easypodcast/core/api.dart';
import 'package:easypodcast/core/models.dart';
import 'package:easypodcast/core/services.dart';
import 'package:easypodcast/ui/eink_widgets.dart';
import 'package:easypodcast/ui/episode_page.dart';
import 'package:easypodcast/ui/library_views.dart';
import 'package:easypodcast/ui/podcast_search.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'fixtures/demo_api.dart';
import 'fixtures/demo_library.dart';
import 'fixtures/demo_sync.dart';
import 'ui_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String font;
  setUpAll(() async => font = await loadTestFonts());

  test('title matching folds case and accents and requires every word', () {
    final episodes = [
      for (final (index, title) in [
        'Tomáš na cestě',
        'Tomáš Roud v Brně',
        'Roud vypráví',
        'Rozhovor: Roud a Toma\u0301s\u030c',
      ].indexed)
        Episode(id: index, podcastId: 1, title: title, enclosureUrl: ''),
    ];

    final words = podcastSearchWords('  ROUD\tTOMAS  ');
    final matches = matchPodcastEpisodes(episodes, words, const {});
    expect(matches.map((episode) => episode.id), [1, 3]);
    expect(podcastSearchWords('Španělské PIÑATA'), ['spanelske', 'pinata']);
  });

  test(
    'global matching keeps at most 100 episodes, with undated ones last',
    () {
      final publishedAt = DateTime.utc(2026, 11, 26);
      final episodes = [
        const Episode(id: 200, podcastId: 1, title: 'Title', enclosureUrl: ''),
        for (var id = 1; id <= 101; id++)
          Episode(
            id: id,
            podcastId: 2,
            title: 'Title',
            enclosureUrl: '',
            publishedAt: publishedAt,
          ),
      ];
      expect(
        matchLibraryEpisodes(
          episodes,
          podcastSearchWords('title'),
          const {},
        ).map((episode) => episode.id),
        [for (var id = 101; id >= 2; id--) id],
      );
    },
  );

  testWidgets('title search works offline and clear or Back close it', (
    tester,
  ) async {
    final (app, api) = await _openPodcast(tester);
    final l = app.strings;
    final all = _episodeIds(tester);
    final field = find.byType(TextField);
    try {
      (app.services.sync as DemoSyncService).setOffline();
      await tester.pump();
      await app.row(l.searchThisPodcast);
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasFocus,
        isTrue,
      );
      await tester.enterText(field, '  NADRAZI nocni ');
      await tester.pump();
      expect(_episodeIds(tester), [102, 108, 114, 120]);
      await tester.pump(const Duration(milliseconds: 401));
      api.requests.single.$3.completeError(OfflineException());
      await tester.pump();
      expect(_episodeIds(tester), [102, 108, 114, 120]);

      await app.tap(find.byTooltip(l.clearSearch));
      expect(field, findsNothing);
      expect(_episodeIds(tester), all);
      await app.row(l.searchThisPodcast);
      await tester.enterText(field, 'no such episode');
      await tester.pump();
      expect(_episodeIds(tester), isEmpty);
      expect(find.text(l.syncLoading), findsOneWidget);
      expect(find.text(l.noMatchingEpisodes), findsNothing);
      await tester.pump(const Duration(milliseconds: 400));
      api.requests.last.$3.complete(const []);
      await tester.pump();
      final empty = find.text(l.noMatchingEpisodes);
      if (empty.hitTestable().evaluate().isEmpty) {
        await app.scrollTo(empty, find.byType(EpisodeList));
      }
      expect(empty.hitTestable(), findsOneWidget);

      await app.back();
      expect(field, findsNothing);
      expect(find.widgetWithText(EinkRow, l.searchThisPodcast), findsOneWidget);
      expect(_episodeIds(tester), all);
    } finally {
      await app.finish();
    }
  });

  testWidgets('debounces server search and appends matches in list order', (
    tester,
  ) async {
    final (app, api) = await _openPodcast(tester);
    final field = find.byType(TextField);
    try {
      await app.row(app.strings.searchThisPodcast);
      await tester.enterText(field, 'vlak');
      await tester.pump(const Duration(milliseconds: 300));
      expect(_episodeIds(tester), [101, 107, 113, 119]);
      expect(api.requests, isEmpty);

      await tester.enterText(field, 'noční nádraží');
      await tester.pump(const Duration(milliseconds: 399));
      expect(_episodeIds(tester), [102, 108, 114, 120]);
      expect(api.requests, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(api.requests.single.$1, 1);
      expect(api.requests.single.$2, 'noční nádraží');
      api.requests.single.$3.complete([115, 108, 103, 115, 999]);
      await tester.pumpAndSettle();
      expect(_episodeIds(tester), [102, 108, 114, 120, 103, 115]);
    } finally {
      await app.finish();
    }
  });

  testWidgets('stale results and failed searches leave the local matches', (
    tester,
  ) async {
    final (app, api) = await _openPodcast(tester);
    final field = find.byType(TextField);
    try {
      await app.row(app.strings.searchThisPodcast);
      await tester.enterText(field, 'noční nádraží');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(field, 'vlak');
      api.requests.single.$3.complete([103]);
      await tester.pump();
      expect(_episodeIds(tester), [101, 107, 113, 119]);

      await tester.pump(const Duration(milliseconds: 400));
      api.requests.last.$3.completeError(OfflineException());
      await tester.pump();
      expect(_episodeIds(tester), [101, 107, 113, 119]);
    } finally {
      await app.finish();
    }
  });

  testWidgets('Escape in the search field closes only the search on Linux', (
    tester,
  ) async {
    final (app, _) = await _openPodcast(tester, desktopFont: font);
    final field = find.byType(TextField);
    try {
      await app.row(app.strings.searchThisPodcast);
      await tester.enterText(field, 'vlak');
      await tester.pump();
      final episode = app.services.library
          .episodesOf(1)
          .firstWhere((episode) => episode.id == 101);
      await app.tap(find.byKey(EpisodeRowKey(episode)));
      expect(find.byType(EpisodePage), findsOneWidget);
      await app.tap(field);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(field, findsNothing);
      expect(
        tester.widget<EpisodePage>(find.byType(EpisodePage)).episode.id,
        101,
      );
    } finally {
      await app.finish();
    }
  });

  testWidgets(
    'global search matches subscribed podcast and episode titles offline',
    (tester) async {
      final (app, api) = await _openHarness(tester);
      final field = find.byType(TextField);
      try {
        await app.services.library.unsubscribe(4);
        (app.services.sync as DemoSyncService).setOffline();
        await app.section(LibrarySection.search);
        expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
        await tester.enterText(field, '  POSLEDNI  ');
        await tester.pump();
        expect(
          _titledRow(app.services.library.podcast(1)!.title),
          findsOneWidget,
        );
        expect(_episodeIds(tester).take(3), [101, 203, 107]);
        expect(
          _episodeIds(tester)
              .every((id) => app.services.library.episode(id)!.podcastId != 4),
          isTrue,
        );
        expect(find.text(app.strings.syncLoading), findsOneWidget);
        expect(api.globalRequests, isEmpty);
        await tester.pump(const Duration(milliseconds: 400));
        api.globalRequests.single.$2.completeError(OfflineException());
        await tester.pumpAndSettle();
        expect(find.text(app.strings.syncLoading), findsNothing);
        expect(_episodeIds(tester).take(3), [101, 203, 107]);
      } finally {
        await app.finish();
      }
    },
  );

  testWidgets(
    'global description matches join titles and both result types return to search',
    (tester) async {
      final (app, api) = await _openHarness(tester);
      final field = find.byType(TextField);
      const query = 'posledni';
      try {
        await app.section(LibrarySection.search);
        await tester.enterText(field, 'no such episode');
        await tester.pump(const Duration(milliseconds: 400));
        expect(_episodeIds(tester), isEmpty);
        expect(find.text(app.strings.syncLoading), findsOneWidget);
        api.globalRequests.single.$2.complete(const []);
        await tester.pump();
        expect(find.text(app.strings.noMatchingEpisodes), findsOneWidget);

        await tester.enterText(field, query);
        await tester.pump(const Duration(milliseconds: 399));
        expect(api.globalRequests, hasLength(1));
        expect(_episodeIds(tester).take(3), [101, 203, 406]);
        await tester.pump(const Duration(milliseconds: 1));
        expect(api.globalRequests.last.$1, query);
        api.globalRequests.last.$2.complete([104, 101, 201, 104, 9999]);
        await tester.pumpAndSettle();
        final matched = _episodeIds(tester);
        expect(matched.take(5), [201, 101, 203, 104, 406]);

        final title = app.services.library.podcast(1)!.title;
        await app.tap(_titledRow(title));
        expect(
          tester.widget<EpisodeList>(find.byType(EpisodeList)).kind,
          EpisodeListKind.podcast,
        );
        await app.back();
        expect(tester.widget<TextField>(field).controller!.text, query);
        expect(_episodeIds(tester), matched);
        await app.tap(
          _titledRow(app.episode(201)),
          within: find.byType(EpisodeList),
        );
        expect(
          tester.widget<EpisodePage>(find.byType(EpisodePage)).episode.id,
          201,
        );
        await app.back();
        expect(tester.widget<TextField>(field).controller!.text, query);
        expect(_episodeIds(tester), matched);
        expect(api.globalRequests, hasLength(2));
      } finally {
        await app.finish();
      }
    },
  );

  testWidgets(
    'editing a scrolled global search shows the newest results first',
    (tester) async {
      final (app, _) = await _openHarness(tester);
      final field = find.byType(TextField);
      final results = find.descendant(
        of: find.byType(EpisodeList),
        matching: find.byType(Scrollable),
      );
      double offset() => tester.state<ScrollableState>(results).position.pixels;
      try {
        await app.section(LibrarySection.search);
        await tester.enterText(field, 'a');
        await tester.pump();
        await tester.drag(results, const Offset(0, -550));
        await tester.pumpAndSettle();
        expect(offset(), greaterThan(0));

        await tester.enterText(field, 'e');
        await tester.pump();
        expect(offset(), 0);
      } finally {
        await app.finish();
      }
    },
  );

  testWidgets(
    'Escape closes global search and restores the previous list on Linux',
    (tester) async {
      final (app, api) = await _openHarness(tester, desktopFont: font);
      final field = find.byType(TextField);
      try {
        await app.section(LibrarySection.podcasts);
        await app.section(LibrarySection.search);
        expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
        await tester.enterText(field, 'posledni');
        await tester.pump(const Duration(milliseconds: 400));
        api.globalRequests.single.$2.complete(const []);
        await tester.pumpAndSettle();
        await app.tap(
          _titledRow(app.episode(101)),
          within: find.byType(EpisodeList),
        );
        expect(find.byType(EpisodePage), findsOneWidget);
        await app.back();
        expect(find.byType(EpisodePage), findsNothing);
        expect(tester.widget<TextField>(field).controller!.text, 'posledni');
        await app.tap(field);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(field, findsNothing);
        expect(find.byType(PodcastList), findsOneWidget);
      } finally {
        await app.finish();
      }
    },
  );
}

Future<(UiHarness, _SearchApi)> _openPodcast(
  WidgetTester tester, {
  String? desktopFont,
}) async {
  final (app, api) = await _openHarness(tester, desktopFont: desktopFont);
  await app.section(LibrarySection.podcasts);
  await app.scrollToRow(
    app.services.library.podcast(1)!.title,
    find.byType(PodcastList),
  );
  return (app, api);
}

Future<(UiHarness, _SearchApi)> _openHarness(
  WidgetTester tester, {
  String? desktopFont,
}) async {
  late _SearchApi api;
  final app = await UiHarness.open(
    tester,
    size: desktopFont == null ? const Size(360, 720) : const Size(1000, 700),
    desktopFont: desktopFont,
    configure: (demo) => AppServices(
      settings: demo.settings,
      library: demo.library,
      sync: demo.sync,
      player: demo.player,
      downloads: demo.downloads,
      api: api = _SearchApi(demo.library as DemoLibrary),
    ),
  );
  return (app, api);
}

Finder _titledRow(String title) => find.byWidgetPredicate(
  (widget) => widget is EinkRow && widget.title == title,
);

List<int> _episodeIds(WidgetTester tester) => [
  for (final episode
      in tester.widget<EpisodeList>(find.byType(EpisodeList)).episodes)
    episode.id,
];

class _SearchApi extends DemoApiClient {
  _SearchApi(super.library);

  final requests = <(int, String, Completer<List<int>>)>[];
  final globalRequests = <(String, Completer<List<int>>)>[];

  @override
  Future<List<int>> searchPodcast(
    int podcastId,
    String query, {
    Duration? timeout,
  }) {
    final result = Completer<List<int>>();
    requests.add((podcastId, query, result));
    return result.future;
  }

  @override
  Future<List<int>> searchAll(String query, {Duration? timeout}) {
    final result = Completer<List<int>>();
    globalRequests.add((query, result));
    return result.future;
  }
}
