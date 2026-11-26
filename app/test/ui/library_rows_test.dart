import 'dart:async';
import 'dart:ui' as ui;

import 'package:easypodcast/ui/cover_image.dart';
import 'package:easypodcast/ui/eink_widgets.dart';
import 'package:easypodcast/ui/library_views.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'fixtures/demo_library.dart';
import 'ui_test_support.dart';

void main() {
  testWidgets('a decorative clock precedes only the remaining time', (
    tester,
  ) async {
    final app = await UiHarness.open(tester);
    final strings = app.strings;
    final library = app.services.library;
    Finder clock(int id) =>
        _inRow(app.episode(id), find.byIcon(Icons.schedule));
    Finder status(int id, String label) =>
        _inRow(app.episode(id), find.textContaining(label));
    try {
      final remaining = status(101, strings.remaining(strings.minutes(23)));
      final icon = tester.widget<Icon>(clock(101));
      expect(icon.size, 16);
      expect(icon.color, Colors.black);
      expect(icon.semanticLabel, isNull);
      expect(
        tester.getRect(clock(101)).right,
        lessThan(tester.getRect(remaining).left),
      );

      await app.services.player.play(101);
      await tester.pumpAndSettle();
      expect(status(101, strings.statePlaying), findsOneWidget);
      expect(clock(101), findsNothing);

      await library.recordPosition(204, const Duration(minutes: 70));
      await tester.pumpAndSettle();
      expect(
        status(204, strings.elapsed(strings.hoursMinutes(1, 10))),
        findsOneWidget,
      );
      expect(clock(204), findsNothing);

      await app.section(LibrarySection.podcasts);
      await app.scrollToRow(
        library.podcast(1)!.title,
        find.byType(PodcastList),
      );
      for (final (id, label) in [
        (102, strings.stateNew),
        (107, strings.statePlayed),
      ]) {
        await app.scrollTo(
          find.widgetWithText(EinkRow, app.episode(id)),
          find.byType(EpisodeList),
        );
        expect(status(id, label), findsOneWidget);
        expect(clock(id), findsNothing);
      }
    } finally {
      await app.finish();
    }
  });

  testWidgets('list thumbnails show in the library lists', (tester) async {
    final app = await UiHarness.open(tester, playerCover: true);
    final podcast = app.services.library.podcast(1)!;
    final title = app.episode(101);
    try {
      final artwork = _inRow(title, find.byType(RawImage));
      final name = _inRow(title, find.text(podcast.title));
      expect(tester.widget<RawImage>(artwork).image, isNotNull);
      expect(tester.getSize(artwork).aspectRatio, 1);
      expect(
        tester.getCenter(artwork).dy,
        moreOrLessEquals(tester.getCenter(name).dy, epsilon: 1),
      );
      expect(
        tester.getTopLeft(name).dx,
        greaterThan(tester.getTopRight(artwork).dx),
      );
      final episodeTitle = _inRow(title, find.text(title));
      expect(
        tester.getTopLeft(episodeTitle).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(artwork).dy),
      );
      expect(
        tester.getTopLeft(episodeTitle).dx,
        lessThan(tester.getTopLeft(artwork).dx + 1),
      );

      await app.section(LibrarySection.podcasts);
      final podcastRow = find.widgetWithText(EinkRow, podcast.title);
      await app.scrollTo(podcastRow, find.byType(PodcastList));
      expect(
        tester
            .widget<RawImage>(_inRow(podcast.title, find.byType(RawImage)))
            .image,
        isNotNull,
      );

      await app.tap(podcastRow);
      expect(_inRow(title, find.byType(Image)), findsNothing);
      expect(
        tester.widget<EinkRow>(find.widgetWithText(EinkRow, title)).leading,
        isNull,
      );
    } finally {
      await app.finish();
    }
  });

  testWidgets('the row text stays in place while its cover loads', (
    tester,
  ) async {
    const url = 'https://podcast.example/loading.png';
    final frame = Completer<ImageInfo>();
    final thumbnail = const CoverImage(url).resized(44, 1);
    final key = await thumbnail.obtainKey(ImageConfiguration.empty);
    final cache = PaintingBinding.instance.imageCache;
    cache.putIfAbsent(key, () => OneFrameImageStreamCompleter(frame.future));
    addTearDown(() => cache.evict(key));

    final app = await UiHarness.open(
      tester,
      library: DemoLibrary(firstPodcastCover: url),
    );
    final podcast = app.services.library.podcast(1)!.title;
    final name = _inRow(app.episode(101), find.text(podcast));
    final cover = _inRow(app.episode(101), find.byType(RawImage));
    try {
      final left = tester.getTopLeft(name).dx;
      expect(tester.widget<RawImage>(cover).image, isNull);

      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.black, BlendMode.src);
      final picture = recorder.endRecording();
      frame.complete(ImageInfo(image: picture.toImageSync(52, 52)));
      picture.dispose();

      await tester.pumpAndSettle();
      expect(tester.widget<RawImage>(cover).image, isNotNull);
      expect(tester.getTopLeft(name).dx, left);
    } finally {
      await app.finish();
    }
  });
}

Finder _inRow(String title, Finder matching) => find.descendant(
  of: find.widgetWithText(EinkRow, title),
  matching: matching,
);
