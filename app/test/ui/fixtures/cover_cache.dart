import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

Future<Directory> coverCache(TestWidgetsFlutterBinding binding) async {
  final parent = Directory(path.join(Directory.current.parent.path, '.ai'));
  await parent.create(recursive: true);
  final root = await parent.createTemp('cover-test-');
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  final messenger = binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async {
    expect(call.method, 'getApplicationCacheDirectory');
    return root.path;
  });
  addTearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await root.delete(recursive: true);
  });
  return Directory(path.join(root.path, 'podcast-covers')).create();
}
