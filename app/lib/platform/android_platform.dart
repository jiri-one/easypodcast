import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'command_queue.dart';

const androidPlatform = MethodChannel('one.jiri.easypodcast/platform');

ValueListenable<bool> watchCarConnection() {
  final connected = ValueNotifier(false);
  Future<void> check() async {
    connected.value =
        await androidPlatform.invokeMethod<bool>('carConnected') ?? false;
  }

  androidPlatform.setMethodCallHandler((call) async {
    if (call.method == 'carConnectionChanged') await check();
  });
  background(check());
  return connected;
}
