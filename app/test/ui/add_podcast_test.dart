import 'dart:async';

import 'package:easypodcast/core/api.dart';
import 'package:easypodcast/core/models.dart';
import 'package:easypodcast/core/services.dart';
import 'package:easypodcast/ui/account_pages.dart';
import 'package:easypodcast/ui/eink_widgets.dart';
import 'package:easypodcast/ui/library_views.dart';
import 'package:easypodcast/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'fixtures/demo_api.dart';
import 'fixtures/demo_library.dart';
import 'ui_test_support.dart';

const DirectoryPodcast _railway = (
  feedUrl: 'https://railway.example/feed.xml',
  title: 'Noční vlak',
  author: 'Jana Hlaváčková',
  imageUrl: null,
  subscribed: false,
);

const DirectoryPodcast _planes = (
  feedUrl: 'https://planes.example/feed.xml',
  title: 'Papírová letadla',
  author: '',
  imageUrl: null,
  subscribed: false,
);

final _page = find.byType(AddPodcastPage);
final _fields = find.descendant(of: _page, matching: find.byType(TextField));

Finder _button(String label) => find.descendant(
  of: _page,
  matching: find.widgetWithText(EinkButton, label),
);

Finder _rowText(DirectoryPodcast result, String label) => find.descendant(
  of: find.widgetWithText(EinkRow, result.title),
  matching: find.text(label),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadTestFonts);

  testWidgets(
    'only a valid explicit submit searches and waiting blocks repeats',
    (tester) async {
      final (app, api, _) = await _open(tester);
      final l = app.strings;
      try {
        final searchSize = tester.getSize(_button(l.search));
        await tester.enterText(_fields.first, '  a ');
        await tester.pump(const Duration(seconds: 1));
        expect(api.searches, isEmpty);
        await app.tap(_button(l.search));
        expect(
          find.widgetWithText(EinkError, l.directoryTooShort),
          findsOneWidget,
        );
        expect(api.searches, isEmpty);

        await tester.enterText(_fields.first, '  noční vlak  ');
        expect(
          tester.widget<TextField>(_fields.first).textInputAction,
          TextInputAction.search,
        );
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        expect(api.searches.single.query, 'noční vlak');
        expect(tester.getSize(_button(l.searching)), searchSize);
        expect(
          find.byWidgetPredicate((widget) => widget is ProgressIndicator),
          findsNothing,
        );
        expect(find.text(l.directoryTooShort), findsNothing);
        await app.tap(_button(l.searching));
        expect(api.searches, hasLength(1));

        api.searches.single.response.complete([_railway]);
        await tester.pumpAndSettle();
        expect(find.text(_railway.title), findsOneWidget);
        await tester.enterText(_fields.first, '  papír  ');
        await app.tap(_button(l.search));
        expect(api.searches.map((call) => call.query), ['noční vlak', 'papír']);
        expect(find.text(_railway.title), findsNothing);
        api.searches.last.response.complete(const []);
        await tester.pumpAndSettle();
        expect(find.text(l.directoryEmpty), findsOneWidget);
        expect(find.byType(EinkError), findsNothing);
      } finally {
        await app.finish();
      }
    },
  );

  testWidgets('search errors are shown by type and status and can be retried', (
    tester,
  ) async {
    final (app, api, _) = await _open(tester);
    final l = app.strings;
    try {
      await tester.enterText(_fields.first, 'noční vlak');
      for (final (error, label) in [
        (OfflineException(), l.directoryOffline),
        (ApiException(404, 'not found'), l.directoryOff),
        (ApiException(502, '<html>Bad gateway</html>'), l.directoryFailed),
      ]) {
        await app.tap(_button(l.search));
        expect(find.byType(EinkError), findsNothing);
        api.searches.last.response.completeError(error);
        await tester.pumpAndSettle();
        expect(find.widgetWithText(EinkError, label), findsOneWidget);
        expect(find.text(l.directoryEmpty), findsNothing);
      }
      expect(api.searches, hasLength(3));
    } finally {
      await app.finish();
    }
  });

  testWidgets('only subscribed rows show a bold mark and hide the plus', (
    tester,
  ) async {
    final (app, api, library) = await _open(tester);
    final l = app.strings;
    final results = await DemoApiClient(library).searchDirectory('vlak');
    try {
      await _showResults(app, api, results);
      for (final result in results.take(2)) {
        final row = find.widgetWithText(EinkRow, result.title);
        expect(row, findsOneWidget);
        expect(_rowText(result, result.author), findsOneWidget);
        final mark = _rowText(result, l.subscribedMark);
        final plus = find.descendant(of: row, matching: find.byIcon(Icons.add));
        if (result.subscribed) {
          expect(mark, findsOneWidget);
          expect(tester.widget<Text>(mark).style?.fontWeight, FontWeight.w700);
          expect(plus, findsNothing);
        } else {
          expect(mark, findsNothing);
          expect(plus, findsOneWidget);
          expect(tester.widget<Icon>(plus).semanticLabel, l.addPodcast);
        }
        expect(
          tester
              .widget<PodcastThumbnail>(
                find.descendant(
                  of: row,
                  matching: find.byType(PodcastThumbnail),
                ),
              )
              .imageUrl,
          result.imageUrl,
        );
      }
      expect(find.text(l.subscribedMark), findsOneWidget);
    } finally {
      await app.finish();
    }
  });

  testWidgets(
    'cancel does nothing and confirmation adds the selected feed once',
    (tester) async {
      final (app, api, library) = await _open(tester);
      final l = app.strings;
      try {
        await _showResults(app, api, [_railway, _planes]);
        await app.row(_railway.title);
        final dialog = find.byType(EinkDialogPanel);
        expect(
          find.widgetWithText(EinkDialogPanel, l.subscribeTitle),
          findsOneWidget,
        );
        expect(
          find.widgetWithText(
            EinkDialogPanel,
            '${_railway.title}\n${_railway.author}',
          ),
          findsOneWidget,
        );
        expect(library.adds, isEmpty);
        await app.dialog(l.cancel);
        expect(dialog, findsNothing);
        expect(library.adds, isEmpty);
        expect(_rowText(_railway, l.addingPodcast), findsNothing);

        await app.row(_railway.title);
        await app.dialog(l.addPodcast);
        expect(library.adds.single.feedUrl, _railway.feedUrl);
        expect(_rowText(_railway, l.addingPodcast), findsOneWidget);
        expect(_rowText(_planes, l.addingPodcast), findsNothing);
        expect(tester.widget<TextField>(_fields.last).enabled, isFalse);
        await app.row(_planes.title);
        await app.tap(_button(l.search));
        expect(dialog, findsNothing);
        expect(library.adds, hasLength(1));
        expect(api.searches, hasLength(1));

        library.adds.single.response.complete();
        await tester.pumpAndSettle();
        expect(_page, findsNothing);
        expect(
          find.widgetWithText(EinkHeader, 'railway.example'),
          findsWidgets,
        );
        await app.back();
        expect(find.byType(PodcastList), findsOneWidget);
      } finally {
        await app.finish();
      }
    },
  );

  testWidgets('an already subscribed result still asks before opening', (
    tester,
  ) async {
    final (app, api, library) = await _open(tester);
    final l = app.strings;
    final show = (await DemoApiClient(library).searchDirectory('vlak')).first;
    expect(show.subscribed, isTrue);
    try {
      await _showResults(app, api, [show]);
      await app.row(show.title);
      expect(
        find.widgetWithText(EinkDialogPanel, l.subscribeTitle),
        findsOneWidget,
      );
      expect(library.adds, isEmpty);
      await app.dialog(l.addPodcast);
      expect(library.adds.single.feedUrl, show.feedUrl);
      library.adds.single.response.complete();
      await tester.pumpAndSettle();
      expect(_page, findsNothing);
      expect(
        find.widgetWithText(EpisodeList, app.episode(101)),
        findsOneWidget,
      );
    } finally {
      await app.finish();
    }
  });

  testWidgets('a failed directory add shows a row error and can be retried', (
    tester,
  ) async {
    final (app, api, library) = await _open(tester);
    final l = app.strings;
    try {
      await _showResults(app, api, [_planes, _railway]);
      for (final (code, label) in [
        (422, l.feedUnavailable),
        (502, l.subscribeFailed),
      ]) {
        await app.row(_planes.title);
        final dialog = tester.widget<EinkDialogPanel>(
          find.byType(EinkDialogPanel),
        );
        expect(dialog.message, _planes.title);
        await app.dialog(l.addPodcast);
        expect(find.byType(EinkError), findsNothing);
        library.adds.last.response.completeError(
          ApiException(code, 'test failure'),
        );
        await tester.pumpAndSettle();
        final inRow = find.descendant(
          of: find.widgetWithText(EinkRow, _planes.title),
          matching: find.widgetWithText(EinkError, label),
        );
        expect(inRow, findsOneWidget);
        expect(tester.widget<EinkError>(inRow).liveRegion, isFalse);
        expect(_rowText(_railway, label), findsNothing);
        expect(tester.widget<TextField>(_fields.last).enabled, isTrue);
      }
      expect(library.adds.map((call) => call.feedUrl), [
        _planes.feedUrl,
        _planes.feedUrl,
      ]);
    } finally {
      await app.finish();
    }
  });

  testWidgets('a pasted feed address still adds directly', (tester) async {
    final (app, api, library) = await _open(tester);
    final l = app.strings;
    try {
      const address = 'https://pasted.example/feed.xml';
      await tester.enterText(_fields.last, '  $address ');
      await app.tap(_button(l.addPodcast), within: _page);
      expect(library.adds.single.feedUrl, address);
      expect(_button(l.addingPodcast), findsOneWidget);
      expect(find.byType(EinkDialogPanel), findsNothing);
      expect(api.searches, isEmpty);
      library.adds.single.response.complete();
      await tester.pumpAndSettle();
      expect(_page, findsNothing);
      expect(find.widgetWithText(EinkHeader, 'pasted.example'), findsWidgets);
    } finally {
      await app.finish();
    }
  });
}

Future<(UiHarness, _DirectoryApi, _DirectoryLibrary)> _open(
  WidgetTester tester,
) async {
  final library = _DirectoryLibrary();
  final api = _DirectoryApi(library);
  final app = await UiHarness.open(
    tester,
    library: library,
    playerCover: true,
    configure: (services) => AppServices(
      api: api,
      sync: services.sync,
      library: services.library,
      player: services.player,
      downloads: services.downloads,
      settings: services.settings,
    ),
  );
  await app.section(LibrarySection.podcasts);
  await app.row(app.strings.addPodcast);
  return (app, api, library);
}

Future<void> _showResults(
  UiHarness app,
  _DirectoryApi api,
  List<DirectoryPodcast> results,
) async {
  await app.tester.enterText(_fields.first, 'vlak');
  await app.tap(_button(app.strings.search));
  api.searches.single.response.complete(results);
  await app.tester.pumpAndSettle();
}

class _DirectoryApi extends DemoApiClient {
  _DirectoryApi(super.library);

  final searches =
      <({String query, Completer<List<DirectoryPodcast>> response})>[];

  @override
  Future<List<DirectoryPodcast>> searchDirectory(
    String query, {
    Duration? timeout,
  }) {
    final response = Completer<List<DirectoryPodcast>>();
    searches.add((query: query, response: response));
    return response.future;
  }
}

class _DirectoryLibrary extends DemoLibrary {
  final adds = <({String feedUrl, Completer<void> response})>[];

  @override
  Future<Podcast> subscribe(String feedUrl) async {
    final response = Completer<void>();
    adds.add((feedUrl: feedUrl, response: response));
    await response.future;
    return super.subscribe(feedUrl);
  }
}
