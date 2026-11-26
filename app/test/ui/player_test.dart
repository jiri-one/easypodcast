import 'package:easypodcast/ui/demo/demo_library.dart';
import 'package:easypodcast/ui/eink_widgets.dart';
import 'package:easypodcast/ui/episode_page.dart';
import 'package:easypodcast/ui/episode_text.dart';
import 'package:easypodcast/ui/library_views.dart';
import 'package:easypodcast/ui/playback_position.dart';
import 'package:easypodcast/ui/player_views.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ui_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String font;
  setUpAll(() async => font = await loadTestFonts());

  testWidgets(
    'dragging previews a seek and releases it once, while a tap does nothing',
    (tester) async {
      final library = _PositionLibrary();
      final app = await UiHarness.open(
        tester,
        size: const Size(360, 720),
        locale: const Locale('cs'),
        library: library,
      );
      final player = app.services.player;
      final clock = find.byKey(PlaybackTimeline.previewKey);
      try {
        await _start(app);
        await player.pause();
        await tester.pumpAndSettle();
        library.positions.clear();

        final track = find.byKey(PlaybackTimeline.trackKey);
        final area = tester.getRect(track);
        final original = player.position.value;
        await tester.tapAt(area.centerLeft + const Offset(24, 0));
        await tester.pumpAndSettle();
        expect(player.position.value, original);
        expect(library.positions, isEmpty);

        final cancelled = await tester.startGesture(area.center);
        await cancelled.moveTo(area.centerLeft);
        await tester.pump();
        expect(tester.widget<Text>(clock).data, isNotEmpty);
        await cancelled.cancel();
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(clock).data, isEmpty);
        expect(library.positions, isEmpty);

        final drag = await tester.startGesture(area.center);
        await drag.moveTo(
          Offset(area.left + area.width * 0.30, area.center.dy),
        );
        await tester.pump();
        final first = tester.widget<Text>(clock).data;
        expect(first, isNotEmpty);
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
        expect(tester.widget<Text>(clock).data, isEmpty);
      } finally {
        await app.finish();
      }
    },
  );

  for (final seconds in [10, 60]) {
    testWidgets(
      'the $seconds-second phone refresh interval is saved and applied',
      (tester) async {
        final app = await UiHarness.open(
          tester,
          size: const Size(360, 720),
          locale: const Locale('cs'),
        );
        final l = app.strings;
        try {
          await app.section(LibrarySection.settings);
          final row = find.widgetWithText(EinkRow, l.playerRedraw);
          await tester.scrollUntilVisible(
            row,
            140,
            scrollable: find.descendant(
              of: find.byKey(const PageStorageKey('settings-list')),
              matching: find.byType(Scrollable),
            ),
          );
          final control = find.descendant(
            of: row,
            matching: find.byType(SegmentedButton<int>),
          );
          expect(tester.widget<SegmentedButton<int>>(control).selected, {1});
          await app.tap(
            find.descendant(
              of: control,
              matching: find.text(
                seconds == 60 ? l.minutes(1) : l.seconds(seconds),
              ),
            ),
          );
          final prefs = await SharedPreferences.getInstance();
          expect(prefs.getInt('playerRedrawSeconds'), seconds);
          await app.back();

          await _start(app);
          expect(find.text('32:00'), findsOneWidget);
          await tester.pump(Duration(seconds: seconds - 1));
          expect(find.text('32:00'), findsOneWidget);
          await tester.pump(const Duration(seconds: 2));
          final sampled =
              const Duration(minutes: 32) + Duration(seconds: seconds);
          expect(
            find.text(positionText(sampled, padMinutes: true)),
            findsOneWidget,
          );
        } finally {
          await app.finish();
        }
      },
    );
  }

  testWidgets('the mini player uses the library redraw interval', (
    tester,
  ) async {
    final app = await UiHarness.open(
      tester,
      size: const Size(392, 785),
      locale: const Locale('cs'),
    );
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
      locale: const Locale('cs'),
      playerCover: true,
    );
    try {
      await _start(app);
      final podcast = app.services.library.podcast(1)!;
      expect(find.widgetWithText(EinkHeader, podcast.title), findsOneWidget);
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
      locale: const Locale('cs'),
      desktopFont: font,
      playerCover: true,
    );
    try {
      await app.tap(
        find.descendant(
          of: find.byType(DesktopPlayer),
          matching: find.text(app.strings.play),
        ),
      );
      expect(tester.getSize(find.byType(ColorFiltered)), const Size.square(52));
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
