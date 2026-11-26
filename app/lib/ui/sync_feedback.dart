import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../core/library.dart';
import '../core/sync.dart';
import 'eink_widgets.dart';

class SyncFeedback extends ChangeNotifier {
  SyncFeedback(this._source) : _lastPhase = _source.value.phase {
    _source.addListener(_changed);
  }

  final ValueListenable<SyncStatus> _source;
  SyncPhase _lastPhase;

  SyncStatus get status => _source.value;
  bool get offline => _lastPhase == SyncPhase.offline;

  void _changed() {
    if (status.phase != SyncPhase.syncing) _lastPhase = status.phase;
    notifyListeners();
  }

  String? problem(BuildContext context) => switch (_lastPhase) {
    SyncPhase.offline => context.strings.offline,
    SyncPhase.error => context.strings.syncError,
    _ => null,
  };

  bool loadingLibrary(Library library) =>
      status.phase == SyncPhase.syncing &&
      status.lastSuccess == null &&
      _lastPhase != SyncPhase.offline &&
      _lastPhase != SyncPhase.error &&
      library.podcasts.isEmpty;

  @override
  void dispose() {
    _source.removeListener(_changed);
    super.dispose();
  }

  static SyncFeedback of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<SyncFeedbackScope>()!
      .notifier!;
}

class SyncFeedbackScope extends InheritedNotifier<SyncFeedback> {
  const SyncFeedbackScope({
    super.key,
    required super.notifier,
    required super.child,
  });
}
