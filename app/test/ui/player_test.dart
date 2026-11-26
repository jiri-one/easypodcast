import 'package:easypodcast/ui/eink_widgets.dart';
import 'package:easypodcast/ui/episode_page.dart';
import 'package:easypodcast/ui/episode_text.dart';
import 'package:easypodcast/ui/playback_position.dart';
import 'package:easypodcast/ui/player_views.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'fixtures/demo_library.dart';
import 'fixtures/demo_sync.dart';
import 'ui_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String font;
  setUpAll(() async => font = await loadTestFonts());

  testWidgets(
    'dragging previews a seek and releases it once, while a tap does nothing',
    (tester) async {
      final library = _PositionLibrary();
      final app = await UiHarness.open(tester, library: library);
      final player = app.services.player;
      final clock = find.byKey(PlaybackTimeline.positionKey);
      try {
        await _start(app);
        await player.pause();
        await tester.pumpAndSettle();
        library.positions.clear();

        final track = find.byKey(PlaybackTimeline.trackKey);
        final area = tester.getRect(track);
        final original = player.position.value;
        final shown = positionText(original, padMinutes: true);
        expect(tester.widget<Text>(clock).data, shown);
        await tester.tapAt(area.centerLeft + const Offset(24, 0));
        await tester.pumpAndSettle();
        expect(player.position.value, original);
        expect(library.positions, isEmpty);

        final cancelled = await tester.startGesture(area.center);
        await cancelled.moveTo(area.centerLeft);
        await tester.pump();
        expect(tester.widget<Text>(clock).data, isNot(shown));
        await cancelled.cancel();
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(clock).data, shown);
        expect(library.positions, isEmpty);

        final drag = await tester.startGesture(area.center);
        await drag.moveTo(
          Offset(area.left + area.width * 0.30, area.center.dy),
        );
        await tester.pump();
        final first = tester.widget<Text>(clock).data;
        expect(first, isNot(shown));
        await drag.moveTo(
          Offset(area.left + area.width * 0.22, area.center.dy),
        );
        await tester.pump();
        final second = tester.widget<Text>(clock).data;
        expect(second, isNot(first));
        expect(library.positions, isEmpty);
        expect(player.position.value, original);

        await drag.up();
        await tester.pumpAndSettle();
        expect(library.positions, [player.position.value]);
        expect(positionText(player.position.value, padMinutes: true), second);
        expect(tester.widget<Text>(clock).data, second);
      } finally {
        await app.finish();
      }
    },
  );

  testWidgets('the mini player redraws every ten seconds', (tester) async {
    final app = await UiHarness.open(tester, size: const Size(392, 785));
    double progress() => tester
        .widget<FractionallySizedBox>(
          find.byKey(const ValueKey('mini-progress')),
        )
        .widthFactor!;
    try {
      final initial = progress();
      expect(initial, closeTo(32 / 55, 0.0001));
      await app.mini(app.strings.play);
      await tester.pump(const Duration(seconds: 9));
      expect(progress(), initial);
      await tester.pump(const Duration(seconds: 2));
      expect(progress(), greaterThan(initial));
    } finally {
      await app.finish();
    }
  });

  testWidgets('the phone player keeps its cover and opens the next episode', (
    tester,
  ) async {
    final app = await UiHarness.open(
      tester,
      size: const Size(392, 785),
      playerCover: true,
    );
    try {
      await _start(app);
      final podcast = app.services.library.podcast(1)!;
      expect(find.widgetWithText(EinkHeader, podcast.title), findsOneWidget);
      expect(find.text(podcast.title), findsOneWidget);
      final cover = tester.getSize(find.byType(ColorFiltered));
      expect(cover.width, cover.height);
      expect(cover.width, greaterThan(100));

      final next = app.services.library.queue.first;
      await app.tapText(app.strings.nextInQueue(next.title));
      expect(find.widgetWithText(EpisodePage, next.title), findsOneWidget);
    } finally {
      await app.finish();
    }
  });

  testWidgets('the PC player bar spans the window and refreshes each second', (
    tester,
  ) async {
    final app = await UiHarness.open(
      tester,
      size: const Size(1000, 700),
      desktopFont: font,
      playerCover: true,
    );
    final player = find.byType(DesktopPlayer);
    try {
      await app.tap(
        find.descendant(of: player, matching: find.text(app.strings.play)),
      );
      expect(
        tester.getSize(
          find.descendant(of: player, matching: find.byType(ColorFiltered)),
        ),
        const Size.square(52),
      );
      expect(
        tester.getSize(find.byKey(PlaybackTimeline.trackKey)).width,
        greaterThan(900),
      );
      expect(find.text('32:00'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('32:01'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await app.finish();
    }
  });

  testWidgets(
    'a cold timeline and skip button explain when seeking is unavailable',
    (tester) async {
      final app = await UiHarness.open(tester, size: const Size(392, 785));
      final l = app.strings;
      final player = app.services.player;
      try {
        await app.mini(app.episode(101));
        final track = tester.getRect(find.byKey(PlaybackTimeline.trackKey));
        final drag = await tester.startGesture(track.center);
        await drag.moveBy(const Offset(70, 0));
        await drag.up();
        await tester.pumpAndSettle();
        expect(find.text(l.seekUnavailable), findsOneWidget);
        expect(player.current, isNull);
        expect(app.services.library.stateOf(101).positionMs, 32 * 60 * 1000);

        await app.tap(find.byIcon(Icons.play_arrow));
        expect(find.text(l.seekUnavailable), findsNothing);
        await player.stop();
        await tester.pumpAndSettle();
        await app.tapText(l.skipBackValue(15));
        expect(find.text(l.seekUnavailable), findsOneWidget);
      } finally {
        await app.finish();
      }
    },
  );

  testWidgets('rebuffering keeps the mini player title and pause button', (
    tester,
  ) async {
    final app = await UiHarness.open(tester);
    try {
      await app.mini(app.strings.play);
      app.engine.buffer();
      await tester.pumpAndSettle();
      final mini = find.byType(MiniPlayer);
      expect(
        find.descendant(of: mini, matching: find.text(app.episode(101))),
        findsOneWidget,
      );
      expect(
        find.descendant(of: mini, matching: find.text(app.strings.pause)),
        findsOneWidget,
      );
      expect(find.text(app.strings.loadingPlayback), findsNothing);
    } finally {
      await app.finish();
    }
  });

  testWidgets('playback failures name the episode and retry through resume', (
    tester,
  ) async {
    final app = await UiHarness.open(tester);
    final l = app.strings;
    final player = app.services.player;
    final engine = app.engine;
    final failed = app.services.library.episode(201)!;
    final failure = StateError('Playback failed');
    Finder problem(String message) => find.text('${failed.title}\n$message');
    try {
      engine.loadError = failure;
      await expectLater(player.play(failed.id), throwsStateError);
      await tester.pumpAndSettle();
      expect(problem(l.playbackLoadFailed), findsOneWidget);

      engine.loadError = null;
      await app.mini(failed.title);
      final loads = engine.loadCalls;
      await app.tapText(l.retry);
      expect(engine.loadCalls, loads + 1);
      expect(player.isPlaying, isTrue);
      expect(find.text(l.retry), findsNothing);

      engine.failStream();
      await tester.pumpAndSettle();
      expect(problem(l.playbackStreamFailed), findsOneWidget);

      await player.resume();
      engine.seekError = failure;
      await player.seekTo(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(problem(l.playbackSeekFailed), findsOneWidget);

      engine.seekError = null;
      engine.focusAvailable = false;
      await player.resume();
      await tester.pumpAndSettle();
      expect(problem(l.playbackFocusUnavailable), findsOneWidget);

      await app.back();
      (app.services.sync as DemoSyncService).setOffline();
      engine.loadError = failure;
      await expectLater(player.play(failed.id), throwsStateError);
      await tester.pumpAndSettle();
      expect(problem(l.playbackOffline), findsOneWidget);
    } finally {
      await app.finish();
    }
  });
}

Future<void> _start(UiHarness app) async {
  await app.mini(app.strings.play);
  await app.mini(app.episode(101));
}

class _PositionLibrary extends DemoLibrary {
  final positions = <Duration>[];

  @override
  Future<void> recordPosition(
    int episodeId,
    Duration position, {
    Duration? duration,
  }) {
    positions.add(position);
    return super.recordPosition(episodeId, position, duration: duration);
  }
}
