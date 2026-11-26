import 'package:material_ui/material_ui.dart';

import '../core/downloads.dart';
import '../core/models.dart';
import '../core/sync.dart';
import 'eink_widgets.dart';
import 'episode_text.dart';
import 'feed_refresh.dart';
import 'playback_actions.dart';
import 'theme.dart';

enum LibrarySection {
  inProgress,
  queue,
  newEpisodes,
  podcasts,
  downloads,
  settings;

  String label(BuildContext context) => switch (this) {
    inProgress => context.strings.inProgress,
    queue => context.strings.queue,
    newEpisodes => context.strings.newEpisodes,
    podcasts => context.strings.podcasts,
    downloads => context.strings.downloads,
    settings => context.strings.settings,
  };
}

enum EpisodeListKind { inProgress, queue, newEpisodes, podcast, downloads }

class ListProblems extends StatelessWidget {
  const ListProblems({super.key, required this.playback});

  final PlaybackActions playback;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: playback.services.sync.status,
    builder: (context, status, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (status.phase == SyncPhase.offline)
          ProblemBox(context.strings.offline),
        if (status.phase == SyncPhase.error)
          ProblemBox(context.strings.syncError),
        if (playback.failed) ProblemBox(context.strings.playbackFailed),
      ],
    ),
  );
}

class RefreshRow extends StatelessWidget {
  const RefreshRow({
    super.key,
    required this.refresh,
    required this.lastLoaded,
    this.podcastId,
  });

  final FeedRefresh refresh;
  final DateTime? lastLoaded;
  final int? podcastId;

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    final last = lastLoaded;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) => EinkRow(
            title: refresh.running ? strings.refreshing : strings.refresh,
            underlined: !refresh.running,
            compact: true,
            onPressed: () => refresh.request(podcastId: podcastId),
            trailing: last == null
                ? null
                : ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: constraints.maxWidth * 0.5,
                    ),
                    child: Text(
                      strings.loadedAt(clockText(strings, last)),
                      style: detailStyle,
                      textAlign: TextAlign.end,
                    ),
                  ),
          ),
        ),
        if (refresh.failed) ProblemBox(strings.refreshFailed),
      ],
    );
  }
}

class EpisodeRowKey extends GlobalObjectKey {
  const EpisodeRowKey(super.value);
}

class EpisodeList extends StatelessWidget {
  const EpisodeList({
    super.key,
    required this.kind,
    required this.episodes,
    required this.playback,
    required this.onOpen,
    this.actions = const [],
    this.desktop = false,
    this.downloadsAvailable = true,
    this.selectedId,
    this.fileSizes = const {},
  });

  final EpisodeListKind kind;
  final List<Episode> episodes;
  final PlaybackActions playback;
  final ValueChanged<Episode> onOpen;
  final List<Widget> actions;
  final bool desktop;
  final bool downloadsAvailable;
  final int? selectedId;
  final Map<int, int?> fileSizes;

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    final queued = switch (kind) {
      EpisodeListKind.podcast || EpisodeListKind.newEpisodes =>
        playback.services.library.queue.map((episode) => episode.id).toSet(),
      _ => const <int>{},
    };
    return CustomScrollView(
      key: key ?? PageStorageKey(kind),
      slivers: [
        SliverToBoxAdapter(child: ListProblems(playback: playback)),
        for (final action in actions) SliverToBoxAdapter(child: action),
        if (episodes.isEmpty)
          SliverToBoxAdapter(
            child: PageMessage(switch (kind) {
              EpisodeListKind.inProgress => strings.inProgressEmpty,
              EpisodeListKind.queue => strings.queueEmpty,
              EpisodeListKind.newEpisodes => strings.newEmpty,
              EpisodeListKind.podcast => strings.podcastEmpty,
              EpisodeListKind.downloads => strings.downloadsEmpty,
            }),
          ),
        SliverList.builder(
          itemCount: episodes.length,
          itemBuilder: (context, index) {
            final episode = episodes[index];
            final row = _episodeRow(
              context,
              episode,
              index,
              queued.contains(episode.id),
            );
            if (kind == EpisodeListKind.newEpisodes &&
                (index == 0 ||
                    !DateUtils.isSameDay(
                      episode.publishedAt?.toLocal(),
                      episodes[index - 1].publishedAt?.toLocal(),
                    ))) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
                    child: Semantics(
                      header: true,
                      child: Text(
                        dayGroup(strings, episode.publishedAt),
                        style: detailStyle.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  row,
                ],
              );
            }
            return row;
          },
        ),
      ],
    );
  }

  Widget _episodeRow(
    BuildContext context,
    Episode episode,
    int index,
    bool queued,
  ) {
    final strings = context.strings;
    final library = playback.services.library;
    final state = library.stateOf(episode.id);
    final playing = playback.playing(episode.id);
    final duration = episodeDuration(episode, state);
    final length = duration == null
        ? null
        : strings.minutes(durationMinutes(duration));
    final podcast = library.podcast(episode.podcastId)?.title;
    final status = switch ((playing, state.status, state.isInProgress)) {
      (true, _, _) => strings.statePlaying,
      (_, EpisodeStatus.played, _) => strings.statePlayed,
      (_, EpisodeStatus.dismissed, _) => strings.stateDismissed,
      (_, _, true) => playbackTime(
        strings,
        Duration(milliseconds: state.positionMs),
        duration,
      ),
      _ => strings.stateNew,
    };

    final row = desktop ? EpisodeRowKey(episode) : ValueKey(episode.id);
    Widget buildRow(BuildContext context, DownloadStatus download) {
      final wifiOnly = playback.services.settings.downloadOnWifiOnly;
      final waitingForWifi =
          wifiOnly &&
          playback.services.sync.status.value.phase == SyncPhase.offline;
      final downloadText = downloadStateText(
        strings,
        download,
        waitingForWifi: waitingForWifi,
      );
      final parts = switch (kind) {
        EpisodeListKind.inProgress => [status, ?downloadText],
        EpisodeListKind.queue => [
          status,
          if (state.isNew && !playing && length != null) length,
          ?downloadText,
        ],
        EpisodeListKind.newEpisodes => [
          if (playing) status,
          ?length,
          if (queued) strings.stateInQueue,
          ?downloadText,
        ],
        EpisodeListKind.podcast => [
          status,
          if (episode.publishedAt case final DateTime date)
            dateText(strings, date),
          if (queued) strings.stateInQueue,
          ?downloadText,
        ],
        EpisodeListKind.downloads when download == DownloadStatus.done => [
          status,
          if (fileSizes[episode.id] case final int bytes)
            bytesText(strings, bytes)
          else
            strings.stateDownloaded,
        ],
        EpisodeListKind.downloads => [?downloadText],
      };
      return EinkRow(
        key: row,
        title: kind == EpisodeListKind.queue
            ? strings.numberedTitle(index + 1, episode.title)
            : episode.title,
        selected: desktop ? episode.id == selectedId : null,
        desktop: desktop,
        onPressed: () => onOpen(episode),
        details: [
          if (kind != EpisodeListKind.podcast && podcast != null)
            Text(podcast, style: detailStyle),
          if (parts.isNotEmpty)
            metadataLine(
              parts.first,
              parts.skip(1),
              bold:
                  (playing && parts.first == status) ||
                  (kind == EpisodeListKind.podcast && state.isNew),
            ),
          if (download == DownloadStatus.failed)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: DefaultTextStyle.merge(
                style: detailStyle,
                child: EinkError(strings.stateDownloadFailed),
              ),
            ),
        ],
      );
    }

    if (!downloadsAvailable) return buildRow(context, DownloadStatus.none);
    return DownloadStatusView(
      key: ValueKey(episode.id),
      downloads: playback.services.downloads,
      episodeId: episode.id,
      builder: (context, status) => status == DownloadStatus.queued
          ? ValueListenableBuilder(
              valueListenable: playback.services.sync.status,
              builder: (context, _, _) => buildRow(context, status),
            )
          : buildRow(context, status),
    );
  }
}

class PodcastList extends StatelessWidget {
  const PodcastList({
    super.key,
    required this.playback,
    required this.alphabetical,
    required this.onOpen,
    required this.onAdd,
    this.desktop = false,
  });

  final PlaybackActions playback;
  final bool alphabetical;
  final ValueChanged<Podcast> onOpen;
  final VoidCallback onAdd;
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    final podcasts = playback.services.library.podcasts;
    final sorted = alphabetical
        ? _alphabetical(podcasts, strings.localeName)
        : podcasts;
    return CustomScrollView(
      key: const PageStorageKey(LibrarySection.podcasts),
      slivers: [
        SliverToBoxAdapter(child: ListProblems(playback: playback)),
        SliverToBoxAdapter(
          child: EinkRow(
            title: strings.addPodcast,
            leading: const Icon(Icons.add),
            underlined: true,
            compact: true,
            onPressed: onAdd,
          ),
        ),
        if (sorted.isEmpty)
          SliverToBoxAdapter(child: PageMessage(strings.podcastsEmpty)),
        SliverList.builder(
          itemCount: sorted.length,
          itemBuilder: (context, index) {
            final podcast = sorted[index];
            return EinkRow(
              key: ValueKey(podcast.id),
              title: podcast.title,
              desktop: desktop,
              onPressed: () => onOpen(podcast),
              details: [
                Text(
                  strings.playedCount(podcast.playedCount),
                  style: detailStyle,
                ),
                if (podcast.lastError?.isNotEmpty ?? false)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: DefaultTextStyle.merge(
                      style: detailStyle,
                      child: EinkError(strings.feedUnavailable),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

List<Podcast> _alphabetical(List<Podcast> podcasts, String locale) {
  if (locale != 'cs') {
    return podcasts.toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  }
  const alphabet = 'abcčdefgh|ijklmnopqrřsštuvwxyzž';
  const accents = {
    'á': 'a',
    'ď': 'd',
    'é': 'e',
    'ě': 'e',
    'í': 'i',
    'ň': 'n',
    'ó': 'o',
    'ť': 't',
    'ú': 'u',
    'ů': 'u',
    'ý': 'y',
  };
  List<int> key(String title) => [
    for (final rune in title.toLowerCase().replaceAll('ch', '|').runes)
      switch (alphabet.indexOf(
        accents[String.fromCharCode(rune)] ?? String.fromCharCode(rune),
      )) {
        -1 => rune < 97 ? rune : 200 + rune,
        final index => 100 + index,
      },
  ];

  final entries = [
    for (final podcast in podcasts) (podcast, key(podcast.title)),
  ];
  entries.sort((a, b) {
    final shared = a.$2.length < b.$2.length ? a.$2.length : b.$2.length;
    for (var index = 0; index < shared; index++) {
      final result = a.$2[index].compareTo(b.$2[index]);
      if (result != 0) return result;
    }
    final byLength = a.$2.length.compareTo(b.$2.length);
    return byLength == 0 ? a.$1.title.compareTo(b.$1.title) : byLength;
  });
  return [for (final entry in entries) entry.$1];
}

class QueueEditor extends StatefulWidget {
  const QueueEditor({super.key, required this.playback, this.desktop = false});

  final PlaybackActions playback;
  final bool desktop;

  @override
  State<QueueEditor> createState() => _QueueEditorState();
}

class _QueueEditorState extends State<QueueEditor> {
  final _scroll = ScrollController();
  int? _selected;
  bool _moving = false;
  bool _failed = false;

  Future<void> _move(int target) async {
    final selected = _selected;
    if (selected == null || _moving) return;
    setState(() {
      _moving = true;
      _failed = false;
    });
    try {
      await widget.playback.services.library.moveInQueue(selected, target);
      if (mounted && target == 0 && _scroll.hasClients) _scroll.jumpTo(0);
    } on Exception {
      if (mounted) _failed = true;
    } finally {
      if (mounted) setState(() => _moving = false);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    final queue = widget.playback.services.library.queue;
    final index = queue.indexWhere((e) => e.id == _selected);
    final controls = index < 0
        ? Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(strings.queueSelect, style: buttonLabelStyle),
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 8,
            children: [
              Row(
                spacing: 8,
                children: [
                  Expanded(
                    child: EinkButton(
                      strings.moveUp,
                      icon: Icons.arrow_upward,
                      onPressed: index == 0 ? null : () => _move(index - 1),
                    ),
                  ),
                  Expanded(
                    child: EinkButton(
                      strings.moveDown,
                      icon: Icons.arrow_downward,
                      onPressed: index == queue.length - 1
                          ? null
                          : () => _move(index + 1),
                    ),
                  ),
                ],
              ),
              EinkButton(
                strings.moveToTop,
                onPressed: index == 0 ? null : () => _move(0),
              ),
            ],
          );
    return Column(
      children: [
        if (_failed) ProblemBox(strings.actionFailed),
        if (_moving) PageMessage(strings.queueLoading),
        if (queue.isEmpty) PageMessage(strings.queueEmpty),
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            itemCount: queue.length,
            itemBuilder: (context, i) {
              final episode = queue[i];
              return EinkRow(
                key: ValueKey(episode.id),
                title: strings.numberedTitle(i + 1, episode.title),
                onPressed: () => setState(() => _selected = episode.id),
                selected: episode.id == _selected,
                desktop: widget.desktop,
              );
            },
          ),
        ),
        if (queue.isNotEmpty)
          DecoratedBox(
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(width: 2)),
            ),
            child: Container(
              constraints: const BoxConstraints(minHeight: 122),
              padding: const EdgeInsets.all(8),
              width: double.infinity,
              alignment: Alignment.center,
              child: controls,
            ),
          ),
      ],
    );
  }
}
