import 'dart:async';
import 'dart:ui' show SemanticsAction;

import 'package:easypodcast/core/api.dart';
import 'package:easypodcast/core/models.dart';
import 'package:easypodcast/ui/eink_widgets.dart';
import 'package:easypodcast/ui/library_views.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'fixtures/demo_library.dart';
import 'ui_test_support.dart';

final _panel = find.byType(EinkDialogPanel);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String font;
  setUpAll(() async => font = await loadTestFonts());

  testWidgets('holding a podcast opens its menu and tapping opens its page', (
    tester,
  ) async {
    final (app, podcast) = await _podcasts(tester);
    final l = app.strings;
    try {
      await app.holdRow(podcast.title);
      expect(_menuText(podcast.title), findsOneWidget);
      final unsubscribe = _menuText(l.unsubscribe);
      final toggle = _showInNewEpisodes(app);
      expect(unsubscribe, findsOneWidget);
      expect(toggle, findsOneWidget);
      expect(
        tester.getBottomLeft(unsubscribe).dy,
        lessThan(tester.getTopLeft(toggle).dy),
      );
      expect(
        find.descendant(of: _panel, matching: find.byType(EinkButton)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: _panel, matching: find.byType(EinkRow)),
        findsOneWidget,
      );
      await app.dialog(l.close);

      await app.row(podcast.title);
      expect(find.byType(EpisodeList), findsOneWidget);
      expect(find.byTooltip(l.aboutPodcast), findsOneWidget);
      expect(_panel, findsNothing);
    } finally {
      await app.finish();
    }
  });

  testWidgets(
    'right-click, Shift+F10, and Menu open podcast actions on Linux',
    (tester) async {
      final (app, podcast) = await _podcasts(tester, desktopFont: font);
      try {
        await app.holdRow(podcast.title, rightClick: true);
        expect(_menuText(podcast.title), findsOneWidget);
        await app.dialog(app.strings.close);

        final rowFocus = Focus.of(tester.element(find.text(podcast.title)));
        rowFocus.requestFocus();
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.f10);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pumpAndSettle();
        expect(_menuText(podcast.title), findsOneWidget);
        await app.dialog(app.strings.close);

        rowFocus.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
        await tester.pumpAndSettle();
        expect(_menuText(podcast.title), findsOneWidget);
      } finally {
        await app.finish();
      }
    },
  );

  testWidgets('podcast rows expose a named accessibility action', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final (app, podcast) = await _podcasts(tester);
    try {
      final node = tester.getSemantics(
        find.widgetWithText(EinkRow, podcast.title),
      );
      expect(node.hintOverrides?.onLongPressHint, app.strings.podcastActions);
      expect(
        node.getSemanticsData().hasAction(SemanticsAction.longPress),
        isTrue,
      );
      node.owner!.performAction(node.id, SemanticsAction.longPress);
      await tester.pumpAndSettle();
      expect(_menuText(podcast.title), findsOneWidget);
    } finally {
      semantics.dispose();
      await app.finish();
    }
  });

  testWidgets('a second menu cannot open over the first', (tester) async {
    final semantics = tester.ensureSemantics();
    final (app, _) = await _podcasts(tester);
    try {
      for (final podcast in app.services.library.podcasts.take(2)) {
        final node = tester.getSemantics(
          find.widgetWithText(EinkRow, podcast.title),
        );
        node.owner!.performAction(node.id, SemanticsAction.longPress);
      }
      await tester.pumpAndSettle();
      expect(find.byType(EinkDialogPanel, skipOffstage: false), findsOneWidget);
    } finally {
      semantics.dispose();
      await app.finish();
    }
  });

  testWidgets('global search podcast rows open the same menu', (tester) async {
    final app = await UiHarness.open(tester, size: const Size(392, 785));
    final podcast = app.services.library.podcast(1)!;
    try {
      await app.section(LibrarySection.search);
      await tester.enterText(find.byType(TextField), 'posledni');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      final row = find.byWidgetPredicate(
        (widget) => widget is EinkRow && widget.title == podcast.title,
      );
      await tester.longPress(row);
      await tester.pumpAndSettle();
      expect(_menuText(podcast.title), findsOneWidget);
      expect(_menuText(app.strings.unsubscribe), findsOneWidget);
      expect(_showInNewEpisodes(app), findsOneWidget);
    } finally {
      await app.finish();
    }
  });

  for (final fails in [false, true]) {
    testWidgets(
      fails
          ? 'the menu switch rolls back and shows a failed request'
          : 'the menu switch displays its requested value until it is saved',
      (tester) async {
        final library = DemoLibrary();
        final reply = Completer<void>();
        final calls = <(int, bool)>[];
        library.beforeShowInNewEpisodes = (id, show) {
          calls.add((id, show));
          return reply.future;
        };
        final (app, podcast) = await _podcasts(tester, library: library);
        try {
          await app.holdRow(podcast.title);
          final toggle = _showInNewEpisodes(app);
          expect(tester.widget<EinkRow>(toggle).toggled, isTrue);
          await app.tap(toggle);
          await app.tap(toggle);
          expect(calls, [(podcast.id, false)]);
          expect(tester.widget<EinkRow>(toggle).toggled, isFalse);
          expect(library.podcast(podcast.id)!.showInNewEpisodes, isTrue);

          if (fails) {
            reply.completeError(OfflineException());
          } else {
            reply.complete();
          }
          await tester.pumpAndSettle();
          expect(tester.widget<EinkRow>(toggle).toggled, fails);
          expect(library.podcast(podcast.id)!.showInNewEpisodes, fails);
          expect(
            _menuText(app.strings.actionFailed),
            findsNWidgets(fails ? 1 : 0),
          );
        } finally {
          await app.finish();
        }
      },
    );
  }

  testWidgets('an open menu follows changes to the library', (tester) async {
    final library = DemoLibrary();
    final (app, podcast) = await _podcasts(tester, library: library);
    try {
      await app.holdRow(podcast.title);
      final toggle = _showInNewEpisodes(app);
      expect(tester.widget<EinkRow>(toggle).toggled, isTrue);
      await library.setShowInNewEpisodes(podcast.id, false);
      await tester.pumpAndSettle();
      expect(tester.widget<EinkRow>(toggle).toggled, isFalse);

      await app.dialog(app.strings.unsubscribe);
      await library.unsubscribe(podcast.id);
      await tester.pumpAndSettle();
      expect(_menuText(app.strings.unsubscribeTitle), findsOneWidget);
      final calls = <int>[];
      library.beforeUnsubscribe = (id) async => calls.add(id);
      await app.dialog(app.strings.unsubscribe);
      expect(calls, isEmpty);
      expect(_panel, findsNothing);
      expect(find.widgetWithText(EinkRow, podcast.title), findsNothing);
      final next = library.podcasts.first;
      await app.holdRow(next.title);
      expect(_menuText(next.title), findsOneWidget);
    } finally {
      await app.finish();
    }
  });

  testWidgets('cancel after an unsubscribe elsewhere closes the menu', (
    tester,
  ) async {
    final library = DemoLibrary();
    final (app, podcast) = await _podcasts(tester, library: library);
    final l = app.strings;
    try {
      await app.holdRow(podcast.title);
      await app.dialog(l.unsubscribe);
      await library.unsubscribe(podcast.id);
      await tester.pumpAndSettle();
      await app.dialog(l.cancel);
      expect(_panel, findsNothing);
      final next = library.podcasts.first;
      await app.holdRow(next.title);
      expect(_menuText(next.title), findsOneWidget);
    } finally {
      await app.finish();
    }
  });

  testWidgets('cancel leaves the subscription and confirm removes it once', (
    tester,
  ) async {
    final library = DemoLibrary();
    final reply = Completer<void>();
    final calls = <int>[];
    library.beforeUnsubscribe = (id) {
      calls.add(id);
      return reply.future;
    };
    final (app, podcast) = await _podcasts(tester, library: library);
    final l = app.strings;
    final row = find.widgetWithText(EinkRow, podcast.title);
    try {
      await app.holdRow(podcast.title);
      await app.dialog(l.unsubscribe);
      expect(_panel, findsOneWidget);
      expect(_menuText(l.unsubscribeHelp), findsOneWidget);
      await app.dialog(l.cancel);
      expect(calls, isEmpty);
      expect(library.podcast(podcast.id)!.subscribed, isTrue);
      expect(row, findsOneWidget);
      expect(_menuText(podcast.title), findsOneWidget);

      await app.dialog(l.unsubscribe);
      await app.dialog(l.unsubscribe);
      expect(_menuText(l.unsubscribing), findsOneWidget);
      expect(library.podcast(podcast.id)!.subscribed, isTrue);
      await app.dialog(l.unsubscribing);
      expect(calls, [podcast.id]);
      await app.dialog(l.close);
      expect(_menuText(l.unsubscribing), findsOneWidget);

      reply.complete();
      await tester.pumpAndSettle();
      expect(library.podcast(podcast.id)!.subscribed, isFalse);
      expect(_panel, findsNothing);
      expect(row, findsNothing);
      expect(
        Navigator.of(tester.element(find.byType(PodcastList))).canPop(),
        isFalse,
      );
    } finally {
      await app.finish();
    }
  });

  testWidgets('a failed unsubscribe leaves the menu open with an error', (
    tester,
  ) async {
    final library = DemoLibrary();
    final calls = <int>[];
    library.beforeUnsubscribe = (id) async {
      calls.add(id);
      throw OfflineException();
    };
    final (app, podcast) = await _podcasts(tester, library: library);
    final l = app.strings;
    try {
      await app.holdRow(podcast.title);
      await app.dialog(l.unsubscribe);
      await app.dialog(l.unsubscribe);
      expect(calls, [podcast.id]);
      expect(library.podcast(podcast.id)!.subscribed, isTrue);
      expect(find.widgetWithText(EinkRow, podcast.title), findsOneWidget);
      expect(_menuText(podcast.title), findsOneWidget);
      expect(_menuText(l.actionFailed), findsOneWidget);
      expect(_menuText(l.unsubscribe), findsOneWidget);
    } finally {
      await app.finish();
    }
  });

  testWidgets('the second tap of a double tap on the confirmation is ignored', (
    tester,
  ) async {
    final library = DemoLibrary()
      ..beforeUnsubscribe = (_) async => throw OfflineException();
    final (app, podcast) = await _podcasts(tester, library: library);
    final l = app.strings;
    final close = _menuText(l.close);
    try {
      await app.holdRow(podcast.title);
      await app.dialog(l.unsubscribe);
      await app.dialog(l.cancel);
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(_menuText(podcast.title), findsOneWidget);

      await app.dialog(l.unsubscribe);
      await app.dialog(l.unsubscribe);
      expect(_menuText(l.actionFailed), findsOneWidget);
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(_menuText(l.actionFailed), findsOneWidget);

      await app.dialog(l.close);
      expect(_panel, findsNothing);
    } finally {
      await app.finish();
    }
  });
}

Finder _menuText(String label) =>
    find.descendant(of: _panel, matching: find.text(label));

Finder _showInNewEpisodes(UiHarness app) => find.descendant(
  of: _panel,
  matching: find.widgetWithText(EinkRow, app.strings.showInNewEpisodes),
);

Future<(UiHarness, Podcast)> _podcasts(
  WidgetTester tester, {
  String? desktopFont,
  DemoLibrary? library,
}) async {
  final app = await UiHarness.open(
    tester,
    size: desktopFont == null ? const Size(392, 785) : const Size(1000, 700),
    desktopFont: desktopFont,
    library: library,
  );
  await app.section(LibrarySection.podcasts);
  return (app, app.services.library.podcasts.first);
}
