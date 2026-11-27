import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/api.dart';
import '../core/library.dart';
import '../core/models.dart';
import '../core/services.dart';
import 'eink_widgets.dart';
import 'episode_text.dart';
import 'library_views.dart';
import 'plain_links.dart';
import 'playback_actions.dart';
import 'player_views.dart';
import 'theme.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.playback,
    required this.onServer,
    required this.onFeeds,
    required this.onOpml,
  });

  final PlaybackActions playback;
  final VoidCallback onServer;
  final VoidCallback onFeeds;
  final VoidCallback onOpml;

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    final services = playback.services;
    final settings = services.settings;
    const version = String.fromEnvironment(
      'EASYPODCAST_VERSION',
      defaultValue: '1.0.0',
    );
    return PageList(
      key: const PageStorageKey('settings-list'),
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            EinkRow(
              title: strings.server,
              trailing: const Icon(Icons.chevron_right),
              onPressed: onServer,
              last: true,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 4,
                children: [
                  ServerStatusLine(services: services),
                  if (services.sync.status.value.clockSkewWarning
                      case final skew?)
                    Text(
                      strings.serverClockSkew(skew.abs().inMinutes),
                      style: detailStyle,
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
          ],
        ),
        _ToggleRow(
          title: strings.continueQueue,
          description: settings.autoplayQueue
              ? strings.continueQueueOn
              : strings.continueQueueOff,
          value: settings.autoplayQueue,
          onPressed: () => settings.autoplayQueue = !settings.autoplayQueue,
        ),
        _ToggleRow(
          title: strings.showSpeedAndSleep,
          value: settings.showSpeedAndSleep,
          onPressed: () {
            // A hidden sleep timer would stop playback with nothing on screen.
            if (settings.showSpeedAndSleep) services.player.setSleepTimer(null);
            settings.showSpeedAndSleep = !settings.showSpeedAndSleep;
          },
        ),
        if (settings.showSpeedAndSleep)
          EinkRow(
            title: strings.speed,
            details: [
              Text(
                speedText(strings, services.player.speed),
                style: detailStyle,
              ),
            ],
            trailing: const Icon(Icons.chevron_right),
            onPressed: () => showSpeedChoices(context, playback),
          ),
        _SecondsRow(
          title: strings.skipBack,
          options: const [10, 15, 30],
          value: settings.skipBackSeconds,
          onChange: (value) => settings.skipBackSeconds = value,
        ),
        _SecondsRow(
          title: strings.skipForward,
          options: const [15, 30, 60],
          value: settings.skipForwardSeconds,
          onChange: (value) => settings.skipForwardSeconds = value,
        ),
        if (downloadsAvailable) ...[
          _ToggleRow(
            title: strings.downloadWifi,
            value: settings.downloadOnWifiOnly,
            onPressed: () =>
                settings.downloadOnWifiOnly = !settings.downloadOnWifiOnly,
          ),
          _ToggleRow(
            title: strings.keepQueueDownloaded,
            value: settings.keepQueueDownloaded,
            onPressed: () =>
                settings.keepQueueDownloaded = !settings.keepQueueDownloaded,
          ),
          _ToggleRow(
            title: strings.deletePlayedDownloads,
            value: settings.deleteAfterPlayed,
            onPressed: () =>
                settings.deleteAfterPlayed = !settings.deleteAfterPlayed,
          ),
        ],
        _ToggleRow(
          title: strings.alphabeticalPodcasts,
          value: settings.alphabeticalPodcasts,
          onPressed: () =>
              settings.alphabeticalPodcasts = !settings.alphabeticalPodcasts,
        ),
        EinkRow(
          title: strings.feedStatus,
          trailing: const Icon(Icons.chevron_right),
          onPressed: onFeeds,
        ),
        EinkRow(
          title: strings.opml,
          trailing: const Icon(Icons.chevron_right),
          onPressed: onOpml,
        ),
        EinkRow(title: strings.version(version)),
      ],
    );
  }
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.title,
    this.description,
    required this.value,
    required this.onPressed,
  });

  final String title;
  final String? description;
  final bool value;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => EinkRow(
    title: title,
    details: [
      if (description case final String text) Text(text, style: detailStyle),
    ],
    toggled: value,
    onPressed: onPressed,
    trailing: ExcludeSemantics(
      child: Container(
        width: 52,
        height: 32,
        padding: const EdgeInsets.all(4),
        alignment: value
            ? AlignmentDirectional.centerEnd
            : AlignmentDirectional.centerStart,
        decoration: BoxDecoration(
          color: value ? Colors.black : Colors.white,
          border: Border.all(width: 2),
          borderRadius: BorderRadius.circular(16),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: value ? Colors.white : Colors.black,
            shape: BoxShape.circle,
          ),
          child: const SizedBox.square(dimension: 20),
        ),
      ),
    ),
  );
}

class _SecondsRow extends StatelessWidget {
  const _SecondsRow({
    required this.title,
    required this.options,
    required this.value,
    required this.onChange,
  });

  final String title;
  final List<int> options;
  final int value;
  final ValueChanged<int> onChange;

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    return EinkRow(
      title: title,
      details: [
        if (!options.contains(value))
          Text(strings.seconds(value), style: detailStyle),
        const SizedBox(height: 6),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<int>(
            segments: [
              for (final seconds in options)
                ButtonSegment(
                  value: seconds,
                  label: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 30),
                    child: Align(
                      widthFactor: 1,
                      heightFactor: 1,
                      child: Text(
                        strings.seconds(seconds),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
            ],
            expandedInsets: EdgeInsets.zero,
            selected: {if (options.contains(value)) value},
            emptySelectionAllowed: !options.contains(value),
            showSelectedIcon: false,
            onSelectionChanged: (selected) => onChange(selected.single),
            style: ButtonStyle(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: WidgetStatePropertyAll(
                Theme.of(context).textTheme.labelLarge!.merge(buttonLabelStyle),
              ),
              padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(vertical: 9),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class ServerStatusLine extends StatelessWidget {
  const ServerStatusLine({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    final status = services.sync.status.value;
    final strings = context.strings;
    final problem = syncProblem(context, status);
    final last = status.lastSuccess;
    final lastSync = last == null
        ? (loadingLibrary(services)
              ? strings.syncLoading
              : strings.serverConnected)
        : strings.serverLastSync(
            [
              if (!DateUtils.isSameDay(last.toLocal(), DateTime.now()))
                dateText(strings, last),
              clockText(strings, last),
            ].join(' '),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 4,
      children: [
        if (status.pending > 0)
          TextButton(
            onPressed: services.sync.syncNow,
            style: const ButtonStyle(
              alignment: AlignmentDirectional.centerStart,
              padding: WidgetStatePropertyAll(EdgeInsets.zero),
            ),
            child: Text.rich(
              TextSpan(
                text:
                    strings.pendingChanges(status.pending) + metadataSeparator,
                children: [
                  TextSpan(text: strings.sendNow, style: underlineStyle),
                ],
              ),
              style: detailStyle,
            ),
          )
        else if (last != null || problem == null)
          Text(lastSync, style: detailStyle),
        if (problem != null)
          DefaultTextStyle.merge(style: detailStyle, child: EinkError(problem)),
      ],
    );
  }
}

class ServerPage extends StatefulWidget {
  const ServerPage({super.key, required this.services});

  final AppServices services;

  @override
  State<ServerPage> createState() => _ServerPageState();
}

class _ServerPageState extends State<ServerPage> {
  bool _loggingOut = false;
  bool _failed = false;

  Future<void> _logout() async {
    if (_loggingOut) return;
    setState(() {
      _loggingOut = true;
      _failed = false;
    });
    final services = widget.services;
    try {
      try {
        await services.player.stop();
      } finally {
        await services.sync.logout();
      }
    } on Exception {
      _failed = true;
    } finally {
      if (mounted) setState(() => _loggingOut = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    final sync = widget.services.sync;
    return PageList(
      children: [
        EinkRow(
          title: strings.serverAddress,
          details: [
            Text(sync.serverUrl, style: detailStyle),
            ServerStatusLine(services: widget.services),
          ],
        ),
        if (sync.deviceName.isNotEmpty)
          EinkRow(
            title: strings.deviceName,
            details: [Text(sync.deviceName, style: detailStyle)],
          ),
        PageMessage(strings.serverChangeHelp),
        if (_failed) EinkError(strings.actionFailed, inset: true),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: EinkButton(
            _loggingOut ? strings.loggingOut : strings.logout,
            onPressed: _logout,
            alternatives: [strings.loggingOut, strings.logout],
          ),
        ),
      ],
    );
  }
}

class AboutPodcastPage extends StatelessWidget {
  const AboutPodcastPage({
    super.key,
    required this.services,
    required this.podcast,
  });

  final AppServices services;
  final Podcast podcast;

  @override
  Widget build(BuildContext context) => _PodcastSubscription(
    library: services.library,
    podcast: podcast,
    aboutDetails: [
      Text(podcast.title, style: headingStyle),
      if (podcast.author.isNotEmpty) Text(podcast.author, style: detailStyle),
      if (podcast.description.isNotEmpty) ...[
        const SizedBox(height: 12),
        PlainLinks(podcast.description, style: buttonLabelStyle),
      ],
      const SizedBox(height: 12),
      Text(context.strings.feedAddress, style: buttonLabelStyle),
      PlainLinks(podcast.feedUrl),
      const SizedBox(height: 8),
      FeedStatusText(podcast),
    ],
  );
}

Future<void> showPodcastMenu(
  BuildContext context,
  Library library,
  Podcast podcast,
) => showEinkDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (context) {
    final route = ModalRoute.of(context)!;
    return Offstage(
      // A taller menu would show around the confirmation above it.
      offstage: !route.isCurrent,
      child: ListenableBuilder(
        listenable: library,
        builder: (context, _) {
          final current = library.podcast(podcast.id);
          if (current != null && current.subscribed) {
            return _PodcastSubscription(library: library, podcast: current);
          }
          // Wait for any confirmation above the menu to close.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (route.isCurrent) route.navigator!.pop();
          });
          return const SizedBox.shrink();
        },
      ),
    );
  },
);

class _PodcastSubscription extends StatefulWidget {
  const _PodcastSubscription({
    required this.library,
    required this.podcast,
    this.aboutDetails,
  });

  final Library library;
  final Podcast podcast;
  final List<Widget>? aboutDetails;

  @override
  State<_PodcastSubscription> createState() => _PodcastSubscriptionState();
}

class _PodcastSubscriptionState extends State<_PodcastSubscription>
    with ActionTapGuard {
  String? _error;
  bool? _subscribing;
  bool? _requestedShow;

  Future<void> _toggleShowInNewEpisodes() => guardAction(() async {
    final podcast = widget.podcast;
    final show = !podcast.showInNewEpisodes;
    setState(() {
      _error = null;
      _requestedShow = show;
    });
    try {
      await widget.library.setShowInNewEpisodes(podcast.id, show);
    } on Exception catch (error) {
      if (mounted) _error = actionError(context, error);
    } finally {
      if (mounted) setState(() => _requestedShow = null);
    }
  });

  Future<void> _changeSubscription() => guardAction(() async {
    final podcast = widget.podcast;
    final strings = context.strings;
    if (_error != null) setState(() => _error = null);
    try {
      if (podcast.subscribed) {
        final confirmed = await confirmAction(
          context,
          title: strings.unsubscribeTitle,
          message: strings.unsubscribeHelp,
          action: strings.unsubscribe,
        );
        if (!confirmed || !mounted) return;
        setState(() => _subscribing = false);
        await widget.library.unsubscribe(podcast.id);
      } else {
        setState(() => _subscribing = true);
        await widget.library.subscribe(podcast.feedUrl);
      }
    } on Exception catch (error) {
      if (mounted) _error = actionError(context, error);
    } finally {
      if (mounted) setState(() => _subscribing = null);
    }
  });

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    final podcast = widget.podcast;
    final aboutDetails = widget.aboutDetails;
    final button = EinkButton(
      switch (_subscribing) {
        true => strings.addingPodcast,
        false => strings.unsubscribing,
        null => podcast.subscribed ? strings.unsubscribe : strings.resubscribe,
      },
      onPressed: _changeSubscription,
      alternatives: [
        strings.unsubscribe,
        strings.unsubscribing,
        strings.resubscribe,
        strings.addingPodcast,
      ],
    );
    final children = [
      if (aboutDetails == null)
        button
      else
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [...aboutDetails, const SizedBox(height: 16), button],
          ),
        ),
      if (podcast.subscribed) ...[
        if (aboutDetails == null)
          const SizedBox(height: 6)
        else
          const Divider(height: 1),
        _ToggleRow(
          title: strings.showInNewEpisodes,
          value: _requestedShow ?? podcast.showInNewEpisodes,
          onPressed: _toggleShowInNewEpisodes,
        ),
      ] else
        PageMessage(strings.notSubscribed),
      if (_error case final error?) ...[
        if (aboutDetails == null) const SizedBox(height: 6),
        EinkError(error, inset: aboutDetails != null),
      ],
    ];
    return aboutDetails == null
        ? EinkDialogPanel(
            title: podcast.title,
            actions: [
              TextButton(
                // A double tap on the confirmation ends on this button.
                onPressed: _subscribing == null
                    ? () => Navigator.pop(context)
                    : null,
                child: Text(strings.close, style: buttonLabelStyle),
              ),
            ],
            children: children,
          )
        : PageList(children: children);
  }
}

class FeedStatusText extends StatelessWidget {
  const FeedStatusText(
    this.podcast, {
    super.key,
    this.showLastLoaded = true,
    this.liveRegion = true,
  });

  final Podcast podcast;
  final bool showLastLoaded;
  final bool liveRegion;

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    final time = podcast.lastSuccessAt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 4,
      children: [
        if (showLastLoaded)
          Text(
            time == null
                ? strings.feedNeverLoaded
                : strings.feedLastLoaded(
                    dateText(strings, time),
                    clockText(strings, time),
                  ),
            style: detailStyle,
          ),
        if (podcast.lastError case final String error when error.isNotEmpty)
          DefaultTextStyle.merge(
            style: detailStyle,
            child: EinkError(
              '${strings.feedUnavailable} ${maskUrlCredentials(error)}',
              liveRegion: liveRegion,
            ),
          ),
      ],
    );
  }
}

class FeedStatusPage extends StatelessWidget {
  const FeedStatusPage({
    super.key,
    required this.services,
    required this.onOpen,
  });

  final AppServices services;
  final ValueChanged<Podcast> onOpen;

  @override
  Widget build(BuildContext context) {
    final podcasts = services.library.podcasts;
    if (podcasts.isEmpty) return PageMessage(context.strings.podcastsEmpty);
    return ListView.builder(
      key: const PageStorageKey('feed-status-list'),
      itemCount: podcasts.length,
      itemBuilder: (context, index) {
        final podcast = podcasts[index];
        return EinkRow(
          title: podcast.title,
          details: [FeedStatusText(podcast, liveRegion: false)],
          trailing: const Icon(Icons.chevron_right),
          onPressed: () => onOpen(podcast),
        );
      },
    );
  }
}

enum _OpmlAction { import, export }

class OpmlPage extends StatefulWidget {
  const OpmlPage({super.key, required this.services});

  final AppServices services;

  @override
  State<OpmlPage> createState() => _OpmlPageState();
}

class _OpmlPageState extends State<OpmlPage> {
  final _contents = TextEditingController();
  _OpmlAction? _busy;
  String? _message;
  bool _failed = false;
  List<({String feedUrl, String error})> _failedFeeds = const [];

  Future<void> _run(_OpmlAction action) async {
    if (_busy != null) return;
    final strings = context.strings;
    final contents = _contents.text.trim();
    if (action == _OpmlAction.import && contents.isEmpty) {
      setState(() {
        _failed = true;
        _message = strings.opmlInvalid;
        _failedFeeds = const [];
      });
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = action;
      _message = null;
      _failed = false;
      _failedFeeds = const [];
    });
    final services = widget.services;
    try {
      switch (action) {
        case _OpmlAction.import:
          final result = await services.api.importOpml(contents);
          _failedFeeds = result.failed;
          _failed = _failedFeeds.isNotEmpty;
          _message = strings.opmlSummary(
            result.added,
            result.existing,
            result.failed.length,
          );
          await services.sync.syncNow();
        case _OpmlAction.export:
          final data = await services.api.exportOpml();
          if (!mounted) return;
          await Clipboard.setData(ClipboardData(text: data));
          _message = strings.opmlCopied;
      }
    } on ApiException catch (error) {
      _failed = true;
      _message = error.statusCode == 400 || error.statusCode == 422
          ? strings.opmlInvalid
          : strings.opmlFailed;
    } on Exception {
      _failed = true;
      _message = strings.opmlFailed;
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  void dispose() {
    _contents.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(12),
          sliver: SliverList.list(
            children: [
              Text(strings.opmlHelp, style: buttonLabelStyle),
              const SizedBox(height: 12),
              LabeledField(
                label: strings.opmlContent,
                controller: _contents,
                enabled: _busy == null,
                lines: 4,
              ),
              EinkButton(
                _busy == _OpmlAction.import
                    ? strings.opmlImporting
                    : strings.opmlImport,
                primary: true,
                onPressed: () => _run(_OpmlAction.import),
              ),
              const SizedBox(height: 8),
              EinkButton(
                _busy == _OpmlAction.export
                    ? strings.opmlExporting
                    : strings.opmlExport,
                onPressed: () => _run(_OpmlAction.export),
              ),
              if (_message case final String message)
                _failed
                    ? EinkError(message, inset: true)
                    : PageMessage(message),
            ],
          ),
        ),
        SliverList.builder(
          itemCount: _failedFeeds.length,
          itemBuilder: (context, index) {
            final failure = _failedFeeds[index];
            return EinkRow(
              title: maskUrlCredentials(failure.feedUrl),
              details: [
                Text(maskUrlCredentials(failure.error), style: detailStyle),
              ],
            );
          },
        ),
      ],
    );
  }
}
