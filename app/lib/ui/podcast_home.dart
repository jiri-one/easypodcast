import 'dart:async';

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/library.dart' show BulkDismissNeedsConnection;
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
import 'queue_edits.dart';
import 'settings_pages.dart';
import 'sync_feedback.dart';
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
  static const _sortPreference = 'alphabeticalPodcasts';
  static const _redrawPreference = 'playerRedrawSeconds';

  late final _playback = PlaybackActions(widget.services);
  late final _refresh = FeedRefresh(widget.services);
  late final _queueEdits = QueueEdits(widget.services.library);
  late final _syncFeedback = SyncFeedback(widget.services.sync.status);
  late final _updates = Listenable.merge([
    widget.services.library,
    widget.services.settings,
    _playback,
    _refresh,
    _queueEdits,
  ]);
  final _pages = <_Page>[];
  final _requestedDownloads = <int>{};
  final _scrollPositions = PageStorageBucket();

  LibrarySection _section = LibrarySection.inProgress;
  bool _menuOpen = false;
  bool _episodeMenuOpen = false;
  bool _alphabetical = false;
  bool _sortEdited = false;
  bool _sortFailed = false;
  int _redrawSeconds = 1;
  bool _redrawEdited = false;
  bool _redrawFailed = false;

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
      if (!_linux || section != LibrarySection.downloads) section,
  ];

  @override
  void initState() {
    super.initState();
    unawaited(_loadPreferences());
  }

  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      final sorted = _sortEdited
          ? _alphabetical
          : prefs.getBool(_sortPreference) ?? false;
      final savedRedraw = prefs.getInt(_redrawPreference);
      final redraw = !_redrawEdited && (savedRedraw == 10 || savedRedraw == 60)
          ? savedRedraw!
          : _redrawSeconds;
      if (sorted == _alphabetical && redraw == _redrawSeconds) return;
      setState(() {
        _alphabetical = sorted;
        _redrawSeconds = redraw;
      });
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

  Future<void> _setRedrawSeconds(int seconds) async {
    _redrawEdited = true;
    setState(() => _redrawSeconds = seconds);
    var saved = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      saved = await prefs.setInt(_redrawPreference, seconds);
    } on Exception {
      saved = false;
    }
    if (mounted && seconds == _redrawSeconds && _redrawFailed == saved) {
      setState(() => _redrawFailed = !saved);
    }
  }

  @override
  void dispose() {
    _queueEdits.dispose();
    _syncFeedback.dispose();
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
    _menuOpen = false;
    if (section == LibrarySection.settings) {
      if (_settingsPage == null) {
        _pages.add((screen: _Screen.settings, id: null));
      }
    } else {
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
      await EpisodeActions(
        episode: episode,
        playback: _playback,
        downloadsAvailable: !_linux,
        queueEdits: _queueEdits,
        onTrackDownload: _requestedDownloads.add,
      ).showMenu(
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
        builder: (context) => EinkDialogPanel(
          title: error is BulkDismissNeedsConnection
              ? context.strings.dismissOlderOffline
              : context.strings.actionFailed,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.strings.close, style: buttonLabelStyle),
            ),
          ],
        ),
      );
    } finally {
      _episodeMenuOpen = false;
    }
  }

  void _openPodcast(Podcast podcast) => setState(() {
    _pages.removeWhere((page) => page.screen == _Screen.add);
    _pages.add((screen: _Screen.podcast, id: podcast.id));
  });

  List<Episode> _activeEpisodeList() {
    if (_settingsPage != null) return const [];
    final podcast = _podcastPage;
    return podcast == null
        ? _sectionEpisodes()
        : widget.services.library.episodesOf(podcast.id!);
  }

  List<Episode> _sectionEpisodes() {
    final library = widget.services.library;
    return switch (_section) {
      LibrarySection.inProgress => library.inProgress,
      LibrarySection.queue => _queueEdits.episodes,
      LibrarySection.newEpisodes => _recentNewEpisodes(),
      _ => const [],
    };
  }

  List<Episode> _recentNewEpisodes() {
    final cutoff = DateTime.now().subtract(const Duration(days: 30));
    return widget.services.library
        .newEpisodes(limit: 0x7fffffff)
        .takeWhile((episode) => episode.publishedAt?.isBefore(cutoff) == false)
        .toList(growable: false);
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
    return SyncFeedbackScope(
      notifier: _syncFeedback,
      child: ListenableBuilder(
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
                ? Focus(
                    autofocus: true,
                    onKeyEvent: _desktopKey,
                    child: content,
                  )
                : content,
          );
        },
      ),
    );
  }

  Widget _phoneBody(BuildContext context) {
    final page = _pages.lastOrNull;
    final podcast = _podcastPage;
    final settings = _settingsPage;
    return Stack(
      fit: StackFit.expand,
      children: [
        Visibility(
          visible: page == null,
          maintainState: true,
          child: _phoneFrame(
            context,
            title: _section.label(context),
            body: _sectionBody(context),
            switcher: true,
            mini: true,
          ),
        ),
        if (podcast != null)
          Visibility(
            visible: page == podcast,
            maintainState: true,
            child: _phoneFrame(
              context,
              title: _title(context, podcast),
              body: _podcastBody(context, podcast.id!, desktop: false),
              onBack: _back,
              mini: true,
            ),
          ),
        if (settings != null)
          Visibility(
            visible: page == settings,
            maintainState: true,
            child: _phoneFrame(
              context,
              title: context.strings.settings,
              body: _settingsBody(),
              onBack: _back,
            ),
          ),
        if (page != null && page != podcast && page != settings)
          _phoneFrame(
            context,
            title: _title(context, page),
            body: _pageBody(context, page),
            onBack: _back,
          ),
      ],
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
                            : () => setState(
                                () => _pages.removeRange(
                                  _pages.indexOf(listPage),
                                  _pages.length,
                                ),
                              ),
                      ),
                      Expanded(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Visibility(
                              visible: listPage == null,
                              maintainState: true,
                              child: _sectionBody(context, desktop: true),
                            ),
                            if (podcast != null)
                              Visibility(
                                visible: settings == null,
                                maintainState: true,
                                child: _podcastBody(
                                  context,
                                  podcast.id!,
                                  desktop: true,
                                ),
                              ),
                            if (settings != null) _settingsBody(),
                          ],
                        ),
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
        DesktopPlayer(
          playback: _playback,
          onEpisode: _openEpisode,
          redrawSeconds: _redrawSeconds,
        ),
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
        downloadsAvailable: !_linux,
        queueEdits: _queueEdits,
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
        alphabetical: _alphabetical,
        onOpen: _openPodcast,
        onAdd: () => _open(_Screen.add),
        desktop: desktop,
      ),
      LibrarySection.downloads => DownloadsPage(
        playback: _playback,
        requestedIds: _requestedDownloads,
        queueEdits: _queueEdits,
        onOpen: _openEpisode,
        onMenu: _openEpisodeMenu,
      ),
      _ => const SizedBox.shrink(),
    };
  }

  Widget _settingsBody() => SettingsPage(
    playback: _playback,
    alphabetical: _alphabetical,
    preferencesFailed: _sortFailed || _redrawFailed,
    onAlphabetical: _toggleSort,
    redrawSeconds: _redrawSeconds,
    onRedrawSeconds: _setRedrawSeconds,
    downloadsAvailable: !_linux,
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
    return EpisodeList(
      key: PageStorageKey(('podcast', id)),
      kind: EpisodeListKind.podcast,
      episodes: library.episodesOf(id),
      playback: _playback,
      onOpen: _openEpisode,
      onMenu: _openEpisodeMenu,
      desktop: desktop,
      downloadsAvailable: !_linux,
      queueEdits: _queueEdits,
      selectedId: last?.screen == _Screen.episode ? last?.id : null,
      actions: [
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
          downloadsAvailable: !_linux,
          queueEdits: _queueEdits,
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
          redrawSeconds: _redrawSeconds,
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
