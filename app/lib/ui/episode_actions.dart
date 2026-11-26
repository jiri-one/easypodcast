import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../core/downloads.dart';
import '../core/library.dart';
import '../core/models.dart';
import 'eink_widgets.dart';
import 'episode_text.dart';
import 'playback_actions.dart';
import 'player_views.dart';
import 'theme.dart';

class EpisodeAction {
  const EpisodeAction(
    this.label,
    this.run, {
    this.primary = false,
    this.icon,
    this.alternatives = const [],
    this.progress,
    this.error = false,
  });

  final String label;
  final Future<void> Function(BuildContext) run;
  final bool primary;
  final IconData? icon;
  final List<String> alternatives;
  final int? progress;
  final bool error;

  EinkButton button(VoidCallback onPressed) => EinkButton(
    label,
    onPressed: onPressed,
    primary: primary,
    icon: icon,
    minHeight: primary ? 52 : 48,
    alternatives: alternatives,
    progress: progress,
    error: error,
  );
}

class EpisodeActions {
  const EpisodeActions({
    required this.episode,
    required this.playback,
    required this.downloadsAvailable,
    required this.wifiConnected,
    required this.onTrackDownload,
  });

  final Episode episode;
  final PlaybackActions playback;
  final bool downloadsAvailable;
  final ValueListenable<bool?> wifiConnected;
  final ValueChanged<int> onTrackDownload;

  Library get _library => playback.services.library;
  DownloadService get _downloads => playback.services.downloads;

  Widget watchDownload(
    BuildContext context,
    Widget Function(BuildContext, DownloadDisplay) builder,
  ) => downloadsAvailable
      ? DownloadStatusView(
          services: playback.services,
          wifiConnected: wifiConnected,
          episodeId: episode.id,
          builder: builder,
        )
      : builder(context, noDownload);

  List<EpisodeAction> options(BuildContext context, DownloadDisplay download) {
    final strings = context.strings;
    final id = episode.id;
    final state = _library.stateOf(id);
    final queued = _library.queue.any((item) => item.id == id);
    return [
      EpisodeAction(
        playLabel(context, playback, episode, showPosition: true),
        (_) => playback.toggle(episode),
        primary: true,
        icon: playback.playing(id) ? Icons.pause : Icons.play_arrow,
        alternatives: [
          strings.checkingPosition,
          strings.loadingPlayback,
          strings.playFrom(
            positionText(
              state.positionMs > 0
                  ? Duration(milliseconds: state.positionMs)
                  : const Duration(minutes: 59, seconds: 59),
            ),
          ),
        ],
      ),
      EpisodeAction(
        queued ? strings.removeFromQueue : strings.addToQueue,
        (_) => queued ? _library.dequeue(id) : _library.enqueue(id),
        alternatives: [strings.removeFromQueue, strings.addToQueue],
      ),
      if (downloadsAvailable &&
          (!state.isDismissed || download.status != DownloadStatus.none))
        _downloadAction(context, download),
      if (state.isDismissed || state.isPlayed)
        EpisodeAction(
          strings.markNew,
          (_) => _library.markNew(id),
          alternatives: [
            strings.markNew,
            state.isPlayed ? strings.markPlayed : strings.dismiss,
          ],
        )
      else ...[
        EpisodeAction(
          strings.markPlayed,
          (_) => _finish(() => _library.markPlayed(id)),
          alternatives: [strings.markNew, strings.markPlayed],
        ),
        EpisodeAction(
          strings.dismiss,
          _dismiss,
          alternatives: [strings.markNew, strings.dismiss],
        ),
      ],
      if (state.isNew && !queued && _dismissibleOlder().length > 1)
        EpisodeAction(strings.dismissOlder, _dismissOlder),
    ];
  }

  Future<void> showMenu(BuildContext context) async {
    final selected = await showEinkDialog<EpisodeAction>(
      context: context,
      barrierDismissible: false,
      builder: (context) => ListenableBuilder(
        listenable: Listenable.merge([
          _library,
          playback,
          playback.services.settings,
        ]),
        builder: (context, _) => watchDownload(
          context,
          (context, download) => EinkDialogPanel(
            title: episode.title,
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(context.strings.close, style: buttonLabelStyle),
              ),
            ],
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 6,
                children: [
                  for (final action in options(context, download))
                    action.button(() => Navigator.pop(context, action)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (selected != null && context.mounted) await selected.run(context);
  }

  EpisodeAction _downloadAction(
    BuildContext context,
    DownloadDisplay download,
  ) {
    final strings = context.strings;
    return EpisodeAction(
      switch (download.status) {
        DownloadStatus.done => strings.deleteFile,
        DownloadStatus.queued =>
          download.waitingForWifi
              ? strings.waitingForWifi
              : strings.waitingForDownload,
        DownloadStatus.running => strings.downloadProgress(download.percent),
        DownloadStatus.failed => strings.retryDownload,
        DownloadStatus.none => strings.download,
      },
      (context) async {
        final id = episode.id;
        switch (download.status) {
          case DownloadStatus.queued:
          case DownloadStatus.running:
            await _cancelDownload(context);
          case DownloadStatus.done:
            await _downloads.delete(id);
          case DownloadStatus.failed:
          case DownloadStatus.none:
            onTrackDownload(id);
            await _downloads.download(id);
        }
      },
      alternatives: [
        strings.download,
        strings.deleteFile,
        strings.waitingForWifi,
        strings.waitingForDownload,
        strings.downloadProgress(100),
        strings.retryDownload,
      ],
      progress: download.status == DownloadStatus.running
          ? download.percent
          : null,
      error: download.status == DownloadStatus.failed,
    );
  }

  Future<void> _cancelDownload(BuildContext context) async {
    final strings = context.strings;
    final cancel = await confirmAction(
      context,
      title: strings.cancelDownloadTitle,
      action: strings.cancelDownload,
    );
    if (!cancel || !context.mounted) return;
    final status = _downloads.statusOf(episode.id).status;
    if (status == DownloadStatus.queued || status == DownloadStatus.running) {
      await _downloads.delete(episode.id);
    }
  }

  Future<void> _finish(Future<void> Function() update) async {
    await update();
    final player = playback.services.player;
    final active = player.current?.id;
    if (active != null &&
        _library.stateOf(active).status != EpisodeStatus.none) {
      await player.stop();
    }
  }

  bool _hasFile(int id) =>
      _downloads.statusOf(id).status == DownloadStatus.done;

  Duration _currentPosition() {
    final player = playback.services.player;
    final stored = _library.stateOf(episode.id).positionMs;
    if (player.current?.id == episode.id &&
        player.position.value.inMilliseconds > stored) {
      return player.position.value;
    }
    return Duration(milliseconds: stored);
  }

  Future<void> _dismiss(BuildContext context) async {
    final strings = context.strings;
    final position = _currentPosition();
    final file = _hasFile(episode.id);
    if (position > Duration.zero || file) {
      final confirm = await confirmAction(
        context,
        title: strings.dismissTitle,
        message: position == Duration.zero
            ? strings.dismissFile
            : file
            ? strings.dismissPositionAndFile(positionText(position))
            : strings.dismissPosition(positionText(position)),
        action: strings.dismiss,
      );
      if (!confirm || !context.mounted) return;
    }
    await _finish(() => _library.dismiss(episode.id));
  }

  List<Episode> _dismissibleOlder() {
    final cutoff = episode.publishedAt;
    final queued = _library.queue.map((item) => item.id).toSet();
    return [
      for (final item in _library.episodesOf(episode.podcastId))
        if ((item.id == episode.id ||
                (cutoff != null &&
                    item.publishedAt?.isAfter(cutoff) == false)) &&
            _library.stateOf(item.id).isNew &&
            !queued.contains(item.id))
          item,
    ];
  }

  Future<void> _dismissOlder(BuildContext context) async {
    final candidates = _dismissibleOlder();
    if (!candidates.any((item) => item.id == episode.id) ||
        candidates.length < 2) {
      return;
    }
    final strings = context.strings;
    final count = candidates.length;
    final message = [
      strings.dismissOlderCount(count - 1),
      strings.dismissOlderKept,
      if (candidates.any((item) => _hasFile(item.id)))
        strings.dismissOlderDownloads,
    ].join(' ');
    final confirm = await confirmAction(
      context,
      title: strings.dismissCountTitle(count),
      message: message,
      action: strings.dismissCount(count),
    );
    if (confirm && context.mounted) {
      await _finish(() => _library.dismissOlder(episode.id));
    }
  }
}
