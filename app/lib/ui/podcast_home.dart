import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/models.dart';
import '../core/services.dart';
import 'account_pages.dart';
import 'app_root.dart';
import 'downloads_page.dart';
import 'eink_widgets.dart';
import 'episode_page.dart';
import 'feed_refresh.dart';
import 'library_views.dart';
import 'playback_actions.dart';
import 'player_views.dart';
import 'settings_pages.dart';

class PodcastHome extends StatelessWidget {
  const PodcastHome({super.key});

  @override
  Widget build(BuildContext context) {
    final services = ServicesScope.of(context);
    return ValueListenableBuilder(
      valueListenable: services.sync.status,
      child: _LibraryHome(key: ObjectKey(services), services: services),
      builder: (context, _, library) => services.sync.isLoggedIn
          ? library!
          : LoginPage(key: ObjectKey(services), services: services),
    );
  }
}

enum _Screen {
  episode,
  player,
  podcast,
  about,
  add,
  reorder,
  server,
  feeds,
  opml,
}

typedef _Page = ({_Screen screen, int? id});

class _LibraryHome extends StatefulWidget {
  const _LibraryHome({super.key, required this.services});

  final AppServices services;

  @override
  State<_LibraryHome> createState() => _LibraryHomeState();
}

class _LibraryHomeState extends State<_LibraryHome> {
  static const _sortPreference = 'alphabeticalPodcasts';

  late final _playback = PlaybackActions(widget.services);
  late final _refresh = FeedRefresh(widget.services);
  late final _updates = Listenable.merge([
    widget.services.library,
    widget.services.settings,
    _playback,
    _refresh,
  ]);
  final _pages = <_Page>[];
  final _requestedDownloads = <int>{};
  final _scrollPositions = PageStorageBucket();

  LibrarySection _section = LibrarySection.inProgress;
  bool _menuOpen = false;
  bool _alphabetical = false;
  bool _sortEdited = false;
  bool _sortFailed = false;

  bool get _linux => !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;
  bool get _wide => _linux && MediaQuery.sizeOf(context).width >= 760;
  bool get _atHome =>
      _section == LibrarySection.inProgress && _pages.isEmpty && !_menuOpen;

  List<LibrarySection> get _sections => [
    for (final section in LibrarySection.values)
      if (!_linux || section != LibrarySection.downloads) section,
  ];

  @override
  void initState() {
    super.initState();
    unawaited(_loadSortPreference());
  }

  Future<void> _loadSortPreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted || _sortEdited) return;
      final sorted = prefs.getBool(_sortPreference) ?? false;
      if (sorted != _alphabetical) setState(() => _alphabetical = sorted);
    } on Exception {
      if (mounted) setState(() => _sortFailed = true);
    }
  }

  Future<void> _toggleSort() async {
    _sortEdited = true;
    setState(() => _alphabetical = !_alphabetical);
    final sorted = _alphabetical;
    var saved = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      saved = await prefs.setBool(_sortPreference, sorted);
    } on Exception {
      saved = false;
    }
    if (mounted && sorted == _alphabetical && _sortFailed == saved) {
      setState(() => _sortFailed = !saved);
    }
  }

  @override
  void dispose() {
    _playback.dispose();
    _refresh.dispose();
    super.dispose();
  }

  void _back() {
    if (_atHome) return;
    setState(() {
      if (_menuOpen) {
        _menuOpen = false;
      } else if (_pages.isNotEmpty) {
        _pages.removeLast();
      } else {
        _section = LibrarySection.inProgress;
      }
    });
  }

  void _switchList(LibrarySection section) => setState(() {
    _section = section;
    _menuOpen = false;
    _pages.clear();
  });

  void _open(_Screen screen, [int? id]) =>
      setState(() => _pages.add((screen: screen, id: id)));

  void _openEpisode(Episode episode) {
    final wide = _wide;
    setState(() {
      if (wide) _pages.removeWhere((page) => page.screen != _Screen.podcast);
      _pages.add((screen: _Screen.episode, id: episode.id));
    });
  }

  void _openPodcast(Podcast podcast) => setState(() {
    _pages.removeWhere((page) => page.screen == _Screen.add);
    _pages.add((screen: _Screen.podcast, id: podcast.id));
  });

  List<Episode> _activeEpisodeList() {
    final library = widget.services.library;
    final podcast = _pages
        .where((page) => page.screen == _Screen.podcast)
        .firstOrNull;
    if (podcast != null) return library.episodesOf(podcast.id!);
    return switch (_section) {
      LibrarySection.inProgress => library.inProgress,
      LibrarySection.queue => library.queue,
      LibrarySection.newEpisodes => library.newEpisodes(limit: 0x7fffffff),
      _ => const [],
    };
  }

  KeyEventResult _desktopKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape && !_atHome) {
      _back();
      return KeyEventResult.handled;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final focus = FocusManager.instance.primaryFocus?.context;
    if (focus?.findAncestorStateOfType<EditableTextState>() != null) {
      return KeyEventResult.ignored;
    }
    final settings = widget.services.settings;
    if (key == LogicalKeyboardKey.space) {
      unawaited(_playback.toggle());
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      unawaited(_playback.skip(Duration(seconds: -settings.skipBackSeconds)));
    } else if (key == LogicalKeyboardKey.arrowRight) {
      unawaited(_playback.skip(Duration(seconds: settings.skipForwardSeconds)));
    } else if (_wide &&
        (key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.arrowDown)) {
      final episodes = _activeEpisodeList();
      if (episodes.isEmpty) return KeyEventResult.ignored;
      final current = _pages.lastOrNull;
      final index = episodes.indexWhere(
        (episode) =>
            current?.screen == _Screen.episode && episode.id == current?.id,
      );
      final delta = key == LogicalKeyboardKey.arrowUp ? -1 : 1;
      final target = episodes[(index + delta).clamp(0, episodes.length - 1)];
      if (target.id != current?.id || current?.screen != _Screen.episode) {
        _openEpisode(target);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final row = EpisodeRowKey(target).currentContext;
          if (mounted && row != null) {
            unawaited(Scrollable.ensureVisible(row));
          }
        });
      }
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final desktop = _wide;
    return ListenableBuilder(
      listenable: _updates,
      builder: (context, _) {
        final content = Scaffold(
          body: SafeArea(
            child: PageStorage(
              bucket: _scrollPositions,
              child: desktop ? _desktopBody(context) : _phoneBody(context),
            ),
          ),
        );
        return PopScope(
          canPop: _atHome,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _back();
          },
          child: _linux
              ? Focus(autofocus: true, onKeyEvent: _desktopKey, child: content)
              : content,
        );
      },
    );
  }

  Widget _phoneBody(BuildContext context) {
    final page = _pages.lastOrNull;
    final settings = _section == LibrarySection.settings;
    final showMini = page == null ? !settings : page.screen == _Screen.podcast;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        EinkHeader(
          page == null ? _section.label(context) : _title(context, page),
          onBack: page != null || settings ? _back : null,
          onMenu: page != null || settings
              ? null
              : () => setState(() => _menuOpen = !_menuOpen),
          expanded: _menuOpen,
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, bounds) => Stack(
              fit: StackFit.expand,
              children: [
                ExcludeSemantics(
                  excluding: _menuOpen,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: page == null
                            ? _sectionBody(context)
                            : _pageBody(context, page),
                      ),
                      if (showMini)
                        MiniPlayer(
                          playback: _playback,
                          onOpen: () => _open(_Screen.player),
                        ),
                    ],
                  ),
                ),
                if (_menuOpen) ...[
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _back,
                    excludeFromSemantics: true,
                    child: const SizedBox.expand(),
                  ),
                  Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: bounds.maxHeight),
                      child: DecoratedBox(
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          border: Border.fromBorderSide(BorderSide(width: 2)),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(2),
                          child: ListView(
                            shrinkWrap: true,
                            padding: EdgeInsets.zero,
                            children: [
                              for (final section in _sections)
                                EinkRow(
                                  title: section.label(context),
                                  onPressed: () => _switchList(section),
                                  selected: section == _section,
                                  last: section == _sections.last,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _desktopBody(BuildContext context) {
    final podcast = _pages
        .where((page) => page.screen == _Screen.podcast)
        .firstOrNull;
    final last = _pages.lastOrNull;
    final detail = last?.screen == _Screen.podcast ? null : last;
    final widthFactor = (MediaQuery.sizeOf(context).width / 1000).clamp(
      0.0,
      1.0,
    );
    final strings = context.strings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 220 * widthFactor,
                child: _columnDivider(
                  Column(
                    children: [
                      Expanded(
                        child: ListView(
                          padding: EdgeInsets.zero,
                          children: [
                            for (final section in _sections)
                              if (section != LibrarySection.settings)
                                EinkRow(
                                  title: section.label(context),
                                  selected: _section == section,
                                  desktop: true,
                                  onPressed: () => _switchList(section),
                                ),
                          ],
                        ),
                      ),
                      DecoratedBox(
                        decoration: const BoxDecoration(
                          border: Border(top: BorderSide()),
                        ),
                        child: EinkRow(
                          title: strings.settings,
                          selected: _section == LibrarySection.settings,
                          desktop: true,
                          last: true,
                          onPressed: () => _switchList(LibrarySection.settings),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(
                width: 360 * widthFactor,
                child: _columnDivider(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      EinkHeader(
                        podcast == null
                            ? _section.label(context)
                            : _title(context, podcast),
                        onBack: podcast == null
                            ? null
                            : () => setState(_pages.clear),
                      ),
                      Expanded(
                        child: podcast == null
                            ? _sectionBody(context, desktop: true)
                            : _podcastBody(context, podcast.id!, desktop: true),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: detail == null
                    ? (_section == LibrarySection.settings ||
                              (_section == LibrarySection.podcasts &&
                                  podcast == null)
                          ? const SizedBox.shrink()
                          : PageMessage(strings.selectEpisode))
                    : detail.screen == _Screen.episode
                    ? _pageBody(context, detail, desktop: true)
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          EinkHeader(_title(context, detail), onBack: _back),
                          Expanded(
                            child: _pageBody(context, detail, desktop: true),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
        DesktopPlayer(playback: _playback, onEpisode: _openEpisode),
      ],
    );
  }

  Widget _columnDivider(Widget child) => DecoratedBox(
    position: DecorationPosition.foreground,
    decoration: const BoxDecoration(border: Border(right: BorderSide())),
    child: child,
  );

  String _title(BuildContext context, _Page page) {
    final library = widget.services.library;
    final strings = context.strings;
    return switch (page.screen) {
      _Screen.episode =>
        _episodePodcastTitle(page.id!) ?? strings.episodeMissing,
      _Screen.podcast =>
        library.podcast(page.id!)?.title ?? strings.podcastMissing,
      _Screen.player => strings.player,
      _Screen.about => strings.aboutPodcast,
      _Screen.add => strings.addPodcast,
      _Screen.reorder => strings.queueOrder,
      _Screen.server => strings.server,
      _Screen.feeds => strings.feedStatus,
      _Screen.opml => strings.opml,
    };
  }

  String? _episodePodcastTitle(int id) {
    final library = widget.services.library;
    final episode = library.episode(id);
    return episode == null
        ? null
        : library.podcast(episode.podcastId)?.title ?? episode.title;
  }

  Widget _sectionBody(BuildContext context, {bool desktop = false}) {
    final strings = context.strings;
    final selected = _pages.lastOrNull;
    final kind = switch (_section) {
      LibrarySection.inProgress => EpisodeListKind.inProgress,
      LibrarySection.queue => EpisodeListKind.queue,
      LibrarySection.newEpisodes => EpisodeListKind.newEpisodes,
      _ => null,
    };
    if (kind != null) {
      return EpisodeList(
        kind: kind,
        episodes: _activeEpisodeList(),
        playback: _playback,
        onOpen: _openEpisode,
        desktop: desktop,
        downloadsAvailable: !_linux,
        selectedId: selected?.screen == _Screen.episode ? selected?.id : null,
        actions: [
          if (_section == LibrarySection.queue)
            EinkRow(
              title: strings.queueEdit,
              compact: true,
              underlined: true,
              trailing: const Icon(Icons.chevron_right),
              onPressed: () => _open(_Screen.reorder),
            ),
          if (_section == LibrarySection.newEpisodes)
            RefreshRow(refresh: _refresh, lastLoaded: _refresh.lastLoaded),
        ],
      );
    }
    return switch (_section) {
      LibrarySection.podcasts => PodcastList(
        playback: _playback,
        alphabetical: _alphabetical,
        onOpen: _openPodcast,
        onAdd: () => _open(_Screen.add),
        desktop: desktop,
      ),
      LibrarySection.downloads => DownloadsPage(
        playback: _playback,
        requestedIds: _requestedDownloads,
        onOpen: _openEpisode,
      ),
      LibrarySection.settings => SettingsPage(
        playback: _playback,
        alphabetical: _alphabetical,
        sortFailed: _sortFailed,
        onAlphabetical: _toggleSort,
        downloadsAvailable: !_linux,
        onServer: () => _open(_Screen.server),
        onFeeds: () => _open(_Screen.feeds),
        onOpml: () => _open(_Screen.opml),
      ),
      _ => const SizedBox.shrink(),
    };
  }

  Widget _podcastBody(BuildContext context, int id, {required bool desktop}) {
    final library = widget.services.library;
    final podcast = library.podcast(id);
    final strings = context.strings;
    if (podcast == null) return PageMessage(strings.podcastMissing);
    final last = _pages.lastOrNull;
    return EpisodeList(
      key: PageStorageKey(('podcast', id)),
      kind: EpisodeListKind.podcast,
      episodes: library.episodesOf(id),
      playback: _playback,
      onOpen: _openEpisode,
      desktop: desktop,
      downloadsAvailable: !_linux,
      selectedId: last?.screen == _Screen.episode ? last?.id : null,
      actions: [
        if (podcast.subscribed)
          RefreshRow(
            refresh: _refresh,
            lastLoaded: podcast.lastSuccessAt,
            podcastId: id,
          ),
        EinkRow(
          title: strings.aboutPodcast,
          compact: true,
          underlined: true,
          trailing: const Icon(Icons.chevron_right),
          onPressed: () => _open(_Screen.about, id),
        ),
      ],
    );
  }

  Widget _pageBody(BuildContext context, _Page page, {bool desktop = false}) {
    final services = widget.services;
    final strings = context.strings;
    final id = page.id;
    switch (page.screen) {
      case _Screen.episode:
        final episode = services.library.episode(id!);
        if (episode == null) return PageMessage(strings.episodeMissing);
        return EpisodePage(
          key: ValueKey(episode.id),
          episode: episode,
          playback: _playback,
          desktopPanel: desktop,
          downloadsAvailable: !_linux,
          onTrackDownload: _requestedDownloads.add,
        );
      case _Screen.podcast:
        return _podcastBody(context, id!, desktop: desktop);
      case _Screen.about:
        final podcast = services.library.podcast(id!);
        return podcast == null
            ? PageMessage(strings.podcastMissing)
            : AboutPodcastPage(
                key: ValueKey(id),
                services: services,
                podcast: podcast,
              );
      case _Screen.player:
        return PlayerPage(
          playback: _playback,
          onEpisode: _openEpisode,
          sleepAvailable: !_linux,
        );
      case _Screen.add:
        return AddPodcastPage(services: services, onAdded: _openPodcast);
      case _Screen.reorder:
        return QueueEditor(playback: _playback, desktop: desktop);
      case _Screen.server:
        return ServerPage(services: services);
      case _Screen.feeds:
        return FeedStatusPage(
          services: services,
          onOpen: (podcast) => _open(_Screen.about, podcast.id),
        );
      case _Screen.opml:
        return OpmlPage(services: services);
    }
  }
}
