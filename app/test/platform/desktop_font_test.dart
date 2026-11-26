import 'package:easypodcast/platform/desktop_font.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('easypodcast/desktop');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.linux);
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('reads a multi-word family and fractional point size', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getDesktopFont');
      return {'family': 'Liberation Sans', 'pointSize': 13.5};
    });
    final font = await desktopFont();
    expect(font?.family, 'Liberation Sans');
    expect(font?.pointSize, 13.5);
  });

  test('18 GTK points give a 24 logical pixel body at any monitor scale', () {
    const font = DesktopFont('Liberation Sans', 18);
    expect(font.textScale * 14, closeTo(24, 1e-10));
    expect(const DesktopFont('Sans', 10.5).textScale, 1);
  });

  test('selects the primary family from a GTK fallback list', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      return {'family': 'Noto Sans, DejaVu Sans', 'pointSize': 12};
    });
    expect((await desktopFont())?.family, 'Noto Sans');
  });

  test(
    'missing or malformed font settings fall back to the app font',
    () async {
      for (final value in [
        null,
        'Liberation Sans',
        {'family': '   ', 'pointSize': 18},
        {'family': 'Sans'},
        {'pointSize': 12},
        {'family': 'Sans', 'pointSize': 'large'},
        {'family': 'Sans', 'pointSize': 0},
        {'family': 'Sans', 'pointSize': -1},
        {'family': 'Sans', 'pointSize': double.infinity},
        {'family': 'Sans', 'pointSize': double.nan},
      ]) {
        messenger.setMockMethodCallHandler(channel, (_) async => value);
        expect(await desktopFont(), isNull);
      }
    },
  );

  test('an unavailable channel or failed native call returns null', () async {
    expect(await desktopFont(), isNull);
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'unavailable');
    });
    expect(await desktopFont(), isNull);
  });

  test('other platforms never invoke the Linux channel', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => fail('Linux channel called'),
    );
    expect(await desktopFont(), isNull);
  });
}
