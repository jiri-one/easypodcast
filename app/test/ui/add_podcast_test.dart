import 'dart:async';

import 'package:easypodcast/core/api.dart';
import 'package:easypodcast/core/models.dart';
import 'package:easypodcast/core/services.dart';
import 'package:easypodcast/ui/account_pages.dart';
import 'package:easypodcast/ui/eink_widgets.dart';
import 'package:easypodcast/ui/library_views.dart';
import 'package:easypodcast/ui/theme.dart';
import 'package:flutter/services.dart';
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
  late String font;
  setUpAll(() async => font = await loadTestFonts());

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
        expect(tester.testTextInput.isVisible, isTrue);
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
        expect(tester.widget<TextField>(_fields.first).enabled, isFalse);
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
        expect(find.text(l.directoryEmpty), findsNothing);
        await tester.enterText(_fields.first, '  papír  ');
        await app.tap(_button(l.search));
        expect(tester.testTextInput.isVisible, isFalse);
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
        (TypeError(), l.directoryFailed),
      ]) {
        await app.tap(_button(l.search));
        expect(find.byType(EinkError), findsNothing);
        api.searches.last.response.completeError(error);
        await tester.pumpAndSettle();
        expect(find.widgetWithText(EinkError, label), findsOneWidget);
        expect(find.text(l.directoryEmpty), findsNothing);
      }
      expect(api.searches, hasLength(4));
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
        await app.row(_planes.title);
        expect(dialog, findsNothing);
        await tester.pump(const Duration(milliseconds: 600));

        await app.row(_railway.title);
        await tester.tap(
          find.descendant(of: dialog, matching: find.text(l.addPodcast)),
        );
        await tester.pump();
        expect(dialog, findsOneWidget);
        expect(library.adds, isEmpty);
        await app.dialog(l.addPodcast);
        expect(library.adds.single.feedUrl, _railway.feedUrl);
        expect(_rowText(_railway, l.addingPodcast), findsOneWidget);
        expect(_rowText(_planes, l.addingPodcast), findsNothing);
        expect(_button(l.addingPodcast), findsNothing);
        expect(tester.widget<TextField>(_fields.first).enabled, isFalse);
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

  testWidgets('Cancel leaves both fields usable after a rebuild', (
    tester,
  ) async {
    final (app, api, _) = await _open(tester);
    try {
      await _showResults(app, api, [_railway]);
      await tester.showKeyboard(_fields.first);
      await app.row(_railway.title);
      await app.services.sync.syncNow();
      await tester.pump();
      await app.dialog(app.strings.cancel);
      expect(tester.widget<TextField>(_fields.first).enabled, isTrue);
      expect(tester.widget<TextField>(_fields.last).enabled, isTrue);
    } finally {
      await app.finish();
    }
  });

  testWidgets('result rows span the page and the plus grows with the text', (
    tester,
  ) async {
    final (app, api, library) = await _open(tester);
    final long = (await DemoApiClient(library).searchDirectory('vlak')).last;
    try {
      await _showResults(app, api, [long]);
      final row = find.widgetWithText(EinkRow, long.title);
      expect(tester.getRect(row).left, 0);
      expect(tester.getRect(row).right, tester.getSize(_page).width);
      expect(tester.getRect(_fields.first).left, 12);
      expect(tester.getRect(_fields.last).left, 12);
      final top = tester.getRect(row).top + 10;
      final thumbnail = find.descendant(
        of: row,
        matching: find.byType(PodcastThumbnail),
      );
      expect(tester.getRect(thumbnail).top, top);
      expect(
        tester.getRect(find.text(app.strings.addPodcastHelp)).top,
        tester.getRect(row).bottom + 24,
      );
      final plus = find.descendant(of: row, matching: find.byIcon(Icons.add));
      expect(tester.getRect(plus).top, top);
      expect(tester.getSize(plus).width, moreOrLessEquals(24 * 1.8));
    } finally {
      await app.finish();
    }
  });

  testWidgets('an already subscribed result opens without asking', (
    tester,
  ) async {
    final (app, api, library) = await _open(tester);
    final show = (await DemoApiClient(library).searchDirectory('vlak')).first;
    expect(show.subscribed, isTrue);
    try {
      await _showResults(app, api, [show]);
      await app.row(show.title);
      expect(find.byType(EinkDialogPanel), findsNothing);
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
      expect(_rowText(_planes, ''), findsNothing);
      for (final (Object error, label) in [
        (ApiException(422, 'test failure'), l.feedUnavailable),
        (ApiException(502, 'test failure'), l.subscribeFailed),
        (OfflineException(), l.subscribeFailed),
      ]) {
        await app.row(_planes.title);
        final dialog = tester.widget<EinkDialogPanel>(
          find.byType(EinkDialogPanel),
        );
        expect(dialog.message, _planes.title);
        await app.dialog(l.addPodcast);
        expect(find.byType(EinkError), findsNothing);
        library.adds.last.response.completeError(error);
        await tester.pumpAndSettle();
        final inRow = find.descendant(
          of: find.widgetWithText(EinkRow, _planes.title),
          matching: find.widgetWithText(EinkError, label),
        );
        expect(inRow, findsOneWidget);
        expect(tester.widget<EinkError>(inRow).liveRegion, isFalse);
        expect(
          tester
              .widget<RichText>(
                find.descendant(of: inRow, matching: find.byType(RichText)),
              )
              .text
              .style
              ?.fontSize,
          detailStyle.fontSize,
        );
        expect(_rowText(_railway, label), findsNothing);
        expect(tester.widget<TextField>(_fields.last).enabled, isTrue);
        await tester.pump(const Duration(milliseconds: 600));
      }
      expect(library.adds.map((call) => call.feedUrl), [
        _planes.feedUrl,
        _planes.feedUrl,
        _planes.feedUrl,
      ]);
      await app.tap(_button(l.search));
      api.searches.last.response.complete([_planes, _railway]);
      await tester.pumpAndSettle();
      expect(find.byType(EinkError), findsNothing);
    } finally {
      await app.finish();
    }
  });

  testWidgets('Linux keys still work after a search', (tester) async {
    final (app, api, _) = await _open(tester, desktopFont: font);
    try {
      await tester.enterText(_fields.first, 'vlak');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      api.searches.single.response.complete([_railway]);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(_page, findsNothing);
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
      expect(tester.testTextInput.isVisible, isFalse);
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
  WidgetTester tester, {
  String? desktopFont,
}) async {
  final library = _DirectoryLibrary();
  final api = _DirectoryApi(library);
  final app = await UiHarness.open(
    tester,
    size: desktopFont == null ? const Size(360, 720) : const Size(1000, 700),
    desktopFont: desktopFont,
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
