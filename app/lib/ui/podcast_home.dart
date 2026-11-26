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
import 'feed_refresh.dart';
import 'library_views.dart';
import 'playback_actions.dart';
import 'player_views.dart';
import 'podcast_search.dart';
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
  late final _updates = Listenable.merge([
    widget.services.library,
    widget.services.settings,
    _playback,
    _refresh,
    widget.services.sync.status,
  ]);
  final _pages = <_Page>[];
  final _scrollPositions = PageStorageBucket();
  final _searchText = TextEditingController();
  final _searchFocus = FocusNode();
  int? _searchPodcastId;
  Timer? _searchTimer;
  List<String> _searchWords = const [];
  // Null while the server searches the descriptions.
  Set<int>? _descriptionMatches = const {};

  LibrarySection _section = LibrarySection.inProgress;
  bool _menuOpen = false;
  bool _episodeMenuOpen = false;
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
    _searchTimer?.cancel();
    _searchText.dispose();
    _searchFocus.dispose();
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
        if (!_closeSearchOn(page)) _pages.removeLast();
      } else {
        _section = LibrarySection.inProgress;
      }
    });
  }

  void _switchList(LibrarySection section) => setState(() {
    _menuOpen = false;
    if (section == LibrarySection.settings) {
      if (_settingsPage == null) {
        _pages.add((screen: _Screen.settings, id: null));
      }
    } else {
      _closeSearch();
      _section = section;
      _pages.clear();
    }
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

  Future<void> _openEpisodeMenu(Episode episode) async {
    if (_episodeMenuOpen) return;
    _episodeMenuOpen = true;
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
      _episodeMenuOpen = false;
    }
  }

  void _openPodcast(Podcast podcast) => setState(() {
    _closeSearch();
    _pages.removeWhere((page) => page.screen == _Screen.add);
    _pages.add((screen: _Screen.podcast, id: podcast.id));
  });

  void _openSearch(int podcastId) {
    setState(() => _searchPodcastId = podcastId);
    _searchFocus.requestFocus();
  }

  void _closeSearch() {
    if (_searchPodcastId == null) return;
    _searchTimer?.cancel();
    _searchFocus.unfocus();
    _searchText.clear();
    _searchPodcastId = null;
    _searchWords = const [];
    _descriptionMatches = const {};
  }

  bool _closeSearchOn(_Page page) {
    if (page.screen != _Screen.podcast || _searchPodcastId != page.id) {
      return false;
    }
    _closeSearch();
    return true;
  }

  void _searchChanged(String input) {
    final id = _searchPodcastId;
    if (id == null) return;
    final words = podcastSearchWords(input);
    final askServer =
        words.length > 1 || (words.isNotEmpty && words.single.runes.length > 1);
    _searchTimer?.cancel();
    setState(() {
      _searchWords = words;
      _descriptionMatches = askServer ? null : const {};
    });
    if (!askServer) return;
    final api = widget.services.api;
    _searchTimer = Timer(const Duration(milliseconds: 400), () async {
      var matches = const <int>{};
      try {
        matches = (await api.searchPodcast(id, input.trim())).toSet();
      } on Exception {
        // Local matches stay available when the server cannot answer.
      }
      if (mounted && identical(_searchWords, words)) {
        setState(() => _descriptionMatches = matches);
      }
    });
  }

  List<Episode> _podcastEpisodes(int id) {
    final episodes = widget.services.library.episodesOf(id);
    return _searchPodcastId == id
        ? matchPodcastEpisodes(
            episodes,
            _searchWords,
            _descriptionMatches ?? const {},
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
      if (_searchFocus.hasFocus) {
        setState(_closeSearch);
      } else {
        _back();
      }
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
              ? Focus(autofocus: true, onKeyEvent: _desktopKey, child: content)
              : content,
        );
      },
    );
  }

  Widget _phoneBody(BuildContext context) {
    final page = _pages.lastOrNull;
    return _phoneFrame(
      context,
      title: page == null ? _section.label(context) : _title(context, page),
      body: page == null ? _sectionBody(context) : _pageBody(context, page),
      onBack: page == null ? null : _back,
      switcher: page == null,
      mini: page == null || page.screen == _Screen.podcast,
    );
  }

  Widget _phoneFrame(
    BuildContext context, {
    required String title,
    required Widget body,
    VoidCallback? onBack,
    bool switcher = false,
    bool mini = false,
  }) {
    final menu = switcher && _menuOpen;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: body),
        if (mini)
          MiniPlayer(playback: _playback, onOpen: () => _open(_Screen.player)),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        EinkHeader(
          title,
          onBack: onBack,
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
                      EinkHeader(
                        listPage == null
                            ? _section.label(context)
                            : _title(context, listPage),
                        onBack: listPage == null
                            ? null
                            : () => setState(() {
                                if (!_closeSearchOn(listPage)) {
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

  Widget _sectionBody(BuildContext context, {bool desktop = false}) {
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
        episodes: _sectionEpisodes(),
        playback: _playback,
        onOpen: _openEpisode,
        onMenu: _openEpisodeMenu,
        desktop: desktop,
        selectedId: selected?.screen == _Screen.episode ? selected?.id : null,
        actions: [
          if (_section == LibrarySection.newEpisodes)
            RefreshRow(refresh: _refresh, lastLoaded: _refresh.lastLoaded),
        ],
      );
    }
    return switch (_section) {
      LibrarySection.podcasts => PodcastList(
        playback: _playback,
        onOpen: _openPodcast,
        onAdd: () => _open(_Screen.add),
        desktop: desktop,
      ),
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

  Widget _podcastBody(BuildContext context, int id, {required bool desktop}) {
    final library = widget.services.library;
    final podcast = library.podcast(id);
    final strings = context.strings;
    if (podcast == null) return PageMessage(strings.podcastMissing);
    final last = _pages.lastOrNull;
    final searching = _searchPodcastId == id;
    return EpisodeList(
      key: PageStorageKey(('podcast', id)),
      kind: EpisodeListKind.podcast,
      episodes: _podcastEpisodes(id),
      playback: _playback,
      onOpen: _openEpisode,
      onMenu: _openEpisodeMenu,
      desktop: desktop,
      selectedId: last?.screen == _Screen.episode ? last?.id : null,
      emptyMessage: searching && _searchWords.isNotEmpty
          ? (_descriptionMatches == null
                ? strings.syncLoading
                : strings.noMatchingEpisodes)
          : null,
      actions: [
        if (searching)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
            child: Semantics(
              label: strings.searchThisPodcast,
              child: TextField(
                controller: _searchText,
                focusNode: _searchFocus,
                onChanged: _searchChanged,
                textInputAction: TextInputAction.search,
                showCursor: false,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  hintText: strings.searchThisPodcast,
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.clear),
                    tooltip: strings.clearSearch,
                    onPressed: () => setState(_closeSearch),
                  ),
                ),
              ),
            ),
          )
        else
          EinkRow(
            title: strings.searchThisPodcast,
            compact: true,
            underlined: true,
            leading: const Icon(Icons.search),
            onPressed: () => _openSearch(id),
          ),
        if (podcast.subscribed)
          RefreshRow(
            refresh: _refresh,
            lastLoaded: podcast.lastSuccessAt,
            podcastId: id,
          ),
        if (podcast.lastError?.isNotEmpty ?? false)
          Padding(
            padding: const EdgeInsets.all(8),
            child: FeedStatusText(podcast, showLastLoaded: !podcast.subscribed),
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
