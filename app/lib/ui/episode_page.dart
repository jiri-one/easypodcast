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
import 'theme.dart';

class EpisodePage extends StatefulWidget {
  const EpisodePage({
    super.key,
    required this.episode,
    required this.playback,
    required this.desktopPanel,
  });

  final Episode episode;
  final PlaybackActions playback;
  final bool desktopPanel;

  @override
  State<EpisodePage> createState() => _EpisodePageState();
}

class _EpisodePageState extends State<EpisodePage> with ActionTapGuard {
  (int, String?)? _descriptionSource;
  Future<String>? _description;
  String? _error;

  Episode get _episode => widget.episode;
  Library get _library => widget.playback.services.library;

  @override
  void initState() {
    super.initState();
    _onLibraryChanged();
    _library.addListener(_onLibraryChanged);
  }

  @override
  void dispose() {
    _library.removeListener(_onLibraryChanged);
    super.dispose();
  }

  void _onLibraryChanged() {
    final podcastId = _library.episode(_episode.id)?.podcastId;
    final source = podcastId == null
        ? null
        : (podcastId, _library.podcast(podcastId)?.episodesVersion);
    if (source == _descriptionSource) return;
    setState(() {
      _descriptionSource = source;
      _description = null;
    });
  }

  Future<void> _change(Future<void> Function() action) => guardAction(() async {
    if (_error != null) setState(() => _error = null);
    try {
      await action();
    } on Object catch (error) {
      if (mounted) setState(() => _error = actionError(context, error));
    }
  });

  @override
  Widget build(BuildContext context) {
    final actions = EpisodeActions(
      episode: _episode,
      playback: widget.playback,
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
    final description = _descriptionSource == null
        ? null
        : _description ??= _library.description(id);
    final playback = widget.playback;
    final state = _library.stateOf(id);
    final podcast = _library.podcast(episode.podcastId);
    final playing = playback.playing(id);
    final length = episodeDuration(episode, state);
    final meta = [
      if (episode.publishedAt case final DateTime time)
        strings.published(dateText(strings, time)),
      if (length != null) minuteLength(strings, length),
    ];
    final subtitle = episodeStatusText(
      strings,
      state,
      length,
      playing: playing,
      showTotal: true,
    );

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
        if (_error case final String error) EinkError(error, inset: true),
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
                key: ObjectKey(description),
                future: description,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        EinkError(strings.descriptionFailed),
                        TextButton(
                          onPressed: () => setState(() => _description = null),
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
