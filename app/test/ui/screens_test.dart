import 'dart:async';

import 'package:easypodcast/core/downloads.dart';
import 'package:easypodcast/ui/account_pages.dart';
import 'package:easypodcast/ui/eink_widgets.dart';
import 'package:easypodcast/ui/episode_page.dart';
import 'package:easypodcast/ui/library_views.dart';
import 'package:easypodcast/ui/player_views.dart';
import 'package:easypodcast/ui/theme.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'fixtures/demo_sync.dart';
import 'ui_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String font;
  setUpAll(() async => font = await loadTestFonts());

  for (final locale in const [Locale('cs'), Locale('en')]) {
    for (final (size, desktop, textScale) in const [
      (Size(392, 785), false, 1.8),
      (Size(360, 720), false, 1.8),
      (palmaSize, false, palmaTextScale),
      (Size(760, 700), true, 1.8),
      (Size(950, 700), true, 1.8),
      (Size(1000, 700), true, 1.8),
    ]) {
      testWidgets('all $locale screens fit at ${size.width} × ${size.height}', (
        tester,
      ) async {
        final app = await UiHarness.open(
          tester,
          size: size,
          locale: locale,
          textScale: textScale,
          desktopFont: desktop ? font : null,
          playerCover: true,
        );
        Future<void> check(String name) async {
          expect(tester.takeException(), isNull, reason: name);
          _checkTextLayout(name);
        }

        try {
          if (desktop) {
            final heading = find.descendant(
              of: find.widgetWithText(EinkRow, app.strings.inProgress),
              matching: find.text(app.strings.inProgress),
            );
            final scale = MediaQuery.textScalerOf(tester.element(heading));
            expect(
              tester.getSize(heading).height,
              lessThan(scale.scale(rowTitleStyle.fontSize!) * 1.5),
            );
            await tourDesktop(app, check);
          } else {
            await tourPhone(app, check);
          }
        } finally {
          await app.finish();
        }
      });
    }
  }

  testWidgets('mini player checks and resumes a stored position with one tap', (
    tester,
  ) async {
    final app = await _phone(tester);
    final player = app.services.player;
    final library = app.services.library;
    final l = app.strings;
    final episode = library.inProgress.first;
    final stored = Duration(
      milliseconds: library.stateOf(episode.id).positionMs,
    );
    final check = Completer<void>();
    final sync = app.services.sync as DemoSyncService;
    sync.beforePlay = (id) {
      expect(id, episode.id);
      return check.future;
    };
    try {
      final mini = find.byType(MiniPlayer);
      final original = tester.getRect(mini);
      await app.mini(l.play);
      expect(find.text(l.checkingPosition), findsOneWidget);
      expect(player.isPlaying, isFalse);

      check.complete();
      await tester.pumpAndSettle();
      expect(player.current?.id, episode.id);
      expect(player.position.value, stored);
      expect(player.isPlaying, isTrue);

      await app.mini(l.pause);
      expect(player.isPlaying, isFalse);
      expect(tester.getRect(mini), original);
      await app.mini(episode.title);
      expect(find.byType(PlayerPage), findsOneWidget);
      await app.tapText(
        l.skipForwardValue(app.services.settings.skipForwardSeconds),
      );
      expect(player.position.value, stored + const Duration(seconds: 30));
      expect(tester.takeException(), isNull);
    } finally {
      if (!check.isCompleted) check.complete();
      await app.finish();
    }
  });

  testWidgets(
    'playback clocks sample every second and immediately after a skip',
    (tester) async {
      final app = await _phone(tester);
      final player = app.services.player;
      try {
        await app.mini(app.strings.play);
        await app.mini(app.episode(101));
        expect(find.text('32:00'), findsOneWidget);
        expect(find.text('−23:00'), findsOneWidget);
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('32:01'), findsOneWidget);
        expect(find.text('−22:59'), findsOneWidget);

        await app.tapText(app.strings.skipForwardValue(30));
        expect(player.position.value, const Duration(minutes: 32, seconds: 31));
        expect(find.text('32:31'), findsOneWidget);
      } finally {
        await app.finish();
      }
    },
  );

  testWidgets('episode-end sleep stops before the next queued episode', (
    tester,
  ) async {
    final app = await _phone(tester);
    final l = app.strings;
    final player = app.services.player;
    try {
      await app.mini(l.play);
      await app.mini(app.episode(101));
      await app.tapText(l.sleep);
      await app.dialog(l.sleepEndOfEpisode);
      expect(find.text(l.sleepEndValue), findsOneWidget);
      expect(player.sleepAtEndOfEpisode, isTrue);
      expect(player.sleepRemaining, isNull);
      final nextId = app.services.library.queue.first.id;
      app.engine.complete(player.duration!);
      await tester.pumpAndSettle();
      expect(app.services.library.stateOf(101).isPlayed, isTrue);
      expect(player.current, isNull);
      expect(app.services.library.queue.first.id, nextId);
      expect(player.isPlaying, isFalse);
      expect(app.services.settings.autoplayQueue, isTrue);
    } finally {
      await app.finish();
    }
  });

  testWidgets('dismiss asks before losing a position or download', (
    tester,
  ) async {
    final app = await _phone(tester);
    final l = app.strings;
    final library = app.services.library;
    try {
      await app.openEpisode(204);
      await app.tapText(l.dismiss);
      expect(find.text(l.dismissTitle), findsOneWidget);
      expect(find.text(l.dismissPositionAndFile('41:00')), findsOneWidget);
      await tester.tapAt(const Offset(12, 12));
      await tester.pumpAndSettle();
      expect(find.byType(EinkDialogPanel), findsOneWidget);
      await app.dialog(l.cancel);
      expect(library.stateOf(204).positionMs, 2460000);
      expect(app.services.downloads.statusOf(204).status, DownloadStatus.done);

      await tester.pump(const Duration(milliseconds: 601));
      await app.tapText(l.dismiss);
      await app.dialog(l.dismiss);
      expect(library.stateOf(204).isDismissed, isTrue);
      expect(library.stateOf(204).positionMs, 0);
      expect(library.inProgress.any((episode) => episode.id == 204), isFalse);
      expect(app.services.downloads.statusOf(204).status, DownloadStatus.none);
      expect(find.byType(EpisodePage), findsOneWidget);
      expect(find.text(l.markNew), findsOneWidget);
    } finally {
      await app.finish();
    }
  });

  testWidgets(
    'dismiss is immediate for untouched episodes and absent for played',
    (tester) async {
      final app = await _phone(tester);
      final l = app.strings;
      final library = app.services.library;
      try {
        await app.section(LibrarySection.newEpisodes);
        await app.openEpisode(201);
        await app.tapText(l.dismiss);
        expect(find.byType(EinkDialogPanel), findsNothing);
        expect(library.stateOf(201).isDismissed, isTrue);
        await tester.pump(const Duration(milliseconds: 601));
        await app.tapText(l.markNew);
        await tester.pump(const Duration(milliseconds: 601));
        await app.tapText(l.markPlayed);
        expect(library.stateOf(201).isPlayed, isTrue);
        expect(find.text(l.dismiss), findsNothing);
        expect(find.text(l.markNew), findsOneWidget);
      } finally {
        await app.finish();
      }
    },
  );

  testWidgets(
    'bulk dismissal counts eligible episodes and preserves the queue',
    (tester) async {
      final app = await _phone(tester);
      final l = app.strings;
      final library = app.services.library;
      final queued = library.queue.map((episode) => episode.id).toList();
      final eligible = library
          .episodesOf(2)
          .where(
            (episode) =>
                library.stateOf(episode.id).isNew &&
                !queued.contains(episode.id),
          );
      final count = eligible.length;
      try {
        await app.section(LibrarySection.newEpisodes);
        await app.openEpisode(201);
        await app.tapText(l.dismissOlder);
        expect(find.text(l.dismissCountTitle(count)), findsOneWidget);
        await app.dialog(l.dismissCount(count));
        expect(library.stateOf(201).isDismissed, isTrue);
        expect(library.stateOf(203).isNew, isTrue);
        expect(library.stateOf(204).isInProgress, isTrue);
        expect(library.stateOf(207).isPlayed, isTrue);
        expect(library.queue.map((episode) => episode.id), queued);
      } finally {
        await app.finish();
      }
    },
  );

  testWidgets('enqueue flips in place and tapping a queue row opens its page', (
    tester,
  ) async {
    final app = await _phone(tester);
    final l = app.strings;
    final library = app.services.library;
    List<int> ids() => [for (final episode in library.queue) episode.id];
    try {
      await app.section(LibrarySection.newEpisodes);
      await app.openEpisode(201);
      final addedAt = tester.getRect(
        find.widgetWithText(EinkButton, l.addToQueue),
      );
      await app.tapText(l.addToQueue);
      expect(ids(), [203, 401, 602, 201]);
      expect(
        tester.getRect(find.widgetWithText(EinkButton, l.removeFromQueue)),
        addedAt,
      );
      await app.back();
      await app.section(LibrarySection.queue);
      await app.row(l.numberedTitle(4, app.episode(201)));
      expect(find.byType(EpisodePage), findsOneWidget);
      await app.tapText(l.removeFromQueue);
      expect(ids(), [203, 401, 602]);
    } finally {
      await app.finish();
    }
  });

  testWidgets('list switcher closes outside and system Back returns home', (
    tester,
  ) async {
    final app = await _phone(tester);
    final l = app.strings;
    try {
      await app.menu();
      expect(find.widgetWithText(EinkRow, l.queue), findsOneWidget);
      await tester.tapAt(const Offset(180, 650));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(EinkRow, l.queue), findsNothing);
      for (final section in LibrarySection.values.skip(1)) {
        await app.section(section);
        final title = section.label(tester.element(find.byType(EinkHeader)));
        expect(find.widgetWithText(EinkHeader, title), findsOneWidget);
        await app.back();
        expect(find.widgetWithText(EinkHeader, l.inProgress), findsOneWidget);
      }
      expect(app.services.player.isPlaying, isFalse);
    } finally {
      await app.finish();
    }
  });

  testWidgets('login reports rejection and can succeed with the same fields', (
    tester,
  ) async {
    final app = await _phone(tester, loggedIn: false);
    final l = app.strings;
    try {
      expect(find.byType(LoginPage), findsOneWidget);
      Iterable<TextField> fields() =>
          tester.widgetList<TextField>(find.byType(TextField));
      expect(fields().first.controller!.text, isEmpty);
      expect(fields().first.decoration!.hintText, 'https://…');
      expect(
        fields().take(3).map((field) => field.textInputAction),
        everyElement(TextInputAction.next),
      );
      expect(fields().last.controller!.text, l.defaultAndroidDevice);
      expect(fields().elementAt(2).obscureText, isTrue);
      await app.login(reject: true);
      expect(find.widgetWithText(EinkError, l.loginRejected), findsOneWidget);
      expect(app.services.sync.isLoggedIn, isFalse);
      await app.login();
      expect(app.services.sync.isLoggedIn, isTrue);
      expect(find.byType(LoginPage), findsNothing);
      expect(find.widgetWithText(EinkHeader, l.inProgress), findsOneWidget);
    } finally {
      await app.finish();
    }
  });

  testWidgets('Linux keys control playback, selection, and Back', (
    tester,
  ) async {
    final app = await UiHarness.open(
      tester,
      size: const Size(1000, 700),
      locale: const Locale('en'),
      desktopFont: font,
    );
    final player = app.services.player;
    final library = app.services.library;
    final l = app.strings;
    Future<void> key(LogicalKeyboardKey key) async {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }

    try {
      final first = library.inProgress.first.id;
      final initial = Duration(milliseconds: library.stateOf(first).positionMs);
      expect(find.byType(MiniPlayer), findsNothing);
      expect(find.byType(DesktopPlayer), findsOneWidget);
      expect(find.text(l.downloads), findsNothing);
      expect(find.text(l.sleep), findsNothing);
      await key(LogicalKeyboardKey.space);
      expect(player.isPlaying, isTrue);
      await key(LogicalKeyboardKey.arrowRight);
      expect(player.position.value, initial + const Duration(seconds: 30));
      await key(LogicalKeyboardKey.arrowLeft);
      expect(player.position.value, initial + const Duration(seconds: 15));
      await key(LogicalKeyboardKey.arrowDown);
      expect(
        tester.widget<EpisodePage>(find.byType(EpisodePage)).episode.id,
        first,
      );
      await key(LogicalKeyboardKey.arrowDown);
      expect(
        tester.widget<EpisodePage>(find.byType(EpisodePage)).episode.id,
        204,
      );
      await key(LogicalKeyboardKey.arrowUp);
      expect(
        tester.widget<EpisodePage>(find.byType(EpisodePage)).episode.id,
        first,
      );
      await key(LogicalKeyboardKey.escape);
      expect(find.byType(EpisodePage), findsNothing);
      await key(LogicalKeyboardKey.space);
      expect(player.isPlaying, isFalse);
    } finally {
      await app.finish();
    }
  });
}

void _checkTextLayout(String screen) {
  final labels = find.descendant(
    of: find.byType(Text),
    matching: find.byType(RichText),
  );
  for (final element in labels.evaluate()) {
    final paragraph = element.renderObject! as RenderParagraph;
    final reason = '$screen: ${paragraph.text.toPlainText()}';
    expect(
      paragraph.text.style?.fontSize,
      greaterThanOrEqualTo(16),
      reason: reason,
    );
    expect(
      paragraph.size.height,
      greaterThanOrEqualTo(
        paragraph.getMaxIntrinsicHeight(paragraph.size.width) - 1,
      ),
      reason: reason,
    );
  }
  expect(
    find.descendant(of: find.byType(FittedBox), matching: find.byType(Text)),
    findsNothing,
    reason: screen,
  );
}

Future<UiHarness> _phone(WidgetTester tester, {bool loggedIn = true}) =>
    UiHarness.open(tester, size: const Size(392, 785), loggedIn: loggedIn);
