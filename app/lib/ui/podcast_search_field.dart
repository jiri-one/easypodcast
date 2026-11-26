import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'eink_widgets.dart';
import 'podcast_search.dart';

class EpisodeSearch extends ChangeNotifier {
  final text = TextEditingController();
  final focus = FocusNode();
  Timer? _timer;
  List<String> _words = const [];
  Set<int>? _matches = const {};

  List<String> get words => _words;
  Set<int> get matches => _matches ?? const {};
  bool get loading => _matches == null;

  void change(String input, Future<List<int>> Function(String) request) {
    final words = podcastSearchWords(input);
    final askServer =
        words.length > 1 || (words.isNotEmpty && words.single.runes.length > 1);
    _timer?.cancel();
    _words = words;
    _matches = askServer ? null : const {};
    notifyListeners();
    if (!askServer) return;
    _timer = Timer(const Duration(milliseconds: 400), () async {
      var matches = const <int>{};
      try {
        matches = (await request(input.trim())).toSet();
      } on Exception {
        // Keep local results if the server is unavailable.
      }
      if (identical(_words, words)) {
        _matches = matches;
        notifyListeners();
      }
    });
  }

  void reset() {
    _timer?.cancel();
    _words = const [];
    _matches = const {};
    focus.unfocus();
    text.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _words = const [];
    focus.dispose();
    text.dispose();
    super.dispose();
  }
}

class PodcastSearchField extends StatelessWidget {
  const PodcastSearchField({
    super.key,
    required this.search,
    required this.hint,
    required this.onChanged,
    required this.onClose,
  });

  final EpisodeSearch search;
  final String hint;
  final ValueChanged<String> onChanged;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
    child: Semantics(
      label: hint,
      child: TextField(
        controller: search.text,
        focusNode: search.focus,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        showCursor: false,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          hintText: hint,
          suffixIcon: IconButton(
            icon: const Icon(Icons.clear),
            tooltip: context.strings.clearSearch,
            onPressed: onClose,
          ),
        ),
      ),
    ),
  );
}
