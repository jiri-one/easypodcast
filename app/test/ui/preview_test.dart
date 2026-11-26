import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ui_test_support.dart';

const _out = String.fromEnvironment('PREVIEW_OUT');

void main() {
  if (_out.isEmpty) {
    testWidgets(
      'write previews when PREVIEW_OUT is set',
      (_) async {},
      skip: true,
    );
    return;
  }

  TestWidgetsFlutterBinding.ensureInitialized();
  late String family;
  setUpAll(() async {
    family = await loadTestFonts();
    await Directory(_out).create(recursive: true);
  });

  Future<void> write(UiHarness app, String name) async {
    await app.tester.pumpAndSettle();
    final surface =
        app.surface.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    await app.tester.runAsync(() async {
      final image = await surface.toImage();
      try {
        final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('$_out/$name.png').writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
      } finally {
        image.dispose();
      }
    });
    expect(app.tester.takeException(), isNull, reason: name);
  }

  testWidgets('phone PNGs at 392 × 785 with 180% text', (tester) async {
    final app = await UiHarness.open(
      tester,
      size: const Size(392, 785),
      locale: const Locale('cs'),
      loggedIn: false,
      playerCover: true,
    );
    try {
      await write(app, '16-login');
      await app.login();
      await app.services.player.setSpeed(1.2);
      await tester.pumpAndSettle();
      await tourPhone(app, (name) async {
        if (name != '16-login') await write(app, name);
      });
    } finally {
      await app.finish();
    }
  });

  testWidgets('Palma PNGs at 440 × 879 with 130% text', (tester) async {
    final app = await UiHarness.open(
      tester,
      size: palmaSize,
      locale: const Locale('cs'),
      textScale: palmaTextScale,
      playerCover: true,
    );
    try {
      await write(app, '28-palma-in-progress');
      await app.services.player.setSpeed(1.2);
      await app.mini(app.strings.play);
      await app.mini(app.episode(101));
      await write(app, '29-palma-player');
    } finally {
      await app.finish();
    }
  });

  testWidgets('Linux PNG at 1000 × 700 with 18 point GTK font', (tester) async {
    final app = await UiHarness.open(
      tester,
      size: const Size(1000, 700),
      locale: const Locale('cs'),
      desktopFont: family,
      playerCover: true,
    );
    try {
      await app.services.player.setSpeed(1.2);
      await tester.pumpAndSettle();
      await tourDesktop(app, (name) => write(app, name), allScreens: false);
    } finally {
      await app.finish();
    }
  });
}
