import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/models.dart';
import 'eink_widgets.dart';
import 'episode_text.dart';
import 'playback_actions.dart';
import 'theme.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, required this.playback, required this.onOpen});

  final PlaybackActions playback;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final episode = playback.target;
    if (episode == null) return const SizedBox.shrink();
    final strings = context.strings;
    final playing = playback.playing(episode.id);
    final checking = playback.checkingId != null;
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(width: 2)),
        ),
        child: SizedBox(
          height: 72,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: onOpen,
                    style: const ButtonStyle(
                      alignment: AlignmentDirectional.centerStart,
                      padding: WidgetStatePropertyAll(
                        EdgeInsets.symmetric(horizontal: 4),
                      ),
                    ),
                    child: Text(
                      checking
                          ? strings.checkingPosition
                          : playback.loading(episode.id)
                          ? strings.loadingPlayback
                          : episode.title,
                      style: buttonLabelStyle.merge(underlineStyle),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 84,
                  height: 58,
                  child: FilledButton(
                    onPressed: () => playback.toggle(),
                    style: const ButtonStyle(
                      padding: WidgetStatePropertyAll(
                        EdgeInsets.symmetric(horizontal: 4),
                      ),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          playing ? Icons.pause : Icons.play_arrow,
                          size: 24,
                        ),
                        Flexible(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              playing ? strings.pause : strings.play,
                              style: detailStyle,
                              maxLines: 1,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PlayerPage extends StatelessWidget {
  const PlayerPage({
    super.key,
    required this.playback,
    required this.onEpisode,
    required this.sleepAvailable,
  });

  final PlaybackActions playback;
  final ValueChanged<Episode> onEpisode;
  final bool sleepAvailable;

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    final episode = playback.target;
    if (episode == null) {
      return PageList(
        children: [
          if (playback.failed) ProblemBox(strings.playbackFailed),
          PageMessage(strings.noPlayback),
        ],
      );
    }
    final player = playback.services.player;
    final settings = playback.services.settings;
    final podcast = playback.services.library.podcast(episode.podcastId);
    final playing = playback.playing(episode.id);
    final sleepEnd = playback.sleepDeadline;
    final sleepOn = playback.sleepUntilEnd || sleepEnd != null;
    final sleepValue = sleepEnd != null
        ? strings.sleepUntil(clockText(strings, sleepEnd))
        : playback.sleepUntilEnd
        ? strings.sleepEndOfEpisode
        : strings.sleepOff;

    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (podcast != null)
                      Text(podcast.title, style: detailStyle),
                    TextButton(
                      onPressed: () => onEpisode(episode),
                      style: const ButtonStyle(
                        alignment: AlignmentDirectional.topStart,
                        padding: WidgetStatePropertyAll(EdgeInsets.zero),
                      ),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight:
                              MediaQuery.textScalerOf(context).scale(18) * 3.6,
                        ),
                        child: Text(
                          episode.title,
                          style: headingStyle.merge(underlineStyle),
                        ),
                      ),
                    ),
                    if (playback.failed) ProblemBox(strings.playbackFailed),
                    PlaybackTimeLine(
                      playback: playback,
                      episode: episode,
                      style: rowTitleStyle,
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 8,
                  children: [
                    EinkButton(
                      playLabel(context, playback, episode),
                      primary: true,
                      icon: playing ? Icons.pause : Icons.play_arrow,
                      minHeight: 64,
                      alternatives: [
                        strings.checkingPosition,
                        strings.play,
                        strings.pause,
                      ],
                      onPressed: () => playback.toggle(),
                    ),
                    Row(
                      spacing: 8,
                      children: [
                        Expanded(
                          child: EinkButton(
                            strings.skipBackValue(settings.skipBackSeconds),
                            minHeight: 56,
                            onPressed: () => playback.skip(
                              Duration(seconds: -settings.skipBackSeconds),
                            ),
                          ),
                        ),
                        Expanded(
                          child: EinkButton(
                            strings.skipForwardValue(
                              settings.skipForwardSeconds,
                            ),
                            minHeight: 56,
                            onPressed: () => playback.skip(
                              Duration(seconds: settings.skipForwardSeconds),
                            ),
                          ),
                        ),
                      ],
                    ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 8,
                      children: [
                        Expanded(
                          child: _PlayerOption(
                            title: strings.speed,
                            value: speedText(strings, player.speed),
                            onPressed: () =>
                                showSpeedChoices(context, playback),
                          ),
                        ),
                        if (sleepAvailable)
                          Expanded(
                            child: _PlayerOption(
                              title: strings.sleep,
                              value: sleepValue,
                              selected: sleepOn,
                              onPressed: () =>
                                  _showSleepChoices(context, playback),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String playLabel(
  BuildContext context,
  PlaybackActions playback,
  Episode episode, {
  bool showPosition = false,
}) {
  final strings = context.strings;
  if (playback.checkingId == episode.id) return strings.checkingPosition;
  if (playback.playing(episode.id)) return strings.pause;
  if (playback.loading(episode.id)) return strings.loadingPlayback;
  if (showPosition) {
    final state = playback.services.library.stateOf(episode.id);
    if (state.status == EpisodeStatus.none && state.positionMs > 0) {
      return strings.playFrom(
        positionText(Duration(milliseconds: state.positionMs)),
      );
    }
  }
  return strings.play;
}

class _PlayerOption extends StatelessWidget {
  const _PlayerOption({
    required this.title,
    required this.value,
    this.selected = false,
    required this.onPressed,
  });

  final String title;
  final String value;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton(
    onPressed: onPressed,
    style: choiceButtonStyle(selected: selected).copyWith(
      minimumSize: const WidgetStatePropertyAll(Size(48, 64)),
      padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: detailStyle, textAlign: TextAlign.center),
        Text(
          value,
          style: buttonLabelStyle.copyWith(fontWeight: FontWeight.w700),
          textAlign: TextAlign.center,
        ),
      ],
    ),
  );
}

class DesktopPlayer extends StatelessWidget {
  const DesktopPlayer({
    super.key,
    required this.playback,
    required this.onEpisode,
  });

  final PlaybackActions playback;
  final ValueChanged<Episode> onEpisode;

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    final settings = playback.services.settings;
    final episode = playback.target;
    final playing = episode != null && playback.playing(episode.id);
    final podcast = episode == null
        ? null
        : playback.services.library.podcast(episode.podcastId);
    final speed = strings.desktopSpeed(
      speedText(strings, playback.services.player.speed),
    );
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(width: 2)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 88),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            spacing: 12,
            children: [
              EinkButton(
                strings.skipBackValue(settings.skipBackSeconds),
                minHeight: 56,
                onPressed: episode == null
                    ? null
                    : () => playback.skip(
                        Duration(seconds: -settings.skipBackSeconds),
                      ),
              ),
              EinkButton(
                playing ? strings.pause : strings.play,
                primary: true,
                icon: playing ? Icons.pause : Icons.play_arrow,
                minHeight: 56,
                onPressed: episode == null ? null : () => playback.toggle(),
              ),
              EinkButton(
                strings.skipForwardValue(settings.skipForwardSeconds),
                minHeight: 56,
                onPressed: episode == null
                    ? null
                    : () => playback.skip(
                        Duration(seconds: settings.skipForwardSeconds),
                      ),
              ),
              Expanded(
                child: episode == null
                    ? Text(strings.noPlayback, style: detailStyle)
                    : TextButton(
                        style: const ButtonStyle(
                          alignment: AlignmentDirectional.centerStart,
                          padding: WidgetStatePropertyAll(EdgeInsets.all(6)),
                        ),
                        onPressed: () => onEpisode(episode),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              playback.checkingId != null
                                  ? strings.checkingPosition
                                  : episode.title,
                              style: buttonLabelStyle
                                  .merge(underlineStyle)
                                  .copyWith(fontWeight: FontWeight.w700),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            PlaybackTimeLine(
                              playback: playback,
                              episode: episode,
                              prefix: podcast?.title,
                              style: detailStyle,
                            ),
                          ],
                        ),
                      ),
              ),
              Flexible(
                flex: 0,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 205),
                  child: EinkButton(
                    speed,
                    minHeight: 56,
                    onPressed: () => showSpeedChoices(context, playback),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PlaybackTimeLine extends StatefulWidget {
  const PlaybackTimeLine({
    super.key,
    required this.playback,
    required this.episode,
    required this.style,
    this.prefix,
  });

  final PlaybackActions playback;
  final Episode episode;
  final TextStyle style;
  final String? prefix;

  @override
  State<PlaybackTimeLine> createState() => _PlaybackTimeLineState();
}

class _PlaybackTimeLineState extends State<PlaybackTimeLine>
    with WidgetsBindingObserver {
  late (Duration, Duration?) _time;
  Timer? _timer;

  bool get _isCurrent =>
      widget.playback.services.player.current?.id == widget.episode.id;

  (Duration, Duration?) _read() {
    final services = widget.playback.services;
    final state = services.library.stateOf(widget.episode.id);
    return _isCurrent
        ? (
            services.player.position.value,
            services.player.duration ?? episodeDuration(widget.episode, state),
          )
        : (
            Duration(milliseconds: state.positionMs),
            episodeDuration(widget.episode, state),
          );
  }

  @override
  void initState() {
    super.initState();
    _time = _read();
    WidgetsBinding.instance.addObserver(this);
    _attach();
    _schedule();
  }

  void _attach() {
    widget.playback.services.player.addListener(_playerChanged);
    widget.playback.interaction.addListener(_sample);
  }

  void _detach(PlaybackActions playback) {
    playback.services.player.removeListener(_playerChanged);
    playback.interaction.removeListener(_sample);
  }

  @override
  void didUpdateWidget(PlaybackTimeLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newPlayback = oldWidget.playback != widget.playback;
    if (newPlayback) {
      _detach(oldWidget.playback);
      _attach();
    }
    if (newPlayback ||
        oldWidget.episode.id != widget.episode.id ||
        !_isCurrent) {
      _time = _read();
    }
    _schedule();
  }

  void _sample() {
    if (!mounted) return;
    final next = _read();
    if (next != _time) setState(() => _time = next);
  }

  void _playerChanged() {
    _schedule();
    scheduleMicrotask(_sample);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _schedule();
    if (state == AppLifecycleState.resumed) _sample();
  }

  void _schedule() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (widget.playback.playing(widget.episode.id) &&
        (lifecycle == null ||
            lifecycle == AppLifecycleState.resumed ||
            lifecycle == AppLifecycleState.inactive)) {
      _timer ??= Timer.periodic(const Duration(minutes: 1), (_) => _sample());
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _detach(widget.playback);
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = playbackTime(
      context.strings,
      _time.$1,
      _time.$2,
      showTotal: true,
    );
    final prefix = widget.prefix;
    return RepaintBoundary(
      child: Text(
        prefix == null ? text : '$prefix$metadataSeparator$text',
        style: widget.style,
      ),
    );
  }
}

Future<void> showSpeedChoices(
  BuildContext context,
  PlaybackActions playback,
) async {
  final strings = context.strings;
  const values = [0.8, 1.0, 1.1, 1.2, 1.3, 1.5, 1.7, 2.0];
  playback.refreshTime();
  final result = await showEinkDialog<double>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => EinkDialogPanel(
      title: strings.speed,
      message: strings.speedHelp,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(strings.close, style: buttonLabelStyle),
        ),
      ],
      children: [
        _ChoiceGrid(
          choices: [
            for (final value in values)
              EinkButton(
                speedText(strings, value),
                selected: playback.services.player.speed == value,
                onPressed: () => Navigator.pop(dialogContext, value),
              ),
          ],
        ),
      ],
    ),
  );
  if (result != null) await playback.speed(result);
}

enum _SleepChoice {
  off(null),
  quarter(15),
  half(30),
  threeQuarters(45),
  hour(60),
  end(null);

  const _SleepChoice(this.minutes);
  final int? minutes;
}

Future<void> _showSleepChoices(
  BuildContext context,
  PlaybackActions playback,
) async {
  final strings = context.strings;
  final deadline = playback.sleepDeadline;
  final endTime = deadline == null ? null : clockText(strings, deadline);
  final message = playback.sleepUntilEnd
      ? (endTime == null
            ? strings.sleepEndHelp
            : strings.sleepEndEstimate(endTime))
      : (endTime == null
            ? strings.sleepOffHelp
            : strings.sleepUntilHelp(endTime));
  playback.refreshTime();
  final result = await showEinkDialog<_SleepChoice>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => EinkDialogPanel(
      title: strings.sleep,
      message: message,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(strings.close, style: buttonLabelStyle),
        ),
      ],
      children: [
        _ChoiceGrid(
          choices: [
            for (final choice in _SleepChoice.values)
              EinkButton(
                switch (choice) {
                  _SleepChoice.off => strings.sleepOff,
                  _SleepChoice.end => strings.sleepEndOfEpisode,
                  _ => strings.minutes(choice.minutes!),
                },
                selected: switch (choice) {
                  _SleepChoice.off =>
                    !playback.sleepUntilEnd && deadline == null,
                  _SleepChoice.end => playback.sleepUntilEnd,
                  _ => playback.sleepMinutes == choice.minutes,
                },
                onPressed: () => Navigator.pop(dialogContext, choice),
              ),
          ],
        ),
      ],
    ),
  );
  if (result != null) {
    await playback.setSleep(
      minutes: result.minutes,
      endOfEpisode: result == _SleepChoice.end,
    );
  }
}

class _ChoiceGrid extends StatelessWidget {
  const _ChoiceGrid({required this.choices});

  final List<Widget> choices;

  @override
  Widget build(BuildContext context) => Column(
    spacing: 8,
    children: [
      for (var i = 0; i < choices.length; i += 2)
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 8,
            children: [
              Expanded(child: choices[i]),
              Expanded(child: choices[i + 1]),
            ],
          ),
        ),
    ],
  );
}
