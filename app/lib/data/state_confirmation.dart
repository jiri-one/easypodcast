import '../core/api.dart';
import '../core/models.dart';

extension StateConfirmation on StatePushResult {
  void requireConfirmation(List<EpisodeState> sent, QueueState? sentQueue) {
    final stored = {
      for (final state in episodes)
        state.episodeId: state.updatedAt.millisecondsSinceEpoch,
    };
    final unknownIds = unknown.toSet();
    for (final state in sent) {
      final confirmed = stored[state.episodeId];
      if (!unknownIds.contains(state.episodeId) &&
          (confirmed == null ||
              confirmed < state.updatedAt.millisecondsSinceEpoch)) {
        throw FormatException(
          'Missing state confirmation for episode ${state.episodeId}',
        );
      }
    }
    final storedQueue = queue;
    if (sentQueue != null &&
        (storedQueue == null ||
            storedQueue.updatedAt.millisecondsSinceEpoch <
                sentQueue.updatedAt.millisecondsSinceEpoch)) {
      throw const FormatException('Missing queue confirmation');
    }
  }
}
