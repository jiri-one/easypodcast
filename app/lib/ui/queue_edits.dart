import 'package:flutter/foundation.dart';

import '../core/library.dart';
import '../core/models.dart';

class QueueEdits extends ChangeNotifier {
  QueueEdits(this.library);

  final Library library;
  List<Episode> Function(List<Episode>)? _project;
  bool _disposed = false;

  bool get saving => _project != null;

  List<Episode> get episodes {
    final queue = library.queue;
    return _project?.call(queue) ?? queue;
  }

  Future<void> setMembership(Episode episode, {required bool queued}) => _edit(
    (queue) => queued
        ? (queue.any((item) => item.id == episode.id)
              ? queue
              : [...queue, episode])
        : queue.where((item) => item.id != episode.id).toList(),
    () => queued ? library.enqueue(episode.id) : library.dequeue(episode.id),
  );

  Future<void> move(Episode episode, int index) => _edit((queue) {
    final from = queue.indexWhere((item) => item.id == episode.id);
    if (from < 0) return queue;
    final reordered = [...queue];
    final item = reordered.removeAt(from);
    reordered.insert(index.clamp(0, reordered.length), item);
    return reordered;
  }, () => library.moveInQueue(episode.id, index));

  Future<void> _edit(
    List<Episode> Function(List<Episode>) project,
    Future<void> Function() save,
  ) async {
    if (saving || _disposed) return;
    _project = project;
    notifyListeners();
    try {
      await save();
    } finally {
      _project = null;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
