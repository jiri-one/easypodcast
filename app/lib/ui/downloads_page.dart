import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import '../core/downloads.dart';
import '../core/models.dart';
import 'eink_widgets.dart';
import 'episode_text.dart';
import 'library_views.dart';
import 'playback_actions.dart';
import 'queue_edits.dart';

typedef _Download = (DownloadStatus status, String? path);
typedef _Storage = ({Map<int, int?> sizes, int? free});

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({
    super.key,
    required this.playback,
    required this.queueEdits,
    required this.requestedIds,
    required this.onOpen,
    required this.onMenu,
  });

  final PlaybackActions playback;
  final QueueEdits queueEdits;
  final Set<int> requestedIds;
  final ValueChanged<Episode> onOpen;
  final ValueChanged<Episode> onMenu;

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  late Set<int> _knownIds;
  Map<int, _Download> _visible = const {};
  late Future<_Storage> _storage;

  @override
  void initState() {
    super.initState();
    _knownIds = _knownEpisodes();
    _visible = _inventory();
    _storage = _readStorage(_visible);
    widget.playback.services.library.addListener(_refreshKnown);
    widget.playback.services.downloads.addListener(_refresh);
  }

  @override
  void dispose() {
    widget.playback.services.library.removeListener(_refreshKnown);
    widget.playback.services.downloads.removeListener(_refresh);
    super.dispose();
  }

  Set<int> _knownEpisodes() {
    final library = widget.playback.services.library;
    return {
      ...widget.requestedIds,
      for (final episode in library.queue) episode.id,
      for (final episode in library.inProgress) episode.id,
      for (final podcast in library.podcasts)
        for (final episode in library.episodesOf(podcast.id)) episode.id,
    };
  }

  Map<int, _Download> _inventory() {
    final downloads = widget.playback.services.downloads;
    final finished = downloads.downloadedEpisodeIds;
    final items = <int, _Download>{};
    for (final id in _knownIds) {
      final info = downloads.statusOf(id);
      if (info.status != DownloadStatus.none &&
          info.status != DownloadStatus.done) {
        items[id] = (info.status, null);
      }
    }
    for (final id in finished) {
      items[id] = (DownloadStatus.done, downloads.localFileOf(id));
    }
    return items;
  }

  void _refreshKnown() {
    _knownIds.addAll(_knownEpisodes());
    _refresh();
  }

  void _refresh() {
    final next = _inventory();
    if (mapEquals(next, _visible)) return;
    final files = _files(next);
    final changed = !mapEquals(files, _files(_visible));
    setState(() {
      _visible = next;
      if (changed) _storage = _readStorage(next);
    });
  }

  Map<int, String?> _files(Map<int, _Download> entries) => {
    for (final entry in entries.entries)
      if (entry.value.$1 == DownloadStatus.done) entry.key: entry.value.$2,
  };

  Future<_Storage> _readStorage(Map<int, _Download> entries) async {
    final library = widget.playback.services.library;
    final sizes = <int, int?>{};
    final free = _freeSpace();
    for (final entry in _files(entries).entries) {
      final path = entry.value;
      int? actual;
      if (path != null) {
        try {
          actual = await File(path).length();
        } on FileSystemException {
          actual = null;
        }
      }
      sizes[entry.key] = actual ?? library.episode(entry.key)?.enclosureLength;
    }
    return (sizes: sizes, free: await free);
  }

  Future<int?> _freeSpace() async {
    if (!Platform.isAndroid) return null;
    try {
      final directory = await getApplicationDocumentsDirectory();
      final result = await Process.run('/system/bin/df', [
        '-k',
        directory.path,
      ]);
      if (result.exitCode != 0) return null;
      final lines = (result.stdout as String).trim().split('\n');
      if (lines.length < 2) return null;
      final fields = lines.last.trim().split(RegExp(r'\s+'));
      final available = fields.length < 4 ? null : int.tryParse(fields[3]);
      return available == null ? null : available * 1024;
    } on Exception {
      return null;
    }
  }

  Widget _storageLine(BuildContext context, _Storage storage) {
    final strings = context.strings;
    final sizes = storage.sizes.values;
    final free = storage.free;
    final String text;
    if (sizes.contains(null)) {
      text = strings.storageUnknown;
    } else {
      final bytes = sizes.fold(0, (sum, bytes) => sum + (bytes ?? 0));
      final used = bytesText(strings, bytes);
      text = free == null
          ? strings.storageUsed(used)
          : strings.storageUsedAndFree(used, bytesText(strings, free));
    }
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
    final library = widget.playback.services.library;
    final episodes = [for (final id in _visible.keys) ?library.episode(id)];
    return FutureBuilder<_Storage>(
      future: _storage,
      initialData: (
        sizes: {
          for (final id in _files(_visible).keys)
            id: library.episode(id)?.enclosureLength,
        },
        free: null,
      ),
      builder: (context, snapshot) {
        final storage = snapshot.data;
        return EpisodeList(
          kind: EpisodeListKind.downloads,
          episodes: episodes,
          playback: widget.playback,
          queueEdits: widget.queueEdits,
          onOpen: widget.onOpen,
          onMenu: widget.onMenu,
          fileSizes: storage?.sizes ?? const {},
          actions: [if (storage != null) _storageLine(context, storage)],
        );
      },
    );
  }
}
