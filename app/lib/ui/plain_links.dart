import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'eink_widgets.dart';

class PlainLinks extends StatefulWidget {
  const PlainLinks(this.text, {super.key, this.style = detailStyle});

  final String text;
  final TextStyle style;

  @override
  State<PlainLinks> createState() => _PlainLinksState();
}

class _PlainLinksState extends State<PlainLinks> {
  static final _url = RegExp(
    r'''https?://[^\s<>"“”„]+''',
    caseSensitive: false,
  );
  static final _punctuation = RegExp(r'[.,;:!?]+$');
  final _recognizers = <TapGestureRecognizer>[];
  late List<TextSpan> _spans;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _parse();
  }

  @override
  void didUpdateWidget(PlainLinks oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _failed = false;
      _parse();
    }
  }

  String _trimUrl(String raw) {
    var url = raw.replaceFirst(_punctuation, '');
    for (final (open, close) in [('(', ')'), ('[', ']')]) {
      if (url.endsWith(close) &&
          close.allMatches(url).length > open.allMatches(url).length) {
        url = url.substring(0, url.length - 1);
      }
    }
    return url;
  }

  void _parse() {
    _disposeRecognizers();
    _spans = [];
    var index = 0;
    for (final match in _url.allMatches(widget.text)) {
      final text = _trimUrl(match[0]!);
      final uri = Uri.tryParse(text);
      if (uri == null || uri.host.isEmpty) continue;
      _spans.add(TextSpan(text: widget.text.substring(index, match.start)));
      final recognizer = TapGestureRecognizer()..onTap = () => _open(uri);
      _recognizers.add(recognizer);
      _spans.add(
        TextSpan(
          text: text,
          style: underlineStyle,
          recognizer: recognizer,
          mouseCursor: SystemMouseCursors.click,
        ),
      );
      index = match.start + text.length;
    }
    _spans.add(TextSpan(text: widget.text.substring(index)));
  }

  Future<void> _open(Uri url) async {
    var opened = false;
    try {
      opened = await launchUrl(url, mode: LaunchMode.externalApplication);
    } on Exception {
      opened = false;
    }
    if (mounted && _failed == opened) setState(() => _failed = !opened);
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text.rich(TextSpan(children: _spans), style: widget.style),
      if (_failed) ProblemBox(context.strings.linkFailed),
    ],
  );
}
