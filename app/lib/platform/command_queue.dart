import 'dart:async';

import 'package:flutter/foundation.dart';

class CommandQueue {
  Future<void> _tail = Future.value();
  bool _closed = false;

  bool get isClosed => _closed;

  Future<void> run(Future<void> Function() command) {
    final result = _tail.then((_) async {
      if (!_closed) await command();
    });
    _tail = result.catchError((Object _, StackTrace _) {});
    return result;
  }

  Future<void> close() {
    _closed = true;
    return _tail;
  }
}

void background(Future<void> work) => unawaited(
  work.catchError(
    (Object error, StackTrace stack) => FlutterError.reportError(
      FlutterErrorDetails(exception: error, stack: stack),
    ),
  ),
);
