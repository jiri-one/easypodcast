import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/downloads.dart';
import '../core/library.dart';
import '../core/services.dart';
import '../l10n/app_localizations.dart';
import 'theme.dart';

extension UiLocalizations on BuildContext {
  AppLocalizations get strings => AppLocalizations.of(this);
}

bool get downloadsAvailable =>
    kIsWeb || defaultTargetPlatform != TargetPlatform.linux;

String actionError(BuildContext context, Object error) =>
    error is BulkDismissNeedsConnection
    ? context.strings.dismissOlderOffline
    : context.strings.actionFailed;

mixin ActionTapGuard<T extends StatefulWidget> on State<T> {
  bool _runningAction = false;
  Timer? _tapGuard;

  Future<void> guardAction(Future<void> Function() action) async {
    if (_runningAction || _tapGuard?.isActive == true) return;
    _runningAction = true;
    try {
      await action();
    } finally {
      _runningAction = false;
      if (mounted) {
        _tapGuard = Timer(const Duration(milliseconds: 600), () {});
      }
    }
  }

  @override
  void dispose() {
    _tapGuard?.cancel();
    super.dispose();
  }
}

const headingStyle = TextStyle(
  fontSize: 22,
  height: 1.2,
  fontWeight: FontWeight.w700,
);
const rowTitleStyle = TextStyle(
  fontSize: 18,
  height: 1.2,
  fontWeight: FontWeight.w400,
);
const detailStyle = TextStyle(
  fontSize: einkBodyFontSize,
  height: 1.25,
  fontWeight: FontWeight.w400,
);
const metadataStyle = TextStyle(
  fontSize: einkBodyFontSize,
  height: 1.25,
  fontWeight: FontWeight.w400,
  fontStyle: FontStyle.italic,
);
const buttonLabelStyle = TextStyle(
  fontSize: einkButtonFontSize,
  height: 1.2,
  fontWeight: FontWeight.w400,
);
const underlineStyle = TextStyle(decoration: TextDecoration.underline);

class EinkHeader extends StatelessWidget {
  const EinkHeader(
    this.title, {
    super.key,
    this.subtitle,
    this.onBack,
    this.onMenu,
    this.expanded = false,
    this.actions = const [],
  });

  final String title;
  final String? subtitle;
  final VoidCallback? onBack;
  final VoidCallback? onMenu;
  final bool expanded;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final label = Text(
      title,
      style: headingStyle,
      maxLines: 4,
      overflow: TextOverflow.ellipsis,
    );
    final menu = onMenu;
    final titleLine = menu == null
        ? Semantics(header: true, child: label)
        : Row(
            children: [
              Flexible(child: label),
              const SizedBox(width: 4),
              Icon(expanded ? Icons.expand_less : Icons.expand_more),
            ],
          );
    final detail = subtitle;
    final content = detail == null
        ? titleLine
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              titleLine,
              Text(detail, style: detailStyle),
            ],
          );
    return DecoratedBox(
      decoration: const BoxDecoration(border: Border(bottom: BorderSide())),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        // Header icons grow with the title; the menu's chevron keeps its button's own size.
        child: IconTheme.merge(
          data: IconThemeData(size: MediaQuery.textScalerOf(context).scale(24)),
          child: Row(
            children: [
              if (onBack != null)
                IconButton(
                  onPressed: onBack,
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  icon: const Icon(Icons.arrow_back),
                )
              else if (menu == null)
                const SizedBox(width: 12),
              Expanded(
                child: menu == null
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: content,
                      )
                    : Semantics(
                        expanded: expanded,
                        label: context.strings.changeList,
                        child: TextButton(
                          onPressed: menu,
                          style: const ButtonStyle(
                            minimumSize: WidgetStatePropertyAll(Size(0, 52)),
                            padding: WidgetStatePropertyAll(
                              EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            ),
                          ),
                          child: content,
                        ),
                      ),
              ),
              if (actions.isNotEmpty)
                Column(mainAxisSize: MainAxisSize.min, children: actions)
              else if (menu == null)
                const SizedBox(width: 12),
            ],
          ),
        ),
      ),
    );
  }
}

class EinkRow extends StatelessWidget {
  const EinkRow({
    super.key,
    required this.title,
    this.details = const [],
    this.leading,
    this.topAligned = false,
    this.trailing,
    this.onPressed,
    this.selected,
    this.lifted = false,
    this.toggled,
    this.underlined = false,
    this.overline,
    this.compact = false,
    this.last = false,
    this.desktop = false,
  });

  final String title;
  final List<Widget> details;
  final Widget? leading;
  final bool topAligned;
  final Widget? trailing;
  final VoidCallback? onPressed;
  final bool? selected;
  final bool lifted;
  final bool? toggled;
  final bool underlined;
  final Widget? overline;
  final bool compact;
  final bool last;
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    final inverted = lifted || selected == true;
    final padding = EdgeInsets.symmetric(
      horizontal: desktop ? 16 : 12,
      vertical: compact ? 6 : 10,
    );
    final content = Row(
      crossAxisAlignment: topAligned
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        if (leading case final Widget start) ...[
          start,
          const SizedBox(width: 6),
        ],
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ?overline,
              Text(
                title,
                style: rowTitleStyle.copyWith(
                  decoration: underlined ? TextDecoration.underline : null,
                ),
              ),
              ...details,
            ],
          ),
        ),
        if (trailing case final Widget end) ...[const SizedBox(width: 8), end],
      ],
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: inverted ? Colors.black : Colors.white,
        border: last ? null : const Border(bottom: BorderSide()),
      ),
      child: onPressed == null
          ? Padding(padding: padding, child: content)
          : Semantics(
              selected: selected,
              toggled: toggled,
              child: TextButton(
                onPressed: onPressed,
                style: ButtonStyle(
                  minimumSize: WidgetStatePropertyAll(
                    Size(double.infinity, compact ? 52 : 56),
                  ),
                  padding: WidgetStatePropertyAll(padding),
                  foregroundColor: WidgetStatePropertyAll(
                    inverted ? Colors.white : Colors.black,
                  ),
                  side: WidgetStateProperty.resolveWith(
                    (states) => states.contains(WidgetState.focused)
                        ? BorderSide(
                            color: inverted ? Colors.white : Colors.black,
                            width: 3,
                          )
                        : BorderSide.none,
                  ),
                  shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: WidgetStatePropertyAll(
                    Theme.of(context).textTheme.labelLarge!
                        .merge(rowTitleStyle),
                  ),
                  alignment: AlignmentDirectional.centerStart,
                ),
                child: content,
              ),
            ),
    );
  }
}

class EinkButton extends StatelessWidget {
  const EinkButton(
    this.label, {
    super.key,
    required this.onPressed,
    this.primary = false,
    this.selected,
    this.icon,
    this.minHeight = 48,
    this.alternatives = const [],
    this.progress,
    this.error = false,
    this.reserveSpaceOnly = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool primary;
  final bool? selected;
  final IconData? icon;
  final double minHeight;
  final List<String> alternatives;
  final int? progress;
  final bool error;
  final bool reserveSpaceOnly;

  @override
  Widget build(BuildContext context) {
    final labelStyle = error
        ? buttonLabelStyle.copyWith(fontWeight: FontWeight.w700)
        : buttonLabelStyle;
    const padding = EdgeInsets.symmetric(horizontal: 8, vertical: 6);
    var style =
        (selected == null
                ? const ButtonStyle()
                : choiceButtonStyle(selected: selected!))
            .copyWith(
              minimumSize: WidgetStatePropertyAll(Size(48, minHeight)),
              padding: const WidgetStatePropertyAll(padding),
              textStyle: WidgetStatePropertyAll(
                Theme.of(context).textTheme.labelLarge!.merge(labelStyle),
              ),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            );
    if (error) {
      style = style.copyWith(
        side: WidgetStateProperty.resolveWith(
          (states) =>
              BorderSide(width: states.contains(WidgetState.focused) ? 3 : 2),
        ),
      );
    }
    Widget line(String text) {
      final label = Text(text, textAlign: TextAlign.center);
      if (icon == null) return label;
      return Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 6),
          Flexible(child: label),
        ],
      );
    }

    final text = alternatives.isEmpty
        ? line(label)
        : IndexedStack(
            alignment: Alignment.center,
            children: [
              for (final text in {label, ...alternatives}) line(text),
            ],
          );
    final Widget content;
    if (progress case final int percent) {
      final fill = percent / 100;
      style = style.copyWith(
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
      );
      content = Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: FractionallySizedBox(
              widthFactor: fill,
              alignment: Alignment.centerLeft,
              child: const ColoredBox(color: Colors.black),
            ),
          ),
          ShaderMask(
            blendMode: BlendMode.srcIn,
            shaderCallback: (bounds) => LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: const [Colors.white, Colors.black],
              stops: [fill, fill],
            ).createShader(bounds),
            child: Container(
              width: double.infinity,
              constraints: BoxConstraints(minHeight: minHeight),
              padding: padding,
              alignment: Alignment.center,
              child: text,
            ),
          ),
        ],
      );
    } else {
      content = text;
    }
    final button = primary
        ? FilledButton(onPressed: onPressed, style: style, child: content)
        : Semantics(
            selected: selected,
            child: OutlinedButton(
              onPressed: onPressed,
              style: style,
              clipBehavior: progress == null ? Clip.none : Clip.antiAlias,
              child: content,
            ),
          );
    return reserveSpaceOnly
        ? IndexedStack(index: null, children: [button])
        : button;
  }
}

class PageList extends StatelessWidget {
  const PageList({super.key, required this.children, this.inset = false});

  final List<Widget> children;
  final bool inset;

  @override
  Widget build(BuildContext context) => ListView(
    padding: inset ? const EdgeInsets.all(12) : EdgeInsets.zero,
    children: children,
  );
}

class PageMessage extends StatelessWidget {
  const PageMessage(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(12),
    child: Text(message, style: detailStyle),
  );
}

class EinkDialogPanel extends StatelessWidget {
  const EinkDialogPanel({
    super.key,
    required this.title,
    this.message,
    this.children = const [],
    this.actions,
  });

  final String title;
  final String? message;
  final List<Widget> children;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): () =>
          Navigator.maybePop(context),
    },
    child: Focus(
      autofocus: true,
      child: Dialog(
        alignment: MediaQuery.sizeOf(context).width < 760
            ? const Alignment(0, -0.6)
            : Alignment.center,
        insetAnimationDuration: Duration.zero,
        child: Semantics(
          scopesRoute: true,
          namesRoute: true,
          explicitChildNodes: true,
          label: title,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  header: true,
                  child: Text(title, style: headingStyle),
                ),
                if (message case final String message) ...[
                  const SizedBox(height: 8),
                  Text(message, style: buttonLabelStyle),
                ],
                if (children.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  ...children,
                ],
                const SizedBox(height: 14),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 6,
                  runSpacing: 6,
                  children:
                      actions ??
                      [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: Text(
                            context.strings.close,
                            style: buttonLabelStyle,
                          ),
                        ),
                      ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

Future<T?> showChoices<T>(
  BuildContext context, {
  required String title,
  required String message,
  required List<({T value, String label, bool selected})> choices,
}) => showEinkDialog<T>(
  context: context,
  barrierDismissible: false,
  builder: (context) => EinkDialogPanel(
    title: title,
    message: message,
    children: [
      Column(
        spacing: 8,
        children: [
          for (var index = 0; index < choices.length; index += 2)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 8,
                children: [
                  for (final choice in choices.skip(index).take(2))
                    Expanded(
                      child: EinkButton(
                        choice.label,
                        selected: choice.selected,
                        onPressed: () => Navigator.pop(context, choice.value),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    ],
  ),
);

Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  String? message,
  required String action,
}) async {
  final cancel = context.strings.cancel;
  // The second tap of an e-ink double tap would otherwise confirm at once.
  var armed = false;
  final arming = Timer(const Duration(milliseconds: 600), () => armed = true);
  try {
    return await showEinkDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => EinkDialogPanel(
            title: title,
            message: message,
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(cancel, style: buttonLabelStyle),
              ),
              EinkButton(
                action,
                primary: true,
                onPressed: () {
                  if (armed) Navigator.pop(dialogContext, true);
                },
              ),
            ],
          ),
        ) ??
        false;
  } finally {
    arming.cancel();
  }
}

class LabeledField extends StatelessWidget {
  const LabeledField({
    super.key,
    required this.label,
    required this.controller,
    this.keyboardType,
    this.obscure = false,
    this.enabled = true,
    this.lines = 1,
    this.onSubmitted,
    this.onChanged,
    this.textInputAction,
    this.hint,
  });

  final String label;
  final TextEditingController controller;
  final TextInputType? keyboardType;
  final bool obscure;
  final bool enabled;
  final int lines;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final TextInputAction? textInputAction;
  final String? hint;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExcludeSemantics(child: Text(label, style: buttonLabelStyle)),
        const SizedBox(height: 4),
        Semantics(
          label: label,
          child: TextField(
            controller: controller,
            keyboardType: keyboardType,
            onSubmitted: onSubmitted,
            onChanged: onChanged,
            textInputAction:
                textInputAction ??
                (onSubmitted == null || lines > 1
                    ? null
                    : TextInputAction.done),
            obscureText: obscure,
            autocorrect: false,
            enableSuggestions: false,
            enabled: enabled,
            minLines: lines,
            maxLines: lines,
            style: const TextStyle(color: Colors.black),
            decoration: InputDecoration(
              isDense: true,
              hintText: hint,
              hintStyle: const TextStyle(color: Colors.black),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 7,
              ),
              constraints: const BoxConstraints(minHeight: 48),
            ),
          ),
        ),
      ],
    ),
  );
}

typedef DownloadDisplay = ({
  DownloadStatus status,
  int percent,
  bool waitingForWifi,
});

const DownloadDisplay noDownload = (
  status: DownloadStatus.none,
  percent: 0,
  waitingForWifi: false,
);

class DownloadStatusView extends StatefulWidget {
  const DownloadStatusView({
    super.key,
    required this.services,
    required this.episodeId,
    required this.builder,
  });

  final AppServices services;
  final int episodeId;
  final Widget Function(BuildContext context, DownloadDisplay download) builder;

  @override
  State<DownloadStatusView> createState() => _DownloadStatusViewState();
}

class _DownloadStatusViewState extends State<DownloadStatusView> {
  late DownloadDisplay _download;

  DownloadDisplay get _current {
    final info = widget.services.downloads.statusOf(widget.episodeId);
    return (
      status: info.status,
      percent: info.status == DownloadStatus.running
          ? (info.progress.clamp(0.0, 1.0) * 10).floor() * 10
          : 0,
      waitingForWifi: info.waitingForWifi,
    );
  }

  @override
  void initState() {
    super.initState();
    _download = _current;
    widget.services.downloads.addListener(_changed);
  }

  void _changed() {
    final next = _current;
    if (_download != next) setState(() => _download = next);
  }

  @override
  void dispose() {
    widget.services.downloads.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _download);
}
