import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import '../core/models.dart';
import 'eink_widgets.dart';
import 'episode_text.dart';
import 'playback_actions.dart';

class PlaybackPositionView extends StatefulWidget {
  const PlaybackPositionView({
    super.key,
    required this.playback,
    required this.episode,
    required this.redrawSeconds,
    required this.builder,
  });

  final PlaybackActions playback;
  final Episode episode;
  final int redrawSeconds;
  final Widget Function(BuildContext, Duration, Duration?) builder;

  @override
  State<PlaybackPositionView> createState() => _PlaybackPositionViewState();
}

class _PlaybackPositionViewState extends State<PlaybackPositionView>
    with WidgetsBindingObserver {
  late (Duration, Duration?) _time;
  Timer? _timer;
  bool _visible = true;

  bool get _isCurrent =>
      widget.playback.services.player.current?.id == widget.episode.id;

  (Duration, Duration?) _read() {
    final services = widget.playback.services;
    final state = services.library.stateOf(widget.episode.id);
    final duration = episodeDuration(widget.episode, state);
    return _isCurrent
        ? (services.player.position.value, services.player.duration ?? duration)
        : (Duration(milliseconds: state.positionMs), duration);
  }

  @override
  void initState() {
    super.initState();
    _time = _read();
    WidgetsBinding.instance.addObserver(this);
    _listen(widget.playback);
    _schedule();
  }

  void _listen(PlaybackActions playback) {
    playback.services.player.addListener(_playerChanged);
    playback.services.player.position.addListener(_positionChanged);
    playback.interaction.addListener(_sample);
  }

  void _unlisten(PlaybackActions playback) {
    playback.services.player.removeListener(_playerChanged);
    playback.services.player.position.removeListener(_positionChanged);
    playback.interaction.removeListener(_sample);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible && !_visible) _time = _read();
    _visible = visible;
    _schedule();
  }

  @override
  void didUpdateWidget(PlaybackPositionView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changed = oldWidget.playback != widget.playback;
    if (changed) {
      _unlisten(oldWidget.playback);
      _listen(widget.playback);
    }
    final intervalChanged = oldWidget.redrawSeconds != widget.redrawSeconds;
    if (intervalChanged) _stopTimer();
    if (changed ||
        intervalChanged ||
        oldWidget.episode.id != widget.episode.id ||
        !_isCurrent) {
      _time = _read();
    }
    _schedule();
  }

  void _sample() {
    if (!mounted || !_visible) return;
    final next = _read();
    if (next != _time) setState(() => _time = next);
  }

  void _positionChanged() {
    if (!widget.playback.playing(widget.episode.id)) {
      _sample();
    }
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
    if (_visible &&
        widget.playback.playing(widget.episode.id) &&
        (lifecycle == null ||
            lifecycle == AppLifecycleState.resumed ||
            lifecycle == AppLifecycleState.inactive)) {
      _timer ??= Timer.periodic(
        Duration(seconds: math.max(1, widget.redrawSeconds)),
        (_) => _sample(),
      );
    } else {
      _stopTimer();
    }
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _unlisten(widget.playback);
    WidgetsBinding.instance.removeObserver(this);
    _stopTimer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      RepaintBoundary(child: widget.builder(context, _time.$1, _time.$2));
}

double playedFraction(Duration elapsed, Duration? duration) =>
    duration == null || duration <= Duration.zero
    ? 0
    : (elapsed.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);

class PlaybackTimeline extends StatefulWidget {
  const PlaybackTimeline({
    super.key,
    required this.playback,
    required this.episode,
    required this.redrawSeconds,
  });

  static const trackKey = ValueKey('seek-track');
  static const previewKey = ValueKey('seek-preview');

  final PlaybackActions playback;
  final Episode episode;
  final int redrawSeconds;

  @override
  State<PlaybackTimeline> createState() => _PlaybackTimelineState();
}

class _PlaybackTimelineState extends State<PlaybackTimeline> {
  static const _trackInset = 9.0;
  Duration? _preview;
  bool _seeking = false;

  void _drag(double x, double width, Duration duration) {
    if (_seeking) return;
    final fraction = ((x - _trackInset) / math.max(1, width - 2 * _trackInset))
        .clamp(0.0, 1.0);
    final target = Duration(
      milliseconds: (duration.inMilliseconds * fraction).round(),
    );
    if (_preview != target) setState(() => _preview = target);
  }

  void _cancel() {
    if (!_seeking && _preview != null) setState(() => _preview = null);
  }

  Future<void> _seek() async {
    final target = _preview;
    if (target == null || _seeking) return;
    setState(() => _seeking = true);
    try {
      await widget.playback.seekTo(widget.episode.id, target);
    } finally {
      if (mounted) {
        setState(() {
          _preview = null;
          _seeking = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PlaybackPositionView(
    playback: widget.playback,
    episode: widget.episode,
    redrawSeconds: widget.redrawSeconds,
    builder: (context, elapsed, duration) {
      final known = duration != null && duration > Duration.zero;
      final canSeek = known && widget.playback.canSeek(widget.episode.id);
      final remaining = known
          ? (elapsed >= duration ? Duration.zero : duration - elapsed)
          : null;
      final displayed = _preview ?? elapsed;
      const step = Duration(seconds: 10);
      final earlier = displayed < step ? Duration.zero : displayed - step;
      final later = known && displayed + step > duration
          ? duration
          : displayed + step;
      return Column(
        children: [
          LayoutBuilder(
            builder: (context, bounds) => Semantics(
              slider: true,
              enabled: canSeek,
              label: context.strings.seekPlayback,
              value: positionText(displayed, padMinutes: true),
              decreasedValue: canSeek
                  ? positionText(earlier, padMinutes: true)
                  : null,
              increasedValue: canSeek
                  ? positionText(later, padMinutes: true)
                  : null,
              onDecrease: canSeek
                  ? () => widget.playback.seekTo(widget.episode.id, earlier)
                  : null,
              onIncrease: canSeek
                  ? () => widget.playback.seekTo(widget.episode.id, later)
                  : null,
              child: Listener(
                onPointerCancel: (_) => _cancel(),
                child: RawGestureDetector(
                  key: PlaybackTimeline.trackKey,
                  behavior: HitTestBehavior.opaque,
                  excludeFromSemantics: true,
                  gestures: {
                    HorizontalDragGestureRecognizer:
                        GestureRecognizerFactoryWithHandlers<
                          HorizontalDragGestureRecognizer
                        >(
                          () =>
                              HorizontalDragGestureRecognizer()
                                ..onlyAcceptDragOnThreshold = true,
                          (recognizer) {
                            void move(Offset position) {
                              if (canSeek) {
                                _drag(position.dx, bounds.maxWidth, duration);
                              }
                            }

                            recognizer.gestureSettings =
                                MediaQuery.maybeGestureSettingsOf(context);
                            recognizer.onStart = (details) =>
                                move(details.localPosition);
                            recognizer.onUpdate = (details) =>
                                move(details.localPosition);
                            recognizer.onEnd = (_) {
                              if (canSeek) {
                                unawaited(_seek());
                              } else {
                                widget.playback.showSeekUnavailable();
                              }
                            };
                            recognizer.onCancel = _cancel;
                          },
                        ),
                  },
                  child: SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: CustomPaint(
                      painter: _SeekTrack(
                        playedFraction(displayed, duration),
                        inset: _trackInset,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Row(
            spacing: 4,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Text(
                  positionText(elapsed, padMinutes: true),
                  style: rowTitleStyle,
                ),
              ),
              Expanded(
                child: Text(
                  _preview == null
                      ? ''
                      : positionText(displayed, padMinutes: true),
                  key: PlaybackTimeline.previewKey,
                  textAlign: TextAlign.center,
                  style: headingStyle,
                ),
              ),
              Expanded(
                child: Text(
                  remaining == null
                      ? '—'
                      : '−${positionText(remaining, padMinutes: true)}',
                  textAlign: TextAlign.end,
                  style: rowTitleStyle,
                ),
              ),
            ],
          ),
        ],
      );
    },
  );
}

class _SeekTrack extends CustomPainter {
  const _SeekTrack(this.fraction, {required this.inset});

  final double fraction;
  final double inset;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= inset * 2) return;
    final track = Rect.fromLTWH(
      inset,
      size.height / 2 - 4,
      size.width - inset * 2,
      8,
    );
    final outline = RRect.fromRectAndRadius(track, const Radius.circular(4));
    final thumb = Offset(track.left + track.width * fraction, track.center.dy);
    final black = Paint()..color = Colors.black;
    canvas.save();
    canvas.clipRRect(outline);
    canvas.drawRect(
      Rect.fromLTRB(track.left, track.top, thumb.dx, track.bottom),
      black,
    );
    canvas.restore();
    canvas.drawRRect(outline, Paint()..style = PaintingStyle.stroke);
    canvas.drawCircle(thumb, 9, Paint()..color = Colors.white);
    canvas.drawCircle(thumb, 7, black);
  }

  @override
  bool shouldRepaint(_SeekTrack oldDelegate) =>
      fraction != oldDelegate.fraction;
}
