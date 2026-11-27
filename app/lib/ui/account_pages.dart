import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/api.dart';
import '../core/models.dart';
import '../core/services.dart';
import 'eink_widgets.dart';
import 'library_views.dart' show PodcastThumbnail, rowError;
import 'theme.dart';

bool _validAddress(String address) {
  final url = Uri.tryParse(address);
  return url != null &&
      (url.scheme == 'http' || url.scheme == 'https') &&
      url.host.isNotEmpty &&
      url.userInfo.isEmpty;
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.services});

  final AppServices services;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  late final _server = TextEditingController(
    text:
        widget.services.settings.lastServerAddress ??
        widget.services.sync.serverUrl,
  );
  final _name = TextEditingController();
  final _password = TextEditingController();
  final _device = TextEditingController();
  bool _prefilled = false;
  bool _busy = false;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_prefilled) return;
    _prefilled = true;
    final saved = widget.services.sync.deviceName;
    final strings = context.strings;
    _device.text = saved.isNotEmpty
        ? saved
        : switch (Theme.of(context).platform) {
            TargetPlatform.linux => strings.defaultLinuxDevice,
            TargetPlatform.android => strings.defaultAndroidDevice,
            _ => strings.defaultDevice,
          };
  }

  Future<void> _login() async {
    if (_busy) return;
    final strings = context.strings;
    final address = _server.text.trim();
    final name = _name.text.trim();
    final password = _password.text;
    final device = _device.text.trim();
    if (!_validAddress(address) ||
        Uri.parse(address).hasQuery ||
        Uri.parse(address).hasFragment) {
      setState(() => _error = strings.invalidServerUrl);
      return;
    }
    if (name.isEmpty || password.isEmpty || device.isEmpty) {
      setState(() => _error = strings.loginMissing);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.services.sync.login(
        serverUrl: address,
        username: name,
        password: password,
        deviceName: device,
      );
    } on OfflineException {
      _error = strings.loginOffline;
    } on ApiException catch (error) {
      _error = switch (error.statusCode) {
        401 => strings.loginRejected,
        429 => strings.loginRateLimit,
        _ => strings.loginFailed,
      };
    } on Exception {
      _error = strings.loginFailed;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _server.dispose();
    _name.dispose();
    _password.dispose();
    _device.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            EinkHeader(strings.signInTitle),
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: PageList(
                    inset: true,
                    children: [
                      Text(strings.loginHelp, style: detailStyle),
                      const SizedBox(height: 16),
                      AutofillGroup(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            LabeledField(
                              key: const ValueKey('login-address'),
                              label: strings.serverAddress,
                              controller: _server,
                              keyboardType: TextInputType.url,
                              hint: 'https://…',
                              onChanged: (text) =>
                                  widget.services.settings.lastServerAddress =
                                      text,
                              textInputAction: TextInputAction.next,
                              enabled: !_busy,
                            ),
                            LabeledField(
                              key: const ValueKey('login-name'),
                              label: strings.username,
                              controller: _name,
                              textInputAction: TextInputAction.next,
                              enabled: !_busy,
                            ),
                            LabeledField(
                              key: const ValueKey('login-password'),
                              label: strings.password,
                              controller: _password,
                              obscure: true,
                              textInputAction: TextInputAction.next,
                              enabled: !_busy,
                            ),
                            LabeledField(
                              key: const ValueKey('login-device'),
                              label: strings.deviceName,
                              controller: _device,
                              enabled: !_busy,
                              onSubmitted: (_) => _login(),
                            ),
                          ],
                        ),
                      ),
                      Text(strings.deviceNameHelp, style: detailStyle),
                      const SizedBox(height: 12),
                      if (_error case final String error) ...[
                        EinkError(error),
                        const SizedBox(height: 8),
                      ],
                      EinkButton(
                        _busy ? strings.signingIn : strings.signIn,
                        primary: true,
                        minHeight: 52,
                        onPressed: _login,
                        alternatives: [strings.signingIn, strings.signIn],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AddPodcastPage extends StatefulWidget {
  const AddPodcastPage({
    super.key,
    required this.services,
    required this.onAdded,
    this.query = '',
  });

  final AppServices services;
  final ValueChanged<Podcast> onAdded;
  final String query;

  @override
  State<AddPodcastPage> createState() => _AddPodcastPageState();
}

class _AddPodcastPageState extends State<AddPodcastPage> with ActionTapGuard {
  late final _query = TextEditingController(text: widget.query);
  final _address = TextEditingController();
  List<DirectoryPodcast>? _results;
  bool _searching = false;
  bool _adding = false;
  String? _addingResult;
  String? _searchError;
  String? _addressError;
  final _resultErrors = <String, String>{};

  bool get _busy => _searching || _adding;

  @override
  void initState() {
    super.initState();
    if (widget.query.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_search());
      });
    }
  }

  Future<void> _search() async {
    if (_busy) return;
    final strings = context.strings;
    final query = _query.text.trim();
    if (query.runes.length < 2) {
      setState(() => _searchError = strings.directoryTooShort);
      return;
    }
    _releaseField();
    setState(() {
      _searching = true;
      _results = null;
      _searchError = null;
      _resultErrors.clear();
    });
    try {
      final results = await widget.services.api.searchDirectory(query);
      if (mounted) _results = results;
    } on Object catch (error) {
      if (mounted) {
        _searchError = switch (error) {
          OfflineException() => strings.directoryOffline,
          ApiException(statusCode: 404) => strings.directoryOff,
          _ => strings.directoryFailed,
        };
      }
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _addByAddress() async {
    if (_busy) return;
    final url = _address.text.trim();
    if (!_validAddress(url)) {
      setState(() => _addressError = context.strings.invalidFeedUrl);
      return;
    }
    await _subscribe(url);
  }

  Future<void> _addResult(DirectoryPodcast result) => guardAction(() async {
    if (_busy) return;
    final strings = context.strings;
    if (!result.subscribed) {
      final confirmed = await confirmAction(
        context,
        title: strings.subscribeTitle,
        message: result.author.isEmpty
            ? result.title
            : '${result.title}\n${result.author}',
        action: strings.addPodcast,
      );
      if (!mounted || !confirmed) return;
    }
    await _subscribe(result.feedUrl, fromDirectory: true);
  });

  Future<void> _subscribe(String url, {bool fromDirectory = false}) async {
    final strings = context.strings;
    _releaseField();
    setState(() {
      _adding = true;
      if (fromDirectory) {
        _addingResult = url;
        _resultErrors.remove(url);
      } else {
        _addressError = null;
      }
    });
    try {
      final podcast = await widget.services.library.subscribe(url);
      if (mounted) widget.onAdded(podcast);
    } on Object catch (error) {
      if (!mounted) return;
      final unavailable = error is ApiException && error.statusCode == 422;
      if (fromDirectory) {
        _resultErrors[url] = unavailable
            ? strings.feedUnavailable
            : strings.subscribeFailed;
      } else {
        _addressError = unavailable
            ? strings.invalidFeed
            : strings.subscribeFailed;
      }
    } finally {
      if (mounted) {
        setState(() {
          _adding = false;
          _addingResult = null;
        });
      }
    }
  }

  // Closes the keyboard but keeps focus inside the page, where the Linux keys are handled.
  void _releaseField() => FocusScope.of(context).focusedChild?.unfocus();

  @override
  void dispose() {
    _query.dispose();
    _address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    final statusStyle = detailStyle.copyWith(fontWeight: FontWeight.w700);
    return PageList(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LabeledField(
                label: strings.directorySearch,
                controller: _query,
                textInputAction: TextInputAction.search,
                enabled: !_busy,
                onSubmitted: (_) => _search(),
              ),
              EinkButton(
                _searching ? strings.searching : strings.search,
                primary: true,
                minHeight: 52,
                onPressed: _search,
                alternatives: [strings.search, strings.searching],
              ),
              if (_searchError case final String error) ...[
                const SizedBox(height: 8),
                EinkError(error),
              ] else if (_results?.isEmpty == true) ...[
                const SizedBox(height: 8),
                Text(strings.directoryEmpty, style: detailStyle),
              ],
            ],
          ),
        ),
        for (final result in _results ?? const <DirectoryPodcast>[])
          EinkRow(
            title: result.title,
            leading: PodcastThumbnail(result.imageUrl, persist: false),
            topAligned: true,
            details: [
              if (result.author.isNotEmpty)
                Text(result.author, style: detailStyle),
              if (result.subscribed)
                Text(strings.subscribedMark, style: statusStyle),
              if (result.feedUrl == _addingResult)
                Text(strings.addingPodcast, style: statusStyle),
              if (_resultErrors[result.feedUrl] case final String error)
                rowError(error),
            ],
            trailing: result.subscribed
                ? null
                : Icon(
                    Icons.add,
                    size: 24,
                    applyTextScaling: true,
                    semanticLabel: strings.addPodcast,
                  ),
            onPressed: () => _addResult(result),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 24, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(strings.addPodcastHelp, style: buttonLabelStyle),
              const SizedBox(height: 16),
              LabeledField(
                label: strings.feedAddress,
                controller: _address,
                keyboardType: TextInputType.url,
                enabled: !_busy,
                onSubmitted: (_) => _addByAddress(),
              ),
              if (_addressError case final String error) ...[
                EinkError(error),
                const SizedBox(height: 8),
              ],
              EinkButton(
                _adding && _addingResult == null
                    ? strings.addingPodcast
                    : strings.addPodcast,
                primary: true,
                minHeight: 52,
                onPressed: _addByAddress,
                alternatives: [strings.addPodcast, strings.addingPodcast],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
