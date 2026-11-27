import 'package:easypodcast/platform/android_platform.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the car connection asks again after each native change', (
    tester,
  ) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    var connected = true;
    var queries = 0;
    messenger.setMockMethodCallHandler(androidPlatform, (call) async {
      expect(call.method, 'carConnected');
      queries++;
      return connected;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(androidPlatform, null);
      androidPlatform.setMethodCallHandler(null);
    });

    final car = watchCarConnection();
    await tester.pump();
    expect(car.value, isTrue);

    connected = false;
    await messenger.handlePlatformMessage(
      androidPlatform.name,
      androidPlatform.codec.encodeMethodCall(
        const MethodCall('carConnectionChanged'),
      ),
      (_) {},
    );
    await tester.pump();
    expect(car.value, isFalse);
    expect(queries, 2);
  });
}
