import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/models.dart';
import '../core/player.dart';
import '../core/sync.dart';
import 'cover_image.dart';
import 'eink_widgets.dart';
import 'episode_text.dart';
import 'playback_actions.dart';
import 'playback_position.dart';
import 'theme.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, required this.playback, required this.onOpen});

  final PlaybackActions playback;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final episode = playback.target;
    if (episode == null) return PlaybackProblem(playback: playback);
    final strings = context.strings;
    final playing = playback.playing(episode.id);
    final checking =
        !playing && playback.services.player.checkingPosition != null;
    final playPause = FilledButton(
      onPressed: () => playback.toggle(),
      style: const ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size(84, 58)),
        padding: WidgetStatePropertyAll(EdgeInsets.all(4)),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(playing ? Icons.pause : Icons.play_arrow, size: 24),
          IndexedStack(
            alignment: Alignment.center,
            index: playing ? 1 : 0,
            children: [
              Text(strings.play, style: buttonLabelStyle),
              Text(strings.pause, style: buttonLabelStyle),
            ],
          ),
        ],
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PlaybackProblem(playback: playback),
        RepaintBoundary(
          child: Stack(
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 72),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: LayoutBuilder(
                    builder: (context, bounds) => Row(
                      spacing: 8,
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
                                  : !playing && playback.loading(episode.id)
                                  ? strings.loadingPlayback
                                  : episode.title,
                              style: buttonLabelStyle.merge(underlineStyle),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: bounds.maxWidth * 0.4,
                          ),
                          child: playPause,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: IgnorePointer(
                  child: PlaybackPositionView(
                    playback: playback,
                    episode: episode,
                    key: ValueKey(episode.id),
                    sparse: true,
                    builder: (context, elapsed, duration) => SizedBox(
                      height: 3,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          const Align(
                            alignment: Alignment.bottomCenter,
                            child: SizedBox(
                              width: double.infinity,
                              height: 1,
                              child: ColoredBox(color: Colors.black),
                            ),
                          ),
                          FractionallySizedBox(
                            key: const ValueKey('mini-progress'),
                            alignment: Alignment.centerLeft,
                            widthFactor: playedFraction(elapsed, duration),
                            child: const ColoredBox(color: Colors.black),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class PlaybackProblem extends StatelessWidget {
  const PlaybackProblem({super.key, required this.playback, this.episodeId});

  final PlaybackActions playback;
  final int? episodeId;

  @override
  Widget build(BuildContext context) {
    final services = playback.services;
    final error = services.player.lastPlaybackError;
    final id = error?.episode.id ?? playback.failedEpisodeId;
    if ((error == null && !playback.failed) ||
        (episodeId != null && episodeId != id)) {
      return const SizedBox.shrink();
    }
    final strings = context.strings;
    final offline =
        id != null &&
        services.sync.status.value.phase == SyncPhase.offline &&
        services.downloads.localFileOf(id) == null;
    final reason = switch (error?.reason) {
      PlaybackErrorReason.loadFailed =>
        offline ? strings.playbackOffline : strings.playbackLoadFailed,
      PlaybackErrorReason.streamFailed =>
        offline ? strings.playbackOffline : strings.playbackStreamFailed,
      PlaybackErrorReason.seekFailed => strings.playbackSeekFailed,
      PlaybackErrorReason.audioFocusUnavailable =>
        strings.playbackFocusUnavailable,
      null =>
        offline && playback.failedPlaying
            ? strings.playbackOffline
            : strings.playbackFailed,
    };
    return EinkError(
      error == null ? reason : '${error.episode.title}\n$reason',
      inset: true,
      action: error == null
          ? null
          : EinkButton(strings.retry, onPressed: playback.retry),
    );
  }
}

const _playControlSize = 76.0;

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
          PlaybackProblem(playback: playback),
          if (playback.seekUnavailable) PageMessage(strings.seekUnavailable),
          PageMessage(strings.noPlayback),
        ],
      );
    }
    final services = playback.services;
    final settings = services.settings;
    final podcast = services.library.podcast(episode.podcastId);
    final next = services.library.queue
        .where((item) => item.id != episode.id)
        .firstOrNull;
    final covers = _coverUrls(episode, podcast);
    final playing = playback.playing(episode.id);
    final playText = playLabel(context, playback, episode);
    final player = services.player;
    final sleepEnd = player.sleepDeadline;
    final sleepOn = player.sleepAtEndOfEpisode || sleepEnd != null;
    final sleepValue = player.sleepAtEndOfEpisode
        ? strings.sleepEndValue
        : sleepEnd != null
        ? strings.sleepUntil(clockText(strings, sleepEnd))
        : strings.sleepOff;

    final controls = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 6,
      children: [
        TextButton(
          onPressed: () => onEpisode(episode),
          style: const ButtonStyle(
            alignment: AlignmentDirectional.centerStart,
            padding: WidgetStatePropertyAll(EdgeInsets.zero),
          ),
          child: Text(episode.title, style: headingStyle.merge(underlineStyle)),
        ),
        if (services.player.lastPlaybackError != null || playback.failed)
          PlaybackProblem(playback: playback),
        PlaybackTimeline(
          key: ValueKey(episode.id),
          playback: playback,
          episode: episode,
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: _SkipControl(
                seconds: -settings.skipBackSeconds,
                onPressed: playback.skipBack,
              ),
            ),
            Expanded(
              flex: 4,
              child: Column(
                spacing: 6,
                children: [
                  SizedBox.square(
                    dimension: _playControlSize,
                    child: FilledButton(
                      onPressed: () => playback.toggle(),
                      style: const ButtonStyle(
                        shape: WidgetStatePropertyAll(CircleBorder()),
                        padding: WidgetStatePropertyAll(EdgeInsets.zero),
                      ),
                      child: Icon(
                        playing ? Icons.pause : Icons.play_arrow,
                        size: 38,
                        semanticLabel: playText,
                      ),
                    ),
                  ),
                  Text(
                    playText,
                    textAlign: TextAlign.center,
                    style: buttonLabelStyle,
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 3,
              child: _SkipControl(
                seconds: settings.skipForwardSeconds,
                onPressed: playback.skipForward,
              ),
            ),
          ],
        ),
        if (playback.seekUnavailable)
          Semantics(
            liveRegion: true,
            child: Text(strings.seekUnavailable, style: detailStyle),
          ),
        if (settings.showSpeedAndSleep)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: [
              Expanded(
                child: _PlayerOption(
                  title: strings.speed,
                  value: speedText(strings, player.speed),
                  onPressed: () => showSpeedChoices(context, playback),
                ),
              ),
              if (sleepAvailable)
                Expanded(
                  child: _PlayerOption(
                    title: strings.sleep,
                    value: sleepValue,
                    selected: sleepOn,
                    onPressed: () => _showSleepChoices(context, playback),
                  ),
                ),
            ],
          ),
        if (next != null)
          TextButton(
            onPressed: () => onEpisode(next),
            style: const ButtonStyle(
              alignment: AlignmentDirectional.centerStart,
              padding: WidgetStatePropertyAll(EdgeInsets.zero),
            ),
            child: Text(
              strings.nextInQueue(next.title),
              style: buttonLabelStyle.merge(underlineStyle),
            ),
          ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: LayoutBuilder(
        builder: (context, bounds) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (covers.isNotEmpty)
              Flexible(
                child: Align(
                  alignment: Alignment.topCenter,
                  heightFactor: 1,
                  child: _PlayerCover(urls: covers, bottomGap: 8),
                ),
              ),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: bounds.maxHeight),
              child: SingleChildScrollView(child: controls),
            ),
          ],
        ),
      ),
    );
  }
}

List<String> _coverUrls(Episode episode, Podcast? podcast) => {
  ?validCoverUrl(episode.imageUrl),
  ?validCoverUrl(podcast?.imageUrl),
}.toList();

class _PlayerCover extends StatelessWidget {
  const _PlayerCover({required this.urls, this.bottomGap = 0});

  final List<String> urls;
  final double bottomGap;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final side = math.min(bounds.maxWidth, bounds.maxHeight - bottomGap);
      if (side < 1) return const SizedBox.shrink();
      Widget cover(int index) => Image(
        image: CoverImage(urls[index])
            .resized(side, MediaQuery.devicePixelRatioOf(context)),
        width: side,
        height: side,
        fit: BoxFit.cover,
        excludeFromSemantics: true,
        frameBuilder: (context, child, frame, synchronous) => Padding(
          padding: EdgeInsets.only(bottom: bottomGap),
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: const BoxDecoration(
              border: Border.fromBorderSide(BorderSide()),
            ),
            child: ColorFiltered(colorFilter: coverGrayscale, child: child),
          ),
        ),
        errorBuilder: (context, error, stack) => index + 1 < urls.length
            ? cover(index + 1)
            : const SizedBox.shrink(),
      );
      return cover(0);
    },
  );
}

class _SkipControl extends StatelessWidget {
  const _SkipControl({required this.seconds, required this.onPressed});

  final int seconds;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final quickBack = seconds < 0;
    final strings = context.strings;
    return TextButton(
      onPressed: onPressed,
      style: const ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size(64, 64)),
        // Narrow e-ink phones need the room for "−15 s" in large text.
        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 4)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: [
          SizedBox.square(
            dimension: _playControlSize,
            child: Container(
              margin: const EdgeInsets.all(8),
              alignment: Alignment.center,
              decoration: const ShapeDecoration(
                color: Colors.white,
                shape: CircleBorder(side: BorderSide(width: 2)),
              ),
              child: Icon(
                quickBack ? Icons.fast_rewind : Icons.fast_forward,
                color: Colors.black,
                size: 30,
              ),
            ),
          ),
          Text(
            quickBack
                ? strings.skipBackValue(-seconds)
                : strings.skipForwardValue(seconds),
            textAlign: TextAlign.center,
            style: buttonLabelStyle,
          ),
        ],
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
  if (playback.services.player.checkingPosition == episode.id) {
    return strings.checkingPosition;
  }
  if (playback.playing(episode.id)) return strings.pause;
  if (playback.loading(episode.id)) return strings.loadingPlayback;
  if (showPosition) {
    final state = playback.services.library.stateOf(episode.id);
    final position = state.resumePosition;
    if (position > Duration.zero) {
      return strings.playFrom(positionText(position));
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
    final labelScale =
        MediaQuery.textScalerOf(context).scale(einkButtonFontSize) /
        einkButtonFontSize;
    final covers = episode == null
        ? const <String>[]
        : _coverUrls(episode, podcast);
    final buttons = [
      EinkButton(
        strings.skipBackValue(settings.skipBackSeconds),
        icon: Icons.fast_rewind,
        minHeight: 56,
        onPressed: episode == null ? null : playback.skipBack,
      ),
      EinkButton(
        episode == null ? strings.play : playLabel(context, playback, episode),
        primary: true,
        icon: playing ? Icons.pause : Icons.play_arrow,
        minHeight: 56,
        onPressed: episode == null ? null : () => playback.toggle(),
      ),
      EinkButton(
        strings.skipForwardValue(settings.skipForwardSeconds),
        icon: Icons.fast_forward,
        minHeight: 56,
        onPressed: episode == null ? null : playback.skipForward,
      ),
    ];
    final speedButton = settings.showSpeedAndSleep
        ? EinkButton(
            strings.desktopSpeed(
              speedText(strings, playback.services.player.speed),
            ),
            minHeight: 56,
            onPressed: () => showSpeedChoices(context, playback),
          )
        : null;
    final heading = Row(
      spacing: 6,
      children: [
        if (covers.isNotEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 52, maxHeight: 52),
            child: _PlayerCover(urls: covers),
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
                        episode.title,
                        style: buttonLabelStyle
                            .merge(underlineStyle)
                            .copyWith(fontWeight: FontWeight.w700),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (podcast != null)
                        Text(
                          podcast.title,
                          style: detailStyle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(width: 2)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 88),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 4,
            children: [
              if (playback.services.player.lastPlaybackError != null ||
                  playback.failed)
                PlaybackProblem(playback: playback),
              if (episode != null)
                PlaybackTimeline(
                  key: ValueKey(episode.id),
                  playback: playback,
                  episode: episode,
                ),
              if (playback.seekUnavailable)
                Semantics(
                  liveRegion: true,
                  child: Text(strings.seekUnavailable, style: detailStyle),
                ),
              LayoutBuilder(
                builder: (context, bounds) {
                  if (bounds.maxWidth < 800 * math.max(1.0, labelScale)) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      spacing: 4,
                      children: [
                        heading,
                        Row(
                          spacing: 8,
                          children: [
                            for (final button in buttons)
                              Expanded(child: button),
                            if (speedButton != null)
                              Expanded(child: speedButton),
                          ],
                        ),
                      ],
                    );
                  }
                  return Row(
                    spacing: 8,
                    children: [
                      for (final button in buttons) Expanded(child: button),
                      Expanded(flex: 3, child: heading),
                      if (speedButton != null) Expanded(child: speedButton),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
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
  final result = await showChoices(
    context,
    title: strings.speed,
    message: strings.speedHelp,
    choices: [
      for (final value in values)
        (
          value: value,
          label: speedText(strings, value),
          selected: playback.services.player.speed == value,
        ),
    ],
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
  final player = playback.services.player;
  final deadline = player.sleepDeadline;
  final endTime = deadline == null ? null : clockText(strings, deadline);
  final message = player.sleepAtEndOfEpisode
      ? strings.sleepEndHelp
      : (endTime == null
            ? strings.sleepOffHelp
            : strings.sleepUntilHelp(endTime));
  playback.refreshTime();
  final result = await showChoices(
    context,
    title: strings.sleep,
    message: message,
    choices: [
      for (final choice in _SleepChoice.values)
        (
          value: choice,
          label: switch (choice) {
            _SleepChoice.off => strings.sleepOff,
            _SleepChoice.end => strings.sleepEndOfEpisode,
            _ => strings.minutes(choice.minutes!),
          },
          selected: switch (choice) {
            _SleepChoice.off => !player.sleepAtEndOfEpisode && deadline == null,
            _SleepChoice.end => player.sleepAtEndOfEpisode,
            _ => player.sleepDuration?.inMinutes == choice.minutes,
          },
        ),
    ],
  );
  if (result != null) {
    await playback.setSleep(
      minutes: result.minutes,
      endOfEpisode: result == _SleepChoice.end,
    );
  }
}
