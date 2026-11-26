import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../core/downloads.dart';
import '../core/library.dart';
import '../core/models.dart';
import 'eink_widgets.dart';
import 'episode_text.dart';
import 'library_views.dart';
import 'playback_actions.dart';

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({
    super.key,
    required this.playback,
    required this.onOpen,
    required this.onMenu,
  });

  final PlaybackActions playback;
  final ValueChanged<Episode> onOpen;
  final ValueChanged<Episode> onMenu;

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  late var _ids = _downloads.episodeIds;
  late var _files = _finishedFiles();
  late var _sizes = _readSizes(_files);

  DownloadService get _downloads => widget.playback.services.downloads;
  Library get _library => widget.playback.services.library;

  @override
  void initState() {
    super.initState();
    _downloads.addListener(_refresh);
  }

  @override
  void dispose() {
    _downloads.removeListener(_refresh);
    super.dispose();
  }

  Map<int, String?> _finishedFiles() => {
    for (final id in _downloads.downloadedEpisodeIds)
      id: _downloads.localFileOf(id),
  };

  void _refresh() {
    final ids = _downloads.episodeIds;
    final files = _finishedFiles();
    final changed = !mapEquals(files, _files);
    if (!changed && listEquals(ids, _ids)) return;
    setState(() {
      _ids = ids;
      if (changed) {
        _files = files;
        _sizes = _readSizes(files);
      }
    });
  }

  Future<Map<int, int?>> _readSizes(Map<int, String?> files) async => {
    for (final MapEntry(key: id, value: path) in files.entries)
      id: await _fileSize(path) ?? _library.episode(id)?.enclosureLength,
  };

  Future<int?> _fileSize(String? path) async {
    if (path == null) return null;
    try {
      return await File(path).length();
    } on FileSystemException {
      return null;
    }
  }

  Widget _storageLine(BuildContext context, Iterable<int?> sizes) {
    final strings = context.strings;
    final text = sizes.contains(null)
        ? strings.storageUnknown
        : strings.storageUsed(
            bytesText(strings, sizes.fold(0, (sum, bytes) => sum + bytes!)),
          );
    return DecoratedBox(
      decoration: const BoxDecoration(border: Border(bottom: BorderSide())),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
        child: Text(text, style: detailStyle),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final episodes = [for (final id in _ids) ?_library.episode(id)];
    return FutureBuilder<Map<int, int?>>(
      future: _sizes,
      builder: (context, snapshot) {
        final sizes = snapshot.connectionState == ConnectionState.done
            ? snapshot.requireData
            : {
                for (final id in _files.keys)
                  id: _library.episode(id)?.enclosureLength,
              };
        return EpisodeList(
          kind: EpisodeListKind.downloads,
          episodes: episodes,
          playback: widget.playback,
          onOpen: widget.onOpen,
          onMenu: widget.onMenu,
          fileSizes: sizes,
          actions: [_storageLine(context, sizes.values)],
        );
      },
    );
  }
}
