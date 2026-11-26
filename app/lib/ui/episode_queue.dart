import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import '../core/library.dart';
import '../core/models.dart';
import 'eink_widgets.dart';

class EpisodeQueue extends StatefulWidget {
  const EpisodeQueue({
    super.key,
    required this.library,
    required this.episodes,
    required this.header,
    required this.onMenu,
    required this.rowBuilder,
  });

  final Library library;
  final List<Episode> episodes;
  final Widget header;
  final ValueChanged<Episode> onMenu;
  final Widget Function(BuildContext, Episode, int, bool) rowBuilder;

  @override
  State<EpisodeQueue> createState() => _EpisodeQueueState();
}

class _QueueDrag {
  _QueueDrag({
    required this.from,
    required this.origin,
    required this.top,
    required this.height,
    required this.menuOnRelease,
  }) : position = origin,
       to = from,
       layoutIndex = from;

  final int from;
  final Offset origin;
  final double top;
  final double height;
  final bool menuOnRelease;
  Offset position;
  int to;
  int layoutIndex;
  bool moved = false;
}

class _EpisodeQueueState extends State<EpisodeQueue> {
  final _scroll = ScrollController();
  final _rowsKey = GlobalKey();
  _QueueDrag? _drag;
  Timer? _edgeScroll;
  bool _saving = false;
  bool _failed = false;

  RenderSliverList? get _rows =>
      _rowsKey.currentContext?.findRenderObject() as RenderSliverList?;
  RenderBox get _viewport => context.findRenderObject()! as RenderBox;

  bool _sameOrder(List<Episode> other) => listEquals(
    [for (final episode in widget.episodes) episode.id],
    [for (final episode in other) episode.id],
  );

  @override
  void didUpdateWidget(EpisodeQueue oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_drag != null &&
        (oldWidget.library != widget.library ||
            !_sameOrder(oldWidget.episodes))) {
      _stopEdgeScroll();
      _drag = null;
    }
  }

  @override
  void dispose() {
    _stopEdgeScroll();
    _scroll.dispose();
    super.dispose();
  }

  void _hold(Offset position, {required bool menuOnRelease}) {
    final rows = _rows;
    if (_saving || _drag != null || rows == null) return;
    for (var row = rows.firstChild; row != null; row = rows.childAfter(row)) {
      if (!row.size.contains(row.globalToLocal(position))) continue;
      final drag = _QueueDrag(
        from: rows.indexOf(row),
        origin: position,
        top: rows.childScrollOffset(row)!,
        height: row.size.height,
        menuOnRelease: menuOnRelease,
      );
      setState(() => _drag = drag);
      return;
    }
  }

  double _distanceToSlot(double y, double top, double height) =>
      math.max(0, math.max(top - y, y - top - height));

  int _slotAt(_QueueDrag drag) {
    final rows = _rows!;
    final scroll = _scroll.position;
    final local = _viewport.globalToLocal(drag.position);
    final height = scroll.viewportDimension;
    if (local.dy <= 0 && scroll.extentBefore < 1) return 0;
    if (local.dy >= height && scroll.extentAfter < 1) {
      return widget.episodes.length - 1;
    }
    final first = rows.firstChild!;
    final pointerY = _viewport
        .localToGlobal(Offset(0, local.dy.clamp(0, height)))
        .dy;
    final y =
        rows.childScrollOffset(first)! +
        pointerY -
        first.localToGlobal(Offset.zero).dy;
    var target = drag.from;
    var closest = _distanceToSlot(y, drag.top, drag.height);
    final lifted = drag.layoutIndex;
    for (RenderBox? row = first; row != null; row = rows.childAfter(row)) {
      final index = rows.indexOf(row);
      if (index == lifted) continue;
      final original = switch (index) {
        _ when index >= drag.from && index < lifted => index + 1,
        _ when index > lifted && index <= drag.from => index - 1,
        _ => index,
      };
      // Use the original slots so unequal rows stay stable beneath the pointer.
      final top =
          rows.childScrollOffset(row)! + (original - index) * drag.height;
      final distance = _distanceToSlot(y, top, row.size.height);
      if (distance < closest) {
        closest = distance;
        target = original;
      }
    }
    return target;
  }

  void _preview(_QueueDrag drag) {
    if (_rows?.firstChild == null) return;
    final target = _slotAt(drag);
    if (target == drag.to) return;
    drag.moved = true;
    setState(() => drag.to = target);
  }

  void _move(Offset position) {
    final drag = _drag;
    if (drag == null || _saving) return;
    drag.position = position;
    if ((position - drag.origin).distance > kTouchSlop) drag.moved = true;
    _preview(drag);
    if (!drag.moved || _edgeOffset(drag) == null) {
      _stopEdgeScroll();
      return;
    }
    _edgeScroll ??= Timer.periodic(
      const Duration(milliseconds: 160),
      (_) => _scrollAtEdge(drag),
    );
  }

  double? _edgeOffset(_QueueDrag drag) {
    final scroll = _scroll.position;
    final height = scroll.viewportDimension;
    final y = _viewport.globalToLocal(drag.position).dy;
    final edge = math.min(32.0, height / 4);
    if (y >= edge && y <= height - edge) return null;
    final step = math.min(drag.height, height / 2);
    final next = (scroll.pixels + (y < edge ? -step : step)).clamp(
      scroll.minScrollExtent,
      scroll.maxScrollExtent,
    );
    return next == scroll.pixels ? null : next;
  }

  void _scrollAtEdge(_QueueDrag drag) {
    final offset = _edgeOffset(drag);
    if (offset == null) {
      _stopEdgeScroll();
      return;
    }
    _scroll.jumpTo(offset);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(_drag, drag) && !_saving) _preview(drag);
    });
  }

  void _stopEdgeScroll() {
    _edgeScroll?.cancel();
    _edgeScroll = null;
  }

  void _cancel() {
    if (_drag == null || _saving) return;
    _stopEdgeScroll();
    setState(() => _drag = null);
  }

  Future<void> _drop() async {
    final drag = _drag;
    if (drag == null || _saving) return;
    _stopEdgeScroll();
    if (!_sameOrder(widget.library.queue)) {
      _cancel();
      return;
    }
    final episode = widget.episodes[drag.from];
    if (drag.from == drag.to) {
      _cancel();
      if (drag.menuOnRelease && !drag.moved) widget.onMenu(episode);
      return;
    }
    setState(() {
      _saving = true;
      _failed = false;
    });
    try {
      await widget.library.moveInQueue(episode.id, drag.to);
    } on Exception {
      _failed = true;
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _drag = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final drag = _drag;
    final episodes = [...widget.episodes];
    if (drag != null) {
      episodes.insert(drag.to, episodes.removeAt(drag.from));
      drag.layoutIndex = drag.to;
    }
    final indices = {
      for (final (index, episode) in episodes.indexed) episode.id: index,
    };
    return Listener(
      onPointerCancel: (_) => _cancel(),
      child: GestureDetector(
        excludeFromSemantics: true,
        supportedDevices: const {PointerDeviceKind.mouse},
        dragStartBehavior: DragStartBehavior.down,
        onVerticalDragStart: (details) =>
            _hold(details.globalPosition, menuOnRelease: false),
        onVerticalDragUpdate: (details) => _move(details.globalPosition),
        onVerticalDragEnd: (_) => unawaited(_drop()),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onLongPressStart: (details) =>
              _hold(details.globalPosition, menuOnRelease: true),
          onLongPressMoveUpdate: (details) => _move(details.globalPosition),
          onLongPressUp: () => unawaited(_drop()),
          child: CustomScrollView(
            controller: _scroll,
            slivers: [
              SliverToBoxAdapter(child: widget.header),
              if (_failed)
                SliverToBoxAdapter(
                  child: ProblemBox(context.strings.actionFailed),
                ),
              if (episodes.isEmpty)
                SliverToBoxAdapter(
                  child: PageMessage(context.strings.queueEmpty),
                ),
              SliverList.builder(
                key: _rowsKey,
                itemCount: episodes.length,
                findChildIndexCallback: (key) =>
                    indices[(key as ValueKey<int>).value],
                itemBuilder: (context, index) {
                  final episode = episodes[index];
                  return KeyedSubtree(
                    key: ValueKey(episode.id),
                    child: widget.rowBuilder(
                      context,
                      episode,
                      index,
                      !_saving && index == drag?.to,
                    ),
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
