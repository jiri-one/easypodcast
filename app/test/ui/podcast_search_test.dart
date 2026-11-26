import 'dart:async';

import 'package:easypodcast/core/api.dart';
import 'package:easypodcast/core/models.dart';
import 'package:easypodcast/core/services.dart';
import 'package:easypodcast/ui/eink_widgets.dart';
import 'package:easypodcast/ui/library_views.dart';
import 'package:easypodcast/ui/podcast_search.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'fixtures/demo_api.dart';
import 'fixtures/demo_library.dart';
import 'fixtures/demo_sync.dart';
import 'ui_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadTestFonts);

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
      expect(api.requests, isEmpty);

      await app.tap(find.byTooltip(l.clearSearch));
      expect(field, findsNothing);
      expect(_episodeIds(tester), all);
      await app.row(l.searchThisPodcast);
      await tester.enterText(field, 'no such episode');
      await tester.pump();
      expect(_episodeIds(tester), isEmpty);
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
}

Future<(UiHarness, _SearchApi)> _openPodcast(WidgetTester tester) async {
  late _SearchApi api;
  final app = await UiHarness.open(
    tester,
    configure: (demo) => AppServices(
      settings: demo.settings,
      library: demo.library,
      sync: demo.sync,
      player: demo.player,
      downloads: demo.downloads,
      api: api = _SearchApi(demo.library as DemoLibrary),
    ),
  );
  await app.section(LibrarySection.podcasts);
  await app.scrollToRow(
    app.services.library.podcast(1)!.title,
    find.byType(PodcastList),
  );
  return (app, api);
}

List<int> _episodeIds(WidgetTester tester) => [
  for (final episode
      in tester.widget<EpisodeList>(find.byType(EpisodeList)).episodes)
    episode.id,
];

class _SearchApi extends DemoApiClient {
  _SearchApi(super.library);

  final requests = <(int, String, Completer<List<int>>)>[];

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
}
