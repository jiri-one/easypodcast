import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../core/downloads.dart';
import '../core/models.dart';
import '../core/sync.dart';
import 'eink_widgets.dart';
import 'episode_queue.dart';
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
    required this.onMenu,
    required this.wifiConnected,
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
  final ValueChanged<Episode> onMenu;
  final ValueListenable<bool?> wifiConnected;
  final List<Widget> actions;
  final bool desktop;
  final bool downloadsAvailable;
  final int? selectedId;
  final Map<int, int?> fileSizes;

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    if (kind == EpisodeListKind.queue) {
      return EpisodeQueue(
        key: key ?? PageStorageKey(kind),
        library: playback.services.library,
        episodes: episodes,
        header: ListProblems(playback: playback),
        onMenu: onMenu,
        rowBuilder: (context, episode, index, lifted) =>
            _episodeRow(context, episode, index, queued: true, lifted: lifted),
      );
    }
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
              queued: queued.contains(episode.id),
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
    int index, {
    required bool queued,
    bool lifted = false,
  }) {
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
    Widget buildRow(BuildContext context, DownloadDisplay download) {
      final downloadText = downloadStateText(strings, download);
      final downloaded = download.status == DownloadStatus.done;
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
        EpisodeListKind.downloads when downloaded => [
          status,
          if (fileSizes[episode.id] case final int bytes)
            bytesText(strings, bytes),
        ],
        EpisodeListKind.downloads => [?downloadText],
      };
      final content = EinkRow(
        key: row,
        title: kind == EpisodeListKind.queue
            ? strings.numberedTitle(index + 1, episode.title)
            : episode.title,
        selected: desktop ? episode.id == selectedId : null,
        lifted: lifted,
        desktop: desktop,
        onPressed: () => onOpen(episode),
        details: [
          if (kind != EpisodeListKind.podcast && podcast != null)
            Text(podcast, style: detailStyle),
          if (parts.isNotEmpty || downloaded)
            metadataLine(
              parts.firstOrNull ?? '',
              parts.skip(1),
              bold:
                  parts.isNotEmpty &&
                  ((playing && parts.first == status) ||
                      (kind == EpisodeListKind.podcast && state.isNew)),
              trailing: downloaded
                  ? Icon(
                      Icons.download_done,
                      size: 16,
                      color: lifted || (desktop && episode.id == selectedId)
                          ? Colors.white
                          : Colors.black,
                      semanticLabel: strings.stateDownloaded,
                    )
                  : null,
            ),
          if (download.status == DownloadStatus.failed)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: DefaultTextStyle.merge(
                style: detailStyle,
                child: EinkError(strings.stateDownloadFailed),
              ),
            ),
        ],
      );
      void showMenu() => onMenu(episode);
      return Semantics(
        onLongPress: showMenu,
        onLongPressHint: strings.episodeActions,
        child: GestureDetector(
          excludeFromSemantics: true,
          onLongPress: kind == EpisodeListKind.queue ? null : showMenu,
          onSecondaryTap: showMenu,
          child: content,
        ),
      );
    }

    if (!downloadsAvailable) return buildRow(context, noDownload);
    return DownloadStatusView(
      key: ValueKey(episode.id),
      services: playback.services,
      wifiConnected: wifiConnected,
      episodeId: episode.id,
      builder: buildRow,
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
