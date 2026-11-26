import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/library.dart';
import '../core/models.dart';
import 'eink_widgets.dart';
import 'episode_actions.dart';
import 'episode_text.dart';
import 'plain_links.dart';
import 'playback_actions.dart';
import 'player_views.dart';
import 'queue_edits.dart';
import 'theme.dart';

class EpisodePage extends StatefulWidget {
  const EpisodePage({
    super.key,
    required this.episode,
    required this.playback,
    required this.queueEdits,
    required this.downloadsAvailable,
    required this.desktopPanel,
    required this.onTrackDownload,
  });

  final Episode episode;
  final PlaybackActions playback;
  final QueueEdits queueEdits;
  final bool downloadsAvailable;
  final bool desktopPanel;
  final ValueChanged<int> onTrackDownload;

  @override
  State<EpisodePage> createState() => _EpisodePageState();
}

class _EpisodePageState extends State<EpisodePage> {
  late Future<String> _description;
  bool _changing = false;
  Timer? _tapGuard;
  String? _error;

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
      _error = null;
      _tapGuard?.cancel();
    }
  }

  @override
  void dispose() {
    _tapGuard?.cancel();
    super.dispose();
  }

  Future<void> _change(Future<void> Function() action) async {
    if (_changing || _tapGuard?.isActive == true) return;
    setState(() {
      _changing = true;
      _error = null;
    });
    try {
      await action();
    } on BulkDismissNeedsConnection {
      if (mounted) _error = context.strings.dismissOlderOffline;
    } on Object {
      if (mounted) _error = context.strings.actionFailed;
    } finally {
      if (mounted) {
        _tapGuard = Timer(
          const Duration(milliseconds: 600),
          () => _tapGuard = null,
        );
        setState(() => _changing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final actions = EpisodeActions(
      episode: _episode,
      playback: widget.playback,
      queueEdits: widget.queueEdits,
      downloadsAvailable: widget.downloadsAvailable,
      onTrackDownload: widget.onTrackDownload,
    );
    return actions.watchDownload(
      context,
      (context, download) => _body(
        context,
        actions.options(context, download, reserveStateSlots: true),
      ),
    );
  }

  Widget _body(BuildContext context, List<EpisodeAction> actions) {
    final strings = context.strings;
    final episode = _episode;
    final id = episode.id;
    final playback = widget.playback;
    final state = _library.stateOf(id);
    final podcast = _library.podcast(episode.podcastId);
    final playing = playback.playing(id);
    final length = episodeDuration(episode, state);
    final position = Duration(milliseconds: state.positionMs);
    final meta = [
      if (episode.publishedAt case final DateTime time)
        strings.published(dateText(strings, time)),
      if (length != null) minuteLength(strings, length),
    ];
    final newSubtitle = [
      strings.stateNew,
      if (length != null) minuteLength(strings, length),
    ].join(metadataSeparator);
    final subtitle = switch ((playing, state.status, state.isInProgress)) {
      (true, _, _) => strings.statePlaying,
      (_, EpisodeStatus.played, _) => strings.statePlayed,
      (_, EpisodeStatus.dismissed, _) => strings.stateDismissed,
      (_, _, true) => playbackTime(strings, position, length, showTotal: true),
      _ => newSubtitle,
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
              Stack(
                children: [
                  if (length != null)
                    Opacity(
                      opacity: 0,
                      child: Text(
                        playbackTime(
                          strings,
                          Duration.zero,
                          length,
                          showTotal: true,
                        ),
                        style: detailStyle,
                      ),
                    ),
                  Text(
                    subtitle,
                    style: detailStyle.copyWith(
                      fontWeight: playing ? FontWeight.w700 : null,
                    ),
                  ),
                ],
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
                  for (final action in actions)
                    action.button(
                      () => unawaited(_change(() => action.run(this.context))),
                    ),
                ],
              ),
            ),
          ),
        ),
        if (_error case final String error) ProblemBox(error),
        PlaybackProblem(playback: playback, episodeId: id),
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
