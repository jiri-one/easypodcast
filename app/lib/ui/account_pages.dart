import 'package:material_ui/material_ui.dart';

import '../core/api.dart';
import '../core/models.dart';
import '../core/services.dart';
import 'eink_widgets.dart';
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
    text: widget.services.settings.serverUrl,
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
    final saved = widget.services.settings.deviceName;
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
                              enabled: !_busy,
                            ),
                            LabeledField(
                              key: const ValueKey('login-name'),
                              label: strings.username,
                              controller: _name,
                              enabled: !_busy,
                            ),
                            LabeledField(
                              key: const ValueKey('login-password'),
                              label: strings.password,
                              controller: _password,
                              obscure: true,
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
  });

  final AppServices services;
  final ValueChanged<Podcast> onAdded;

  @override
  State<AddPodcastPage> createState() => _AddPodcastPageState();
}

class _AddPodcastPageState extends State<AddPodcastPage> {
  final _address = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _add() async {
    if (_busy) return;
    final strings = context.strings;
    final url = _address.text.trim();
    if (!_validAddress(url)) {
      setState(() => _error = strings.invalidFeedUrl);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final podcast = await widget.services.library.subscribe(url);
      if (mounted) widget.onAdded(podcast);
    } on ApiException catch (error) {
      _error = error.statusCode == 422
          ? strings.invalidFeed
          : strings.subscribeFailed;
    } on Exception {
      _error = strings.subscribeFailed;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    return PageList(
      inset: true,
      children: [
        Text(strings.addPodcastHelp, style: buttonLabelStyle),
        const SizedBox(height: 16),
        LabeledField(
          label: strings.feedAddress,
          controller: _address,
          keyboardType: TextInputType.url,
          enabled: !_busy,
          onSubmitted: (_) => _add(),
        ),
        if (_error case final String error) ...[
          EinkError(error),
          const SizedBox(height: 8),
        ],
        EinkButton(
          _busy ? strings.addingPodcast : strings.addPodcast,
          primary: true,
          minHeight: 52,
          onPressed: _add,
          alternatives: [strings.addPodcast, strings.addingPodcast],
        ),
      ],
    );
  }
}
