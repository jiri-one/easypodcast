import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/models.dart';
import '../core/player.dart';
import 'cover_image.dart';
import 'eink_widgets.dart';
import 'episode_text.dart';
import 'playback_actions.dart';
import 'playback_position.dart';
import 'sync_feedback.dart';
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
    final checking = !playing && playback.checkingId != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PlaybackProblem(playback: playback),
        RepaintBoundary(
          child: Stack(
            children: [
              SizedBox(
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
                                : !playing && playback.loading(episode.id)
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
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: IgnorePointer(
                  child: PlaybackPositionView(
                    playback: playback,
                    episode: episode,
                    redrawSeconds:
                        playback.services.settings.positionRedrawSeconds,
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
        SyncFeedback.of(context).offline &&
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
    if (error == null) return ProblemBox(reason);
    return Padding(
      padding: const EdgeInsets.all(8),
      child: DefaultTextStyle.merge(
        style: detailStyle,
        child: EinkError(
          '${error.episode.title}\n$reason',
          action: EinkButton(strings.retry, onPressed: playback.retry),
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
    required this.redrawSeconds,
  });

  final PlaybackActions playback;
  final ValueChanged<Episode> onEpisode;
  final bool sleepAvailable;
  final int redrawSeconds;

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
    final sleepEnd = playback.sleepDeadline;
    final sleepOn = playback.sleepUntilEnd || sleepEnd != null;
    final sleepValue = playback.sleepUntilEnd
        ? strings.sleepEndValue
        : sleepEnd != null
        ? strings.sleepUntil(clockText(strings, sleepEnd))
        : strings.sleepOff;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: CustomMultiChildLayout(
        delegate: _PlayerLayout(),
        children: [
          if (covers.isNotEmpty)
            LayoutId(
              id: _PlayerPart.cover,
              child: _PlayerCover(urls: covers),
            ),
          LayoutId(
            id: _PlayerPart.controls,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 6,
                children: [
                  TextButton(
                    onPressed: () => onEpisode(episode),
                    style: const ButtonStyle(
                      alignment: AlignmentDirectional.centerStart,
                      padding: WidgetStatePropertyAll(EdgeInsets.zero),
                    ),
                    child: Text(
                      episode.title,
                      style: headingStyle.merge(underlineStyle),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (services.player.lastPlaybackError != null ||
                      playback.failed)
                    PlaybackProblem(playback: playback),
                  PlaybackTimeline(
                    key: ValueKey(episode.id),
                    playback: playback,
                    episode: episode,
                    redrawSeconds: redrawSeconds,
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: _SkipControl(
                          seconds: -settings.skipBackSeconds,
                          onPressed: () => playback.skip(
                            Duration(seconds: -settings.skipBackSeconds),
                          ),
                        ),
                      ),
                      SizedBox.square(
                        dimension: 76,
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
                      Expanded(
                        child: _SkipControl(
                          seconds: settings.skipForwardSeconds,
                          onPressed: () => playback.skip(
                            Duration(seconds: settings.skipForwardSeconds),
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (playback.seekUnavailable)
                    Semantics(
                      liveRegion: true,
                      child: Text(strings.seekUnavailable, style: detailStyle),
                    ),
                  Text(
                    playText,
                    textAlign: TextAlign.center,
                    style: detailStyle,
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 8,
                    children: [
                      Expanded(
                        child: _PlayerOption(
                          title: strings.speed,
                          value: speedText(strings, services.player.speed),
                          onPressed: () => showSpeedChoices(context, playback),
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
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _PlayerPart { cover, controls }

class _PlayerLayout extends MultiChildLayoutDelegate {
  @override
  void performLayout(Size size) {
    final controls = layoutChild(
      _PlayerPart.controls,
      BoxConstraints.tightFor(width: size.width)
          .copyWith(maxHeight: size.height),
    );
    var top = 0.0;
    if (hasChild(_PlayerPart.cover)) {
      final side = math.min(
        size.width,
        math.max(0.0, size.height - controls.height - 8),
      );
      final cover = layoutChild(
        _PlayerPart.cover,
        BoxConstraints.loose(Size.square(side)),
      );
      positionChild(
        _PlayerPart.cover,
        Offset((size.width - cover.width) / 2, 0),
      );
      if (cover.height > 0) top = cover.height + 8;
    }
    positionChild(_PlayerPart.controls, Offset(0, top));
  }

  @override
  bool shouldRelayout(_PlayerLayout oldDelegate) => false;
}

List<String> _coverUrls(Episode episode, Podcast? podcast) => [
  for (final url in {?episode.imageUrl?.trim(), ?podcast?.imageUrl?.trim()})
    if (Uri.tryParse(url) case final Uri uri
        when uri.hasAuthority &&
            (uri.scheme == 'https' || uri.scheme == 'http'))
      url,
];

class _PlayerCover extends StatelessWidget {
  const _PlayerCover({required this.urls});

  final List<String> urls;

  static const _grayscale = ColorFilter.matrix([
    0.2126,
    0.7152,
    0.0722,
    0,
    0,
    0.2126,
    0.7152,
    0.0722,
    0,
    0,
    0.2126,
    0.7152,
    0.0722,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ]);

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final side = math.min(bounds.maxWidth, bounds.maxHeight);
      if (side < 1) return const SizedBox.shrink();
      final pixels = math.max(
        1,
        (side * MediaQuery.devicePixelRatioOf(context)).round(),
      );
      Widget cover(int index) => Image(
        image: ResizeImage(
          CoverImage(urls[index]),
          width: pixels,
          height: pixels,
          policy: ResizeImagePolicy.fit,
        ),
        width: side,
        height: side,
        fit: BoxFit.cover,
        excludeFromSemantics: true,
        frameBuilder: (context, child, frame, synchronous) => DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: const BoxDecoration(
            border: Border.fromBorderSide(BorderSide()),
          ),
          child: ColorFiltered(colorFilter: _grayscale, child: child),
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
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(quickBack ? Icons.replay : Icons.rotate_right, size: 24),
          Text(
            quickBack
                ? strings.skipBackValue(-seconds)
                : strings.skipForwardValue(seconds),
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
    required this.redrawSeconds,
  });

  final PlaybackActions playback;
  final ValueChanged<Episode> onEpisode;
  final int redrawSeconds;

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    final settings = playback.services.settings;
    final episode = playback.target;
    final playing = episode != null && playback.playing(episode.id);
    final podcast = episode == null
        ? null
        : playback.services.library.podcast(episode.podcastId);
    final covers = episode == null
        ? const <String>[]
        : _coverUrls(episode, podcast);
    final buttons = [
      EinkButton(
        strings.skipBackValue(settings.skipBackSeconds),
        minHeight: 56,
        onPressed: episode == null
            ? null
            : () => playback.skip(Duration(seconds: -settings.skipBackSeconds)),
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
        minHeight: 56,
        onPressed: episode == null
            ? null
            : () =>
                  playback.skip(Duration(seconds: settings.skipForwardSeconds)),
      ),
      EinkButton(
        strings.desktopSpeed(
          speedText(strings, playback.services.player.speed),
        ),
        minHeight: 56,
        onPressed: () => showSpeedChoices(context, playback),
      ),
    ];
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
                  redrawSeconds: redrawSeconds,
                ),
              if (playback.seekUnavailable)
                Semantics(
                  liveRegion: true,
                  child: Text(strings.seekUnavailable, style: detailStyle),
                ),
              LayoutBuilder(
                builder: (context, bounds) {
                  if (bounds.maxWidth < 800) {
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
                          ],
                        ),
                      ],
                    );
                  }
                  return Row(
                    spacing: 8,
                    children: [
                      for (final button in buttons.take(3))
                        Expanded(child: button),
                      Expanded(flex: 3, child: heading),
                      Expanded(child: buttons.last),
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
      ? strings.sleepEndHelp
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
