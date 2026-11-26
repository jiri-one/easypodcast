import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/api.dart';
import '../core/models.dart';
import '../core/services.dart';
import '../core/sync.dart';
import 'eink_widgets.dart';
import 'episode_text.dart';
import 'plain_links.dart';
import 'playback_actions.dart';
import 'player_views.dart';
import 'theme.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.playback,
    required this.alphabetical,
    required this.preferencesFailed,
    required this.onAlphabetical,
    required this.redrawSeconds,
    required this.onRedrawSeconds,
    required this.downloadsAvailable,
    required this.onServer,
    required this.onFeeds,
    required this.onOpml,
  });

  final PlaybackActions playback;
  final bool alphabetical;
  final bool preferencesFailed;
  final VoidCallback onAlphabetical;
  final int redrawSeconds;
  final ValueChanged<int> onRedrawSeconds;
  final bool downloadsAvailable;
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
        EinkRow(
          title: strings.server,
          details: [ServerStatusLine(services: services)],
          trailing: const Icon(Icons.chevron_right),
          onPressed: onServer,
        ),
        _ToggleRow(
          title: strings.continueQueue,
          description: settings.autoplayQueue
              ? strings.continueQueueOn
              : strings.continueQueueOff,
          value: settings.autoplayQueue,
          onPressed: () => settings.autoplayQueue = !settings.autoplayQueue,
        ),
        EinkRow(
          title: strings.speed,
          details: [
            Text(speedText(strings, services.player.speed), style: detailStyle),
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
        if (downloadsAvailable)
          _SecondsRow(
            title: strings.playerRedraw,
            options: const [1, 10, 60],
            value: redrawSeconds,
            onChange: onRedrawSeconds,
            showMinute: true,
          ),
        if (downloadsAvailable) ...[
          _ToggleRow(
            title: strings.downloadWifi,
            value: settings.downloadOnWifiOnly,
            onPressed: () =>
                settings.downloadOnWifiOnly = !settings.downloadOnWifiOnly,
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
          value: alphabetical,
          onPressed: onAlphabetical,
        ),
        if (preferencesFailed) ProblemBox(strings.actionFailed),
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
    this.showMinute = false,
  });

  final String title;
  final List<int> options;
  final int value;
  final ValueChanged<int> onChange;
  final bool showMinute;

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
                        showMinute && seconds == 60
                            ? strings.minutes(1)
                            : strings.seconds(seconds),
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
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: services.sync.status,
    builder: (context, status, _) {
      final strings = context.strings;
      final problem = switch (status.phase) {
        SyncPhase.offline => strings.offline,
        SyncPhase.error => strings.syncError,
        _ => null,
      };
      if (problem != null) {
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: DefaultTextStyle.merge(
            style: detailStyle,
            child: EinkError(problem),
          ),
        );
      }
      return Text(strings.serverConnected, style: detailStyle);
    },
  );
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
    final settings = widget.services.settings;
    return PageList(
      children: [
        EinkRow(
          title: strings.serverAddress,
          details: [
            Text(settings.serverUrl, style: detailStyle),
            ServerStatusLine(services: widget.services),
          ],
        ),
        if (settings.deviceName.isNotEmpty)
          EinkRow(
            title: strings.deviceName,
            details: [Text(settings.deviceName, style: detailStyle)],
          ),
        PageMessage(strings.serverChangeHelp),
        if (_failed) ProblemBox(strings.actionFailed),
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

class AboutPodcastPage extends StatefulWidget {
  const AboutPodcastPage({
    super.key,
    required this.services,
    required this.podcast,
  });

  final AppServices services;
  final Podcast podcast;

  @override
  State<AboutPodcastPage> createState() => _AboutPodcastPageState();
}

class _AboutPodcastPageState extends State<AboutPodcastPage> {
  bool _working = false;
  bool _failed = false;

  Future<void> _unsubscribe() async {
    if (_working) return;
    setState(() {
      _working = true;
      _failed = false;
    });
    try {
      await widget.services.library.unsubscribe(widget.podcast.id);
    } on Exception {
      _failed = true;
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    final podcast = widget.podcast;
    return PageList(
      inset: true,
      children: [
        Text(podcast.title, style: headingStyle),
        if (podcast.author.isNotEmpty) Text(podcast.author, style: detailStyle),
        if (podcast.description.isNotEmpty) ...[
          const SizedBox(height: 12),
          PlainLinks(podcast.description, style: buttonLabelStyle),
        ],
        const SizedBox(height: 12),
        Text(strings.feedAddress, style: buttonLabelStyle),
        PlainLinks(podcast.feedUrl),
        const SizedBox(height: 8),
        FeedStatusText(podcast),
        const SizedBox(height: 16),
        if (_failed) ProblemBox(strings.actionFailed),
        if (podcast.subscribed) ...[
          Text(strings.unsubscribeHelp, style: detailStyle),
          const SizedBox(height: 8),
          EinkButton(
            _working ? strings.unsubscribing : strings.unsubscribe,
            onPressed: _unsubscribe,
          ),
        ] else
          Text(strings.notSubscribed, style: buttonLabelStyle),
      ],
    );
  }
}

class FeedStatusText extends StatelessWidget {
  const FeedStatusText(this.podcast, {super.key});

  final Podcast podcast;

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    final time = podcast.lastSuccessAt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 4,
      children: [
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
            child: EinkError('${strings.feedUnavailable} $error'),
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
      itemCount: podcasts.length,
      itemBuilder: (context, index) {
        final podcast = podcasts[index];
        return EinkRow(
          title: podcast.title,
          details: [FeedStatusText(podcast)],
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

  Future<void> _run(_OpmlAction action) async {
    if (_busy != null) return;
    final strings = context.strings;
    final contents = _contents.text.trim();
    if (action == _OpmlAction.import && contents.isEmpty) {
      setState(() {
        _failed = true;
        _message = strings.opmlInvalid;
      });
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = action;
      _message = null;
      _failed = false;
    });
    final services = widget.services;
    try {
      switch (action) {
        case _OpmlAction.import:
          final result = await services.api.importOpml(contents);
          _failed = result.failed.isNotEmpty;
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
    return PageList(
      inset: true,
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
          _failed ? ProblemBox(message) : PageMessage(message),
      ],
    );
  }
}
