import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/models.dart';
import '../core/services.dart';
import 'account_pages.dart';
import 'app_root.dart';
import 'downloads_page.dart';
import 'eink_widgets.dart';
import 'episode_actions.dart';
import 'episode_page.dart';
import 'episode_text.dart';
import 'feed_refresh.dart';
import 'library_views.dart';
import 'playback_actions.dart';
import 'player_views.dart';
import 'podcast_search.dart';
import 'podcast_search_field.dart';
import 'settings_pages.dart';
import 'theme.dart';

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
  settings,
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
  late final _playback = PlaybackActions(widget.services);
  late final _refresh = FeedRefresh(widget.services);
  final _podcastSearch = EpisodeSearch();
  final _globalSearch = EpisodeSearch();
  late final _updates = Listenable.merge([
    widget.services.library,
    widget.services.settings,
    _playback,
    _refresh,
    _podcastSearch,
    _globalSearch,
    widget.services.sync.status,
  ]);
  final _pages = <_Page>[];
  final _scrollPositions = PageStorageBucket();
  int? _searchPodcastId;
  final _searchTitles = <String, String>{};

  LibrarySection _section = LibrarySection.inProgress;
  LibrarySection _searchOrigin = LibrarySection.inProgress;
  bool _menuOpen = false;
  bool _rowMenuOpen = false;
  bool get _linux => !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;
  bool get _wide => _linux && MediaQuery.sizeOf(context).width >= 760;
  bool get _atHome =>
      _section == LibrarySection.inProgress && _pages.isEmpty && !_menuOpen;

  _Page? get _podcastPage =>
      _pages.where((page) => page.screen == _Screen.podcast).firstOrNull;

  _Page? get _settingsPage =>
      _pages.where((page) => page.screen == _Screen.settings).firstOrNull;

  List<LibrarySection> get _sections => [
    for (final section in LibrarySection.values)
      if (downloadsAvailable || section != LibrarySection.downloads) section,
  ];

  @override
  void dispose() {
    _podcastSearch.dispose();
    _globalSearch.dispose();
    _playback.dispose();
    _refresh.dispose();
    super.dispose();
  }

  void _back() {
    if (_atHome) return;
    setState(() {
      if (_menuOpen) {
        _menuOpen = false;
      } else if (_pages.lastOrNull case final page?) {
        if (!_closePodcastSearchOn(page)) _pages.removeLast();
      } else if (_section == LibrarySection.search) {
        _closeGlobalSearch();
      } else {
        _section = LibrarySection.inProgress;
      }
    });
  }

  void _switchList(LibrarySection section) {
    setState(() {
      _menuOpen = false;
      if (section == LibrarySection.settings) {
        if (_settingsPage == null) {
          _pages.add((screen: _Screen.settings, id: null));
        }
        return;
      }
      if (section == LibrarySection.search) {
        if (_section != section) _searchOrigin = _section;
      } else if (_section == LibrarySection.search) {
        _closeGlobalSearch();
      }
      _closePodcastSearch();
      _section = section;
      _pages.clear();
    });
    if (section == LibrarySection.search) _globalSearch.focus.requestFocus();
  }

  void _open(_Screen screen, [int? id]) =>
      setState(() => _pages.add((screen: screen, id: id)));

  void _openPlayer() {
    // A page the player opened leads back to it, not to a second player.
    if (_pages.length > 1 &&
        _pages[_pages.length - 2].screen == _Screen.player) {
      _back();
    } else {
      _open(_Screen.player);
    }
  }

  void _openEpisode(Episode episode) {
    final wide = _wide;
    setState(() {
      if (wide) _pages.removeWhere((page) => page.screen != _Screen.podcast);
      _pages.add((screen: _Screen.episode, id: episode.id));
    });
  }

  Future<void> _openEpisodeMenu(Episode episode) async {
    if (_rowMenuOpen) return;
    _rowMenuOpen = true;
    try {
      await EpisodeActions(episode: episode, playback: _playback).showMenu(
        context,
        queueMoves:
            _section == LibrarySection.queue &&
            _podcastPage == null &&
            _settingsPage == null,
      );
    } on Object catch (error) {
      if (!mounted) return;
      await showEinkDialog<void>(
        context: context,
        builder: (_) => EinkDialogPanel(title: actionError(context, error)),
      );
    } finally {
      _rowMenuOpen = false;
    }
  }

  Future<void> _openPodcastMenu(Podcast podcast) async {
    if (_rowMenuOpen) return;
    _rowMenuOpen = true;
    try {
      await showPodcastMenu(context, widget.services, podcast);
    } finally {
      _rowMenuOpen = false;
    }
  }

  void _openPodcast(Podcast podcast) => setState(() {
    _closePodcastSearch();
    final _Page page = (screen: _Screen.podcast, id: podcast.id);
    // An Add page under the player turns into its podcast there.
    final add = _pages.indexWhere((page) => page.screen == _Screen.add);
    if (add < 0) {
      _pages.add(page);
    } else {
      _pages[add] = page;
    }
  });

  void _openPodcastSearch(int podcastId) {
    setState(() => _searchPodcastId = podcastId);
    _podcastSearch.focus.requestFocus();
  }

  void _closePodcastSearch() {
    if (_searchPodcastId == null) return;
    _searchPodcastId = null;
    _podcastSearch.reset();
  }

  bool _closePodcastSearchOn(_Page page) {
    if (page.screen != _Screen.podcast || _searchPodcastId != page.id) {
      return false;
    }
    _closePodcastSearch();
    return true;
  }

  void _closeGlobalSearch() {
    _section = _searchOrigin;
    _pages.clear();
    _searchTitles.clear();
    _globalSearch.reset();
  }

  // Title matches come first, so a full page leaves no room for the server's
  // description matches.
  Future<List<int>> _searchAll(String query) => _globalEpisodes().length < 100
      ? widget.services.api.searchAll(query)
      : Future.value(const []);

  List<Episode> _globalEpisodes() {
    final library = widget.services.library;
    return matchLibraryEpisodes(
      library.podcasts.expand((podcast) => library.episodesOf(podcast.id)),
      _globalSearch.words,
      _globalSearch.matches,
      _searchTitles,
    );
  }

  List<Episode> _podcastEpisodes(int id) {
    final episodes = widget.services.library.episodesOf(id);
    return _searchPodcastId == id
        ? matchPodcastEpisodes(
            episodes,
            _podcastSearch.words,
            _podcastSearch.matches,
          )
        : episodes;
  }

  List<Episode> _activeEpisodeList() {
    if (_settingsPage != null) return const [];
    final podcast = _podcastPage;
    return podcast == null ? _sectionEpisodes() : _podcastEpisodes(podcast.id!);
  }

  List<Episode> _sectionEpisodes() {
    final library = widget.services.library;
    return switch (_section) {
      LibrarySection.inProgress => library.inProgress,
      LibrarySection.queue => library.projectedQueue,
      LibrarySection.newEpisodes => _recentNewEpisodes(),
      LibrarySection.search => _globalEpisodes(),
      _ => const [],
    };
  }

  List<Episode> _recentNewEpisodes() {
    final cutoff = DateTime.now().subtract(const Duration(days: 30));
    return widget.services.library.newEpisodes(since: cutoff);
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
    if (key == LogicalKeyboardKey.space) {
      unawaited(_playback.toggle());
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      unawaited(_playback.skipBack());
    } else if (key == LogicalKeyboardKey.arrowRight) {
      unawaited(_playback.skipForward());
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
              ? FocusScope(
                  autofocus: true,
                  onKeyEvent: _desktopKey,
                  child: content,
                )
              : content,
        );
      },
    );
  }

  Widget _phoneBody(BuildContext context) {
    final top = _pages.lastOrNull;
    final player = top?.screen == _Screen.player ? top : null;
    final page = player == null ? top : _pages.reversed.skip(1).firstOrNull;
    final switcher = page == null && _section != LibrarySection.search;
    final menu = switcher && _menuOpen;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: page == null
              ? _sectionBody(context)
              : _pageBody(context, page),
        ),
        MiniPlayer(playback: _playback, onOpen: _openPlayer),
      ],
    );
    final screen = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(
          context,
          page,
          onBack: switcher ? null : _back,
          onMenu: switcher
              ? () => setState(() => _menuOpen = !_menuOpen)
              : null,
          expanded: menu,
        ),
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              ExcludeFocus(
                excluding: menu,
                child: ExcludeSemantics(excluding: menu, child: content),
              ),
              if (menu) ...[
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _back,
                  excludeFromSemantics: true,
                  child: const SizedBox.expand(),
                ),
                Align(
                  alignment: Alignment.topCenter,
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
              ],
            ],
          ),
        ),
      ],
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        // Hidden with its header and mini player, so its lists keep their
        // size and Back shows the screen as it was.
        Visibility(visible: player == null, maintainState: true, child: screen),
        if (player != null)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(context, player, onBack: _back),
              Expanded(child: _pageBody(context, player)),
            ],
          ),
      ],
    );
  }

  Widget _desktopBody(BuildContext context) {
    final podcast = _podcastPage;
    final settings = _settingsPage;
    final listPage = settings ?? podcast;
    final last = _pages.lastOrNull;
    final detail = last == listPage ? null : last;
    final width = MediaQuery.sizeOf(context).width;
    final navWidth = _desktopNavWidth(context).clamp(220.0, width - 480);
    final listWidth = math.min(360.0, (width - navWidth) * 0.46);
    final strings = context.strings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: navWidth,
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
                                  selected:
                                      settings == null && _section == section,
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
                          selected: settings != null,
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
                width: listWidth,
                child: _columnDivider(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _header(
                        context,
                        listPage,
                        onBack: listPage == null
                            ? (_section == LibrarySection.search
                                  ? () => setState(_closeGlobalSearch)
                                  : null)
                            : () => setState(() {
                                if (!_closePodcastSearchOn(listPage)) {
                                  _pages.removeRange(
                                    _pages.indexOf(listPage),
                                    _pages.length,
                                  );
                                }
                              }),
                      ),
                      Expanded(
                        child: listPage == null
                            ? _sectionBody(context, desktop: true)
                            : _pageBody(context, listPage, desktop: true),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: detail == null
                    ? (settings != null ||
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

  double _desktopNavWidth(BuildContext context) {
    final style = Theme.of(context).textTheme.labelLarge!.merge(rowTitleStyle);
    final painter = TextPainter(
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    );
    var widest = 0.0;
    for (final section in _sections) {
      painter.text = TextSpan(text: section.label(context), style: style);
      painter.layout();
      widest = math.max(widest, painter.width);
    }
    painter.dispose();
    return widest.ceilToDouble() + 33;
  }

  Widget _columnDivider(Widget child) => DecoratedBox(
    position: DecorationPosition.foreground,
    decoration: const BoxDecoration(border: Border(right: BorderSide())),
    child: child,
  );

  Widget _header(
    BuildContext context,
    _Page? page, {
    VoidCallback? onBack,
    VoidCallback? onMenu,
    bool expanded = false,
  }) {
    final strings = context.strings;
    final podcast = switch (page) {
      (screen: _Screen.podcast, id: final int id) =>
        widget.services.library.podcast(id),
      _ => null,
    };
    final canRefresh =
        podcast?.subscribed == true ||
        (page == null && _section == LibrarySection.newEpisodes);
    return EinkHeader(
      page == null ? _section.label(context) : _title(context, page),
      onBack: onBack,
      onMenu: onMenu,
      expanded: expanded,
      subtitle: canRefresh ? _refreshSubtitle(context, podcast) : null,
      actions: [
        if (canRefresh)
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: strings.refresh,
            onPressed: () => _refresh.request(podcastId: podcast?.id),
          ),
        if (podcast != null)
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: strings.aboutPodcast,
            onPressed: () => _open(_Screen.about, podcast.id),
          ),
      ],
    );
  }

  String? _refreshSubtitle(BuildContext context, Podcast? podcast) {
    final strings = context.strings;
    final id = podcast?.id;
    if (_refresh.runningFor(id)) return strings.refreshing;
    final last = _refresh.lastLoadedFor(id);
    // A failing feed's error box already explains the wait; keep its date.
    if (_refresh.requestedFor(id) &&
        !(podcast?.lastError?.isNotEmpty ?? false)) {
      return strings.refreshRequested;
    }
    if (last == null) return null;
    return DateUtils.isSameDay(last.toLocal(), DateTime.now())
        ? strings.loadedAt(clockText(strings, last))
        : strings.loadedOn(dateText(strings, last));
  }

  String _title(BuildContext context, _Page page) {
    final library = widget.services.library;
    final strings = context.strings;
    return switch (page.screen) {
      _Screen.episode =>
        _episodePodcastTitle(page.id!) ?? strings.episodeMissing,
      _Screen.podcast =>
        library.podcast(page.id!)?.title ?? strings.podcastMissing,
      _Screen.player => switch (_playback.target) {
        Episode(:final podcastId) =>
          library.podcast(podcastId)?.title ?? strings.player,
        null => strings.player,
      },
      _Screen.about => strings.aboutPodcast,
      _Screen.add => strings.addPodcast,
      _Screen.settings => strings.settings,
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

  int? get _selectedEpisodeId {
    final last = _pages.lastOrNull;
    return last?.screen == _Screen.episode ? last?.id : null;
  }

  Widget _sectionBody(BuildContext context, {bool desktop = false}) {
    final kind = switch (_section) {
      LibrarySection.inProgress => EpisodeListKind.inProgress,
      LibrarySection.queue => EpisodeListKind.queue,
      LibrarySection.newEpisodes => EpisodeListKind.newEpisodes,
      _ => null,
    };
    if (kind != null) {
      final canRefresh = kind == EpisodeListKind.newEpisodes;
      return EpisodeList(
        kind: kind,
        episodes: _sectionEpisodes(),
        playback: _playback,
        onOpen: _openEpisode,
        onMenu: _openEpisodeMenu,
        onRefresh: canRefresh ? _refresh.request : null,
        desktop: desktop,
        selectedId: _selectedEpisodeId,
        actions: [
          if (canRefresh && _refresh.failedFor(null))
            EinkError(context.strings.refreshFailed, inset: true),
        ],
      );
    }
    return switch (_section) {
      LibrarySection.podcasts => PodcastList(
        playback: _playback,
        onOpen: _openPodcast,
        onMenu: _openPodcastMenu,
        onAdd: () => _open(_Screen.add),
        desktop: desktop,
      ),
      LibrarySection.search => _searchBody(context, desktop: desktop),
      LibrarySection.downloads => DownloadsPage(
        playback: _playback,
        onOpen: _openEpisode,
        onMenu: _openEpisodeMenu,
      ),
      _ => const SizedBox.shrink(),
    };
  }

  Widget _settingsBody() => SettingsPage(
    playback: _playback,
    onServer: () => _open(_Screen.server),
    onFeeds: () => _open(_Screen.feeds),
    onOpml: () => _open(_Screen.opml),
  );

  Widget _searchBody(BuildContext context, {required bool desktop}) {
    final strings = context.strings;
    final words = _globalSearch.words;
    final library = widget.services.library;
    final episodes = _globalEpisodes();
    final podcasts = [
      if (words.isNotEmpty)
        for (final podcast in library.podcasts)
          if (podcastTitleMatches(podcast.title, words)) podcast,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PodcastSearchField(
          search: _globalSearch,
          hint: strings.searchHint,
          onChanged: (input) => _globalSearch.change(input, _searchAll),
          onClose: () => setState(_closeGlobalSearch),
        ),
        if (words.isNotEmpty)
          Expanded(
            // A new query starts at the top; Back from a result keeps its place.
            child: EpisodeList(
              key: PageStorageKey(('search', words.join(' '))),
              kind: EpisodeListKind.search,
              episodes: episodes,
              playback: _playback,
              onOpen: _openEpisode,
              onMenu: _openEpisodeMenu,
              desktop: desktop,
              selectedId: _selectedEpisodeId,
              emptyMessage: _globalSearch.loading ? strings.syncLoading : null,
              headerSlivers: [
                if (podcasts.isNotEmpty) ...[
                  SliverToBoxAdapter(child: listHeading(strings.podcasts)),
                  PodcastList.rows(
                    podcasts,
                    onOpen: _openPodcast,
                    onMenu: _openPodcastMenu,
                    desktop: desktop,
                  ),
                ],
                SliverToBoxAdapter(child: listHeading(strings.episodes)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _podcastBody(BuildContext context, int id, {required bool desktop}) {
    final library = widget.services.library;
    final podcast = library.podcast(id);
    final strings = context.strings;
    if (podcast == null) return PageMessage(strings.podcastMissing);
    final searching = _searchPodcastId == id;
    return EpisodeList(
      key: PageStorageKey(('podcast', id)),
      kind: EpisodeListKind.podcast,
      episodes: _podcastEpisodes(id),
      playback: _playback,
      onOpen: _openEpisode,
      onMenu: _openEpisodeMenu,
      onRefresh: podcast.subscribed
          ? () => _refresh.request(podcastId: id)
          : null,
      desktop: desktop,
      selectedId: _selectedEpisodeId,
      emptyMessage: searching && _podcastSearch.words.isNotEmpty
          ? (_podcastSearch.loading
                ? strings.syncLoading
                : strings.noMatchingEpisodes)
          : null,
      actions: [
        if (searching)
          PodcastSearchField(
            search: _podcastSearch,
            hint: strings.searchThisPodcast,
            onChanged: (input) => _podcastSearch.change(
              input,
              (query) => widget.services.api.searchPodcast(id, query),
            ),
            onClose: () => setState(_closePodcastSearch),
          )
        else
          EinkRow(
            title: strings.searchThisPodcast,
            compact: true,
            underlined: true,
            leading: const Icon(Icons.search),
            onPressed: () => _openPodcastSearch(id),
          ),
        if (podcast.subscribed && _refresh.failedFor(id))
          EinkError(strings.refreshFailed, inset: true),
        if (podcast.lastError?.isNotEmpty ?? false)
          Padding(
            padding: const EdgeInsets.all(8),
            child: FeedStatusText(podcast, showLastLoaded: !podcast.subscribed),
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
      case _Screen.settings:
        return _settingsBody();
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
