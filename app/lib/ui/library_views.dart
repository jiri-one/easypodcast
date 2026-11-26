import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/downloads.dart';
import '../core/models.dart';
import '../core/services.dart';
import '../core/sync.dart';
import 'cover_image.dart';
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
  search,
  downloads,
  settings;

  String label(BuildContext context) => switch (this) {
    inProgress => context.strings.inProgress,
    queue => context.strings.queue,
    newEpisodes => context.strings.newEpisodes,
    podcasts => context.strings.podcasts,
    search => context.strings.search,
    downloads => context.strings.downloads,
    settings => context.strings.settings,
  };
}

enum EpisodeListKind {
  inProgress,
  queue,
  newEpisodes,
  podcast,
  search,
  downloads,
}

String? syncProblem(BuildContext context, SyncStatus status) =>
    switch (status.phase) {
      SyncPhase.offline => context.strings.offline,
      SyncPhase.error => context.strings.syncError,
      _ => null,
    };

bool loadingLibrary(AppServices services) {
  final status = services.sync.status.value;
  return status.syncing &&
      status.lastSuccess == null &&
      status.phase == SyncPhase.idle &&
      services.library.podcasts.isEmpty;
}

class ListProblems extends StatelessWidget {
  const ListProblems(this.status, {super.key});

  final SyncStatus status;

  @override
  Widget build(BuildContext context) {
    final problem = syncProblem(context, status);
    return problem == null
        ? const SizedBox.shrink()
        : EinkError(problem, inset: true);
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
        if (refresh.failedFor(podcastId))
          EinkError(strings.refreshFailed, inset: true),
      ],
    );
  }
}

Widget listHeading(String text) => Padding(
  padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
  child: Semantics(
    header: true,
    child: Text(text, style: detailStyle.copyWith(fontWeight: FontWeight.w700)),
  ),
);

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
    this.actions = const [],
    this.headerSlivers = const [],
    this.desktop = false,
    this.selectedId,
    this.emptyMessage,
    this.fileSizes = const {},
  });

  final EpisodeListKind kind;
  final List<Episode> episodes;
  final PlaybackActions playback;
  final ValueChanged<Episode> onOpen;
  final ValueChanged<Episode> onMenu;
  final List<Widget> actions;
  final List<Widget> headerSlivers;
  final bool desktop;
  final int? selectedId;
  final String? emptyMessage;
  final Map<int, int?> fileSizes;

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    final library = playback.services.library;
    final problem = ListProblems(playback.services.sync.status.value);
    final loading = episodes.isEmpty && loadingLibrary(playback.services);
    if (kind == EpisodeListKind.queue) {
      return EpisodeQueue(
        key: key ?? PageStorageKey(kind),
        library: library,
        episodes: episodes,
        header: problem,
        emptyMessage: loading ? strings.syncLoading : strings.queueEmpty,
        onMenu: onMenu,
        rowBuilder: (context, episode, index, lifted) =>
            _episodeRow(context, episode, index, queued: true, lifted: lifted),
      );
    }
    final queued = switch (kind) {
      EpisodeListKind.podcast ||
      EpisodeListKind.search ||
      EpisodeListKind.newEpisodes =>
        library.projectedQueue.map((episode) => episode.id).toSet(),
      _ => const <int>{},
    };
    return CustomScrollView(
      key: key ?? PageStorageKey(kind),
      slivers: [
        SliverToBoxAdapter(child: problem),
        for (final action in actions) SliverToBoxAdapter(child: action),
        ...headerSlivers,
        if (episodes.isEmpty)
          SliverToBoxAdapter(
            child: PageMessage(
              emptyMessage ??
                  (loading
                      ? strings.syncLoading
                      : switch (kind) {
                          EpisodeListKind.inProgress => strings.inProgressEmpty,
                          EpisodeListKind.queue => strings.queueEmpty,
                          EpisodeListKind.newEpisodes => strings.newEmpty,
                          EpisodeListKind.podcast => strings.podcastEmpty,
                          EpisodeListKind.search => strings.noMatchingEpisodes,
                          EpisodeListKind.downloads => strings.downloadsEmpty,
                        }),
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
                  listHeading(dayGroup(strings, episode.publishedAt)),
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
    final podcast = library.podcast(episode.podcastId);
    final showPodcast = kind != EpisodeListKind.podcast;
    final boldNew =
        kind == EpisodeListKind.podcast || kind == EpisodeListKind.search;
    final hasRemainingTime =
        !playing &&
        state.isInProgress &&
        duration != null &&
        state.resumePosition <= duration;
    final status = episodeStatusText(
      strings,
      state,
      duration,
      playing: playing,
    );

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
        EpisodeListKind.podcast || EpisodeListKind.search => [
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
        overline: showPodcast && podcast != null
            ? _PodcastHeader(podcast)
            : null,
        selected: desktop ? episode.id == selectedId : null,
        lifted: lifted,
        desktop: desktop,
        onPressed: () => onOpen(episode),
        details: [
          if (parts.isNotEmpty || downloaded)
            _EpisodeMetadata(
              parts: parts,
              bold:
                  parts.isNotEmpty &&
                  ((playing && parts.first == status) ||
                      (boldNew && state.isNew)),
              remaining: hasRemainingTime && parts.firstOrNull == status,
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
    required this.remaining,
    required this.downloaded,
    required this.inverted,
  });

  final List<String> parts;
  final bool bold;
  final bool remaining;
  final bool downloaded;
  final bool inverted;

  @override
  Widget build(BuildContext context) {
    const iconSize = 16.0;
    const gap = 4.0;
    final first = parts.firstOrNull ?? '';
    final rest = parts.skip(1);
    final text = metadataLine(first, rest, bold: bold);
    final color = inverted ? Colors.white : Colors.black;
    final label = context.strings.stateDownloaded;
    Widget line(bool showLabel) => Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      spacing: gap,
      children: [
        if (remaining) Icon(Icons.schedule, size: iconSize, color: color),
        if (parts.isNotEmpty) Flexible(child: text),
        if (downloaded)
          Icon(
            Icons.download_outlined,
            size: iconSize,
            color: color,
            semanticLabel: showLabel ? null : label,
          ),
        if (showLabel) Text(label, style: metadataStyle),
      ],
    );

    if (!downloaded) return remaining ? line(false) : text;
    return LayoutBuilder(
      builder: (context, bounds) {
        final painter = TextPainter(
          text: TextSpan(
            style: DefaultTextStyle.of(context).style.merge(metadataStyle),
            children: [
              text.textSpan!,
              TextSpan(text: label),
            ],
          ),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final markerWidth = iconSize + gap;
        final labelWidth =
            painter.width + markerWidth + gap + (remaining ? markerWidth : 0);
        painter.dispose();
        return line(labelWidth <= bounds.maxWidth);
      },
    );
  }
}

class _PodcastHeader extends StatelessWidget {
  const _PodcastHeader(this.podcast);

  final Podcast podcast;

  @override
  Widget build(BuildContext context) {
    final name = Text(
      podcast.title,
      style: detailStyle.copyWith(fontWeight: FontWeight.w700),
    );
    if (validCoverUrl(podcast.imageUrl) == null) return name;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        spacing: 8,
        children: [
          _PodcastThumbnail(podcast.imageUrl, side: 44),
          Expanded(child: name),
        ],
      ),
    );
  }
}

class _PodcastThumbnail extends StatelessWidget {
  const _PodcastThumbnail(this.imageUrl, {this.side = 52});

  final String? imageUrl;
  final double side;

  @override
  Widget build(BuildContext context) {
    final url = validCoverUrl(imageUrl);
    return SizedBox.square(
      dimension: side,
      child: url == null
          ? null
          : ColorFiltered(
              colorFilter: coverGrayscale,
              child: Image(
                image: CoverImage(url)
                    .resized(side, MediaQuery.devicePixelRatioOf(context)),
                fit: BoxFit.cover,
                excludeFromSemantics: true,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
    );
  }
}

class PodcastList extends StatelessWidget {
  const PodcastList({
    super.key,
    required this.playback,
    required this.onOpen,
    required this.onAdd,
    this.desktop = false,
  });

  final PlaybackActions playback;
  final ValueChanged<Podcast> onOpen;
  final VoidCallback onAdd;
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    final podcasts = playback.services.library.podcasts;
    final sorted = playback.services.settings.alphabeticalPodcasts
        ? _alphabetical(podcasts, strings.localeName)
        : podcasts;
    return CustomScrollView(
      key: const PageStorageKey(LibrarySection.podcasts),
      slivers: [
        SliverToBoxAdapter(
          child: ListProblems(playback.services.sync.status.value),
        ),
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
              loadingLibrary(playback.services)
                  ? strings.syncLoading
                  : strings.podcastsEmpty,
            ),
          ),
        rows(sorted, onOpen: onOpen, desktop: desktop),
      ],
    );
  }

  static Widget rows(
    List<Podcast> podcasts, {
    required ValueChanged<Podcast> onOpen,
    required bool desktop,
  }) => SliverList.builder(
    itemCount: podcasts.length,
    itemBuilder: (context, index) {
      final podcast = podcasts[index];
      final strings = context.strings;
      return EinkRow(
        key: ValueKey(podcast.id),
        title: podcast.title,
        leading: _PodcastThumbnail(podcast.imageUrl),
        topAligned: true,
        desktop: desktop,
        onPressed: () => onOpen(podcast),
        details: [
          Text(strings.playedCount(podcast.playedCount), style: metadataStyle),
          if (podcast.lastError?.isNotEmpty ?? false)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: DefaultTextStyle.merge(
                style: detailStyle,
                child: EinkError(strings.feedUnavailable, liveRegion: false),
              ),
            ),
        ],
      );
    },
  );
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
