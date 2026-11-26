import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/downloads.dart';
import '../core/models.dart';
import 'eink_widgets.dart';
import 'episode_queue.dart';
import 'episode_text.dart';
import 'feed_refresh.dart';
import 'playback_actions.dart';
import 'queue_edits.dart';
import 'sync_feedback.dart';
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
  const ListProblems({super.key});

  @override
  Widget build(BuildContext context) {
    final problem = SyncFeedback.of(context).problem(context);
    return problem == null ? const SizedBox.shrink() : ProblemBox(problem);
  }
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
    final running = refresh.runningFor(podcastId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) => EinkRow(
            title: running
                ? strings.refreshing
                : refresh.requestedFor(podcastId, last)
                ? strings.refreshRequested
                : strings.refresh,
            underlined: !running,
            compact: true,
            onPressed: () => refresh.request(podcastId: podcastId),
            trailing: last == null
                ? null
                : ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: constraints.maxWidth * 0.5,
                    ),
                    child: Text(
                      DateUtils.isSameDay(last.toLocal(), DateTime.now())
                          ? strings.loadedAt(clockText(strings, last))
                          : strings.loadedOn(dateText(strings, last)),
                      style: detailStyle,
                      textAlign: TextAlign.end,
                    ),
                  ),
          ),
        ),
        if (refresh.failedFor(podcastId)) ProblemBox(strings.refreshFailed),
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
    required this.queueEdits,
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
  final QueueEdits queueEdits;
  final List<Widget> actions;
  final bool desktop;
  final bool downloadsAvailable;
  final int? selectedId;
  final Map<int, int?> fileSizes;

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    final loading =
        episodes.isEmpty &&
        SyncFeedback.of(context).loadingLibrary(playback.services.library);
    if (kind == EpisodeListKind.queue) {
      return EpisodeQueue(
        key: key ?? PageStorageKey(kind),
        edits: queueEdits,
        episodes: episodes,
        header: const ListProblems(),
        emptyMessage: loading ? strings.syncLoading : strings.queueEmpty,
        onMenu: onMenu,
        rowBuilder: (context, episode, index, lifted) =>
            _episodeRow(context, episode, index, queued: true, lifted: lifted),
      );
    }
    final queued = switch (kind) {
      EpisodeListKind.podcast || EpisodeListKind.newEpisodes =>
        queueEdits.episodes.map((episode) => episode.id).toSet(),
      _ => const <int>{},
    };
    return CustomScrollView(
      key: key ?? PageStorageKey(kind),
      slivers: [
        const SliverToBoxAdapter(child: ListProblems()),
        for (final action in actions) SliverToBoxAdapter(child: action),
        if (episodes.isEmpty)
          SliverToBoxAdapter(
            child: PageMessage(
              loading
                  ? strings.syncLoading
                  : switch (kind) {
                      EpisodeListKind.inProgress => strings.inProgressEmpty,
                      EpisodeListKind.queue => strings.queueEmpty,
                      EpisodeListKind.newEpisodes => strings.newEmpty,
                      EpisodeListKind.podcast => strings.podcastEmpty,
                      EpisodeListKind.downloads => strings.downloadsEmpty,
                    },
            ),
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
        if (kind == EpisodeListKind.newEpisodes && !loading)
          SliverToBoxAdapter(
            child: PageMessage(strings.olderEpisodesInPodcasts),
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
    final length = duration == null ? null : minuteLength(strings, duration);
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
      final inverted = lifted || (desktop && episode.id == selectedId);
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
            _EpisodeMetadata(
              parts: parts,
              bold:
                  parts.isNotEmpty &&
                  ((playing && parts.first == status) ||
                      (kind == EpisodeListKind.podcast && state.isNew)),
              downloaded: downloaded,
              inverted: inverted,
            ),
          if (download.status == DownloadStatus.failed)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: DefaultTextStyle.merge(
                style: detailStyle,
                child: EinkError(
                  strings.stateDownloadFailed,
                  liveRegion: false,
                ),
              ),
            ),
        ],
      );
      void showMenu() => onMenu(episode);
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.f10, shift: true): showMenu,
          const SingleActivator(LogicalKeyboardKey.contextMenu): showMenu,
        },
        child: Semantics(
          onLongPress: showMenu,
          onLongPressHint: strings.episodeActions,
          child: GestureDetector(
            excludeFromSemantics: true,
            onLongPress: kind == EpisodeListKind.queue ? null : showMenu,
            onSecondaryTap: showMenu,
            child: content,
          ),
        ),
      );
    }

    if (!downloadsAvailable) return buildRow(context, noDownload);
    return DownloadStatusView(
      key: ValueKey(episode.id),
      services: playback.services,
      episodeId: episode.id,
      builder: buildRow,
    );
  }
}

class _EpisodeMetadata extends StatelessWidget {
  const _EpisodeMetadata({
    required this.parts,
    required this.bold,
    required this.downloaded,
    required this.inverted,
  });

  final List<String> parts;
  final bool bold;
  final bool downloaded;
  final bool inverted;

  @override
  Widget build(BuildContext context) {
    final first = parts.firstOrNull ?? '';
    final rest = parts.skip(1);
    final metadata = metadataLine(first, rest, bold: bold);
    if (!downloaded) return metadata;
    final label = context.strings.stateDownloaded;
    return LayoutBuilder(
      builder: (context, bounds) {
        final painter = TextPainter(
          text: TextSpan(
            style: DefaultTextStyle.of(context).style.merge(detailStyle),
            children: [
              metadata.textSpan!,
              TextSpan(text: label),
            ],
          ),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final showLabel = painter.width + 24 <= bounds.maxWidth;
        painter.dispose();
        return Row(
          spacing: 4,
          children: [
            if (parts.isNotEmpty) Flexible(child: metadata),
            Icon(
              Icons.download_outlined,
              size: 16,
              color: inverted ? Colors.white : Colors.black,
              semanticLabel: showLabel ? null : label,
            ),
            if (showLabel) Text(label, style: detailStyle),
          ],
        );
      },
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
        const SliverToBoxAdapter(child: ListProblems()),
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
          SliverToBoxAdapter(
            child: PageMessage(
              SyncFeedback.of(context).loadingLibrary(playback.services.library)
                  ? strings.syncLoading
                  : strings.podcastsEmpty,
            ),
          ),
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
                      child: EinkError(
                        strings.feedUnavailable,
                        liveRegion: false,
                      ),
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
