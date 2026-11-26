import 'dart:async';
import 'dart:ui' show SemanticsAction;

import 'package:easypodcast/ui/demo/demo_library.dart';
import 'package:easypodcast/ui/eink_widgets.dart';
import 'package:easypodcast/ui/episode_queue.dart';
import 'package:easypodcast/ui/library_views.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String font;
  setUpAll(() async => font = await loadTestFonts());

  for (final (description, from, to) in [
    ('first', 2, 0),
    ('middle', 0, 1),
    ('last', 0, 2),
    ('below the list', 0, null),
  ]) {
    testWidgets('hold and drag to $description saves one final index', (
      tester,
    ) async {
      final library = _RecordingLibrary();
      final app = await _openQueue(tester, library);
      final before = _ids(library);
      final id = before[from];
      final target = to ?? before.length - 1;
      try {
        final destination = to == null
            ? tester.getBottomLeft(find.byType(EpisodeQueue)) +
                  const Offset(40, 12)
            : tester.getCenter(_row(app, before[to], to));
        final drag = await _hold(tester, _row(app, id, from));
        await drag.moveTo(destination);
        await tester.pump();

        expect(_row(app, id, target), findsOneWidget);
        expect(_ids(library), before);
        expect(library.moves, isEmpty);

        await drag.up();
        await tester.pumpAndSettle();

        final expected = [...before];
        expected.insert(target, expected.removeAt(from));
        expect(_ids(library), expected);
        expect(library.moves, [(id, target)]);
        expect(find.byType(EinkDialogPanel), findsNothing);
      } finally {
        await app.finish();
      }
    });
  }

  testWidgets('holding a queue row opens actions on release without a move', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final library = _RecordingLibrary();
    final app = await _openQueue(tester, library);
    try {
      final row = _row(app, 203, 0);
      expect(
        tester
            .getSemantics(row)
            .getSemanticsData()
            .hasAction(SemanticsAction.longPress),
        isTrue,
      );
      final hold = await _hold(tester, row);
      expect(tester.widget<EinkRow>(row).lifted, isTrue);
      await hold.moveBy(const Offset(3, 2));
      await tester.pump();
      expect(find.byType(EinkDialogPanel), findsNothing);

      await hold.up();
      await tester.pumpAndSettle();
      final dialog = find.byType(EinkDialogPanel);
      expect(
        find.descendant(
          of: dialog,
          matching: find.text(app.strings.removeFromQueue),
        ),
        findsOneWidget,
      );
      expect(library.moves, isEmpty);
      expect(_ids(library), [203, 401, 602]);
      await app.dialog(app.strings.removeFromQueue);
      expect(_ids(library), [401, 602]);
      expect(find.byType(EinkDialogPanel), findsNothing);
    } finally {
      semantics.dispose();
      await app.finish();
    }
  });

  testWidgets('a move keeps the preview during the library refresh', (
    tester,
  ) async {
    final gate = Completer<void>();
    final library = _RecordingLibrary()..beforeMove = gate.future;
    final app = await _openQueue(tester, library);
    try {
      final destination = tester.getCenter(_row(app, 602, 2));
      final drag = await _hold(tester, _row(app, 203, 0));
      await drag.moveTo(destination);
      await tester.pump();
      final preview = tester.getRect(_row(app, 203, 2));
      await drag.up();
      await tester.pump();

      expect(tester.getRect(_row(app, 203, 2)), preview);
      expect(_ids(library), [203, 401, 602]);
      expect(library.moves, [(203, 2)]);

      gate.complete();
      await tester.pumpAndSettle();
      expect(tester.getRect(_row(app, 203, 2)), preview);
      expect(_ids(library), [401, 602, 203]);
    } finally {
      if (!gate.isCompleted) gate.complete();
      await app.finish();
    }
  });

  testWidgets('dragging away and back closes the preview without a write', (
    tester,
  ) async {
    final library = _RecordingLibrary();
    final app = await _openQueue(tester, library);
    try {
      final row = _row(app, 203, 0);
      final origin = tester.getCenter(row);
      final destination = tester.getCenter(_row(app, 602, 2));
      final drag = await _hold(tester, row);
      await drag.moveTo(destination);
      await tester.pump();
      expect(_row(app, 203, 2), findsOneWidget);

      await drag.moveTo(origin);
      await drag.up();
      await tester.pumpAndSettle();
      expect(row, findsOneWidget);
      expect(library.moves, isEmpty);
      expect(find.byType(EinkDialogPanel), findsNothing);
    } finally {
      await app.finish();
    }
  });

  testWidgets('a queue change during the drag cancels the preview', (
    tester,
  ) async {
    final library = _RecordingLibrary();
    final app = await _openQueue(tester, library);
    try {
      final destination = tester.getCenter(_row(app, 602, 2));
      final drag = await _hold(tester, _row(app, 203, 0));
      await drag.moveTo(destination);
      await tester.pump();
      await library.dequeue(401);
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();

      expect(_ids(library), [203, 602]);
      expect(library.moves, isEmpty);
      expect(find.byType(EinkDialogPanel), findsNothing);
    } finally {
      await app.finish();
    }
  });

  testWidgets('the bottom edge scrolls to a destination outside the view', (
    tester,
  ) async {
    final library = _RecordingLibrary();
    for (final episode in library.episodesOf(1).skip(11).take(8)) {
      await library.enqueue(episode.id);
    }
    final app = await _openQueue(tester, library);
    try {
      final list = find.byType(EpisodeQueue);
      final viewport = tester.getRect(list);
      final scroll = tester
          .state<ScrollableState>(
            find.descendant(of: list, matching: find.byType(Scrollable)),
          )
          .position;
      final last = library.queue.length - 1;
      expect(
        _row(app, library.queue.last.id, last).hitTestable(),
        findsNothing,
      );
      final drag = await _hold(tester, _row(app, 203, 0));
      await drag.moveTo(Offset(viewport.center.dx, viewport.bottom - 3));
      for (var step = 0; step < 25 && scroll.extentAfter > 0; step++) {
        await tester.pump(const Duration(milliseconds: 160));
        await tester.pump();
      }
      expect(scroll.extentAfter, 0);
      expect(_row(app, 203, last).hitTestable(), findsOneWidget);
      expect(library.moves, isEmpty);

      await drag.up();
      await tester.pumpAndSettle();
      expect(library.moves, [(203, last)]);
      expect(library.queue.last.id, 203);
    } finally {
      await app.finish();
    }
  });

  testWidgets('Linux supports a mouse drag, a mouse hold, and a right click', (
    tester,
  ) async {
    final library = _RecordingLibrary();
    final app = await _openQueue(tester, library, desktopFont: font);
    try {
      final drag = await tester.startGesture(
        tester.getCenter(_row(app, 203, 0)),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveTo(tester.getCenter(_row(app, 401, 1)));
      await drag.up();
      await tester.pumpAndSettle();
      expect(library.moves, [(203, 1)]);

      final title = app.strings.numberedTitle(2, app.episode(203));
      for (final rightClick in [false, true]) {
        await app.holdRow(title, rightClick: rightClick);
        expect(find.byType(EinkDialogPanel), findsOneWidget);
        await app.dialog(app.strings.close);
      }
      expect(library.moves, [(203, 1)]);
    } finally {
      await app.finish();
    }
  });
}

Future<UiHarness> _openQueue(
  WidgetTester tester,
  DemoLibrary library, {
  String? desktopFont,
}) async {
  final app = await UiHarness.open(
    tester,
    size: desktopFont == null ? const Size(360, 720) : const Size(1000, 700),
    locale: const Locale('cs'),
    library: library,
    desktopFont: desktopFont,
  );
  await app.section(LibrarySection.queue);
  return app;
}

Finder _row(UiHarness app, int id, int index) => find.widgetWithText(
  EinkRow,
  app.strings.numberedTitle(index + 1, app.episode(id)),
);

List<int> _ids(DemoLibrary library) => [
  for (final episode in library.queue) episode.id,
];

Future<TestGesture> _hold(WidgetTester tester, Finder row) async {
  final gesture = await tester.startGesture(tester.getCenter(row));
  await tester.pump(kLongPressTimeout);
  return gesture;
}

class _RecordingLibrary extends DemoLibrary {
  final moves = <(int, int)>[];
  Future<void>? beforeMove;

  @override
  Future<void> moveInQueue(int episodeId, int newIndex) async {
    moves.add((episodeId, newIndex));
    await beforeMove;
    await super.moveInQueue(episodeId, newIndex);
  }
}
