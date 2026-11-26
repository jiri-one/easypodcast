import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../core/library.dart';
import '../core/sync.dart';
import 'eink_widgets.dart';

class SyncFeedback extends ChangeNotifier {
  SyncFeedback(this._source) {
    _source.addListener(_changed);
  }

  final ValueListenable<SyncStatus> _source;

  SyncStatus get status => _source.value;
  bool get offline => status.phase == SyncPhase.offline;

  void _changed() {
    notifyListeners();
  }

  String? problem(BuildContext context) => switch (status.phase) {
    SyncPhase.offline => context.strings.offline,
    SyncPhase.error => context.strings.syncError,
    _ => null,
  };

  bool loadingLibrary(Library library) =>
      status.syncing &&
      status.lastSuccess == null &&
      status.phase != SyncPhase.offline &&
      status.phase != SyncPhase.error &&
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
