import 'package:material_ui/material_ui.dart';

import '../core/downloads.dart';
import '../core/library.dart';
import '../core/models.dart';
import 'eink_widgets.dart';
import 'episode_text.dart';
import 'plain_links.dart';
import 'playback_actions.dart';
import 'player_views.dart';
import 'theme.dart';

class EpisodePage extends StatefulWidget {
  const EpisodePage({
    super.key,
    required this.episode,
    required this.playback,
    required this.downloadsAvailable,
    required this.desktopPanel,
    required this.onTrackDownload,
  });

  final Episode episode;
  final PlaybackActions playback;
  final bool downloadsAvailable;
  final bool desktopPanel;
  final ValueChanged<int> onTrackDownload;

  @override
  State<EpisodePage> createState() => _EpisodePageState();
}

class _EpisodePageState extends State<EpisodePage> {
  late Future<String> _description;
  bool _changing = false;
  bool _failed = false;

  Episode get _episode => widget.episode;
  Library get _library => widget.playback.services.library;

  @override
  void initState() {
    super.initState();
    _description = _library.description(_episode.id);
  }

  @override
  void didUpdateWidget(EpisodePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.episode.id != _episode.id ||
        oldWidget.playback.services.library != _library) {
      _description = _library.description(_episode.id);
      _failed = false;
    }
  }

  Future<void> _change(Future<void> Function() action) async {
    if (_changing) return;
    setState(() {
      _changing = true;
      _failed = false;
    });
    try {
      await action();
    } on Exception {
      if (mounted) _failed = true;
    } finally {
      if (mounted) setState(() => _changing = false);
    }
  }

  Future<void> _finish(Future<void> Function() update) async {
    await update();
    final player = widget.playback.services.player;
    final active = player.current?.id;
    if (active != null &&
        _library.stateOf(active).status != EpisodeStatus.none) {
      await player.stop();
    }
  }

  bool _hasFile(int id) =>
      widget.playback.services.downloads.statusOf(id).status ==
      DownloadStatus.done;

  Duration _currentPosition() {
    final player = widget.playback.services.player;
    final stored = _library.stateOf(_episode.id).positionMs;
    if (player.current?.id == _episode.id &&
        player.position.value.inMilliseconds > stored) {
      return player.position.value;
    }
    return Duration(milliseconds: stored);
  }

  Future<void> _dismiss() async {
    final strings = context.strings;
    final position = _currentPosition();
    final file = _hasFile(_episode.id);
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
      if (!confirm || !mounted) return;
    }
    await _finish(() => _library.dismiss(_episode.id));
  }

  List<Episode> _dismissibleOlder() {
    final cutoff = _episode.publishedAt;
    final queued = _library.queue.map((episode) => episode.id).toSet();
    return [
      for (final episode in _library.episodesOf(_episode.podcastId))
        if ((episode.id == _episode.id ||
                (cutoff != null &&
                    episode.publishedAt?.isAfter(cutoff) == false)) &&
            _library.stateOf(episode.id).isNew &&
            !queued.contains(episode.id))
          episode,
    ];
  }

  Future<void> _dismissOlder() async {
    final candidates = _dismissibleOlder();
    if (!candidates.any((episode) => episode.id == _episode.id) ||
        candidates.length < 2) {
      return;
    }
    final strings = context.strings;
    final count = candidates.length;
    final message = [
      strings.dismissOlderCount(count - 1),
      strings.dismissOlderKept,
      if (candidates.any((episode) => _hasFile(episode.id)))
        strings.dismissOlderDownloads,
    ].join(' ');
    final confirm = await confirmAction(
      context,
      title: strings.dismissCountTitle(count),
      message: message,
      action: strings.dismissCount(count),
    );
    if (confirm && mounted) {
      await _finish(() => _library.dismissOlder(_episode.id));
    }
  }

  Widget _downloadButton(BuildContext context, DownloadStatus status) {
    final strings = context.strings;
    final downloads = widget.playback.services.downloads;
    final id = _episode.id;
    final delete =
        status == DownloadStatus.queued ||
        status == DownloadStatus.running ||
        status == DownloadStatus.done;
    return EinkButton(
      switch (status) {
        DownloadStatus.done => strings.deleteFile,
        DownloadStatus.queued ||
        DownloadStatus.running => strings.cancelDownload,
        DownloadStatus.failed => strings.retryDownload,
        DownloadStatus.none => strings.download,
      },
      onPressed: () => _change(() async {
        if (delete) {
          await downloads.delete(id);
        } else {
          widget.onTrackDownload(id);
          await downloads.download(id);
        }
      }),
      alternatives: [
        strings.download,
        strings.deleteFile,
        strings.cancelDownload,
        strings.retryDownload,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final downloads = widget.playback.services.downloads;
    if (!widget.downloadsAvailable) return _body(context, DownloadStatus.none);
    return DownloadStatusView(
      downloads: downloads,
      episodeId: _episode.id,
      builder: _body,
    );
  }

  Widget _body(BuildContext context, DownloadStatus download) {
    final strings = context.strings;
    final episode = _episode;
    final id = episode.id;
    final playback = widget.playback;
    final state = _library.stateOf(id);
    final podcast = _library.podcast(episode.podcastId);
    final queued = _library.queue.any((episode) => episode.id == id);
    final playing = playback.playing(id);
    final length = episodeDuration(episode, state);
    final position = Duration(milliseconds: state.positionMs);
    final meta = [
      if (episode.publishedAt case final DateTime time)
        strings.published(dateText(strings, time)),
      if (length != null) strings.minutes(durationMinutes(length)),
    ];
    final subtitle = switch ((playing, state.status, state.isInProgress)) {
      (true, _, _) => strings.statePlaying,
      (_, EpisodeStatus.played, _) => strings.statePlayed,
      (_, EpisodeStatus.dismissed, _) => strings.stateDismissed,
      (_, _, true) => playbackTime(strings, position, length, showTotal: true),
      _ => [
        strings.stateNew,
        if (length != null) strings.minutes(durationMinutes(length)),
      ].join(metadataSeparator),
    };

    return PageList(
      key: PageStorageKey(('episode', id)),
      inset: true,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: widget.desktopPanel ? 12 : 0,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 4,
            children: [
              if (widget.desktopPanel && podcast != null)
                Text(podcast.title, style: detailStyle),
              Semantics(
                header: true,
                child: Text(episode.title, style: headingStyle),
              ),
              Text(
                subtitle,
                style: detailStyle.copyWith(
                  fontWeight: playing ? FontWeight.w700 : null,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: widget.desktopPanel ? 12 : 0,
          ),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: widget.desktopPanel ? 360 : double.infinity,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 6,
                children: [
                  EinkButton(
                    playLabel(context, playback, episode, showPosition: true),
                    primary: true,
                    icon: playing ? Icons.pause : Icons.play_arrow,
                    minHeight: 52,
                    alternatives: [
                      strings.checkingPosition,
                      strings.loadingPlayback,
                      strings.playFrom(
                        positionText(
                          position > Duration.zero
                              ? position
                              : const Duration(minutes: 59, seconds: 59),
                        ),
                      ),
                    ],
                    onPressed: () {
                      if (!_changing) playback.toggle(episode);
                    },
                  ),
                  EinkButton(
                    queued ? strings.removeFromQueue : strings.addToQueue,
                    alternatives: [strings.removeFromQueue, strings.addToQueue],
                    onPressed: () => _change(
                      () =>
                          queued ? _library.dequeue(id) : _library.enqueue(id),
                    ),
                  ),
                  if (widget.downloadsAvailable &&
                      (!state.isDismissed || download != DownloadStatus.none))
                    _downloadButton(context, download),
                  if (!state.isDismissed)
                    EinkButton(
                      state.isPlayed ? strings.markNew : strings.markPlayed,
                      alternatives: [strings.markNew, strings.markPlayed],
                      onPressed: () => _change(
                        () => state.isPlayed
                            ? _library.markNew(id)
                            : _finish(() => _library.markPlayed(id)),
                      ),
                    ),
                  if (!state.isPlayed)
                    EinkButton(
                      state.isDismissed ? strings.markNew : strings.dismiss,
                      alternatives: [strings.markNew, strings.dismiss],
                      onPressed: () => _change(
                        () => state.isDismissed
                            ? _library.markNew(id)
                            : _dismiss(),
                      ),
                    ),
                  if (state.isNew && !queued && _dismissibleOlder().length > 1)
                    EinkButton(
                      strings.dismissOlder,
                      onPressed: () => _change(_dismissOlder),
                    ),
                ],
              ),
            ),
          ),
        ),
        if (_failed) ProblemBox(strings.actionFailed),
        if (playback.failedEpisodeId == id) ProblemBox(strings.playbackFailed),
        if (download == DownloadStatus.failed)
          ProblemBox(strings.stateDownloadFailed),
        Padding(
          padding: EdgeInsets.fromLTRB(
            widget.desktopPanel ? 12 : 0,
            12,
            widget.desktopPanel ? 12 : 0,
            0,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 8,
            children: [
              if (meta.isNotEmpty)
                Text(meta.join(metadataSeparator), style: detailStyle),
              FutureBuilder<String>(
                future: _description,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        EinkError(strings.descriptionFailed),
                        TextButton(
                          onPressed: () => setState(() {
                            _description = _library.description(id);
                          }),
                          child: Text(strings.retry, style: buttonLabelStyle),
                        ),
                      ],
                    );
                  }
                  final text = snapshot.data;
                  return text == null || text.isEmpty
                      ? const SizedBox.shrink()
                      : PlainLinks(text);
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}
