import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../core/downloads.dart';
import '../core/services.dart';
import '../core/sync.dart';
import '../l10n/app_localizations.dart';
import 'theme.dart';

extension UiLocalizations on BuildContext {
  AppLocalizations get strings => AppLocalizations.of(this);
}

const headingStyle = TextStyle(
  fontSize: 18,
  height: 1.2,
  fontWeight: FontWeight.w700,
);
const rowTitleStyle = TextStyle(
  fontSize: 16,
  height: 1.2,
  fontWeight: FontWeight.w400,
);
const detailStyle = TextStyle(
  fontSize: 12,
  height: 1.25,
  fontWeight: FontWeight.w400,
);
const buttonLabelStyle = TextStyle(
  fontSize: 14,
  height: 1.2,
  fontWeight: FontWeight.w400,
);
const underlineStyle = TextStyle(decoration: TextDecoration.underline);

class EinkHeader extends StatelessWidget {
  const EinkHeader(
    this.title, {
    super.key,
    this.onBack,
    this.onMenu,
    this.expanded = false,
  });

  final String title;
  final VoidCallback? onBack;
  final VoidCallback? onMenu;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final label = FittedBox(
      fit: BoxFit.scaleDown,
      alignment: AlignmentDirectional.centerStart,
      child: Text(title, style: headingStyle, maxLines: 1),
    );
    final menu = onMenu;
    return DecoratedBox(
      decoration: const BoxDecoration(border: Border(bottom: BorderSide())),
      child: SizedBox(
        height: 52,
        child: menu != null
            ? Semantics(
                expanded: expanded,
                label: context.strings.changeList,
                child: TextButton(
                  onPressed: menu,
                  style: const ButtonStyle(
                    alignment: AlignmentDirectional.centerStart,
                    padding: WidgetStatePropertyAll(
                      EdgeInsets.symmetric(horizontal: 12),
                    ),
                  ),
                  child: Row(
                    children: [
                      Flexible(child: label),
                      const SizedBox(width: 4),
                      Icon(expanded ? Icons.expand_less : Icons.expand_more),
                    ],
                  ),
                ),
              )
            : Row(
                children: [
                  if (onBack != null)
                    IconButton(
                      onPressed: onBack,
                      tooltip: MaterialLocalizations.of(context)
                          .backButtonTooltip,
                      icon: const Icon(Icons.arrow_back),
                    )
                  else
                    const SizedBox(width: 12),
                  Expanded(child: Semantics(header: true, child: label)),
                  const SizedBox(width: 12),
                ],
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
    this.trailing,
    this.onPressed,
    this.selected,
    this.lifted = false,
    this.toggled,
    this.underlined = false,
    this.compact = false,
    this.last = false,
    this.desktop = false,
  });

  final String title;
  final List<Widget> details;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onPressed;
  final bool? selected;
  final bool lifted;
  final bool? toggled;
  final bool underlined;
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
      children: [
        if (leading case final Widget icon) ...[icon, const SizedBox(width: 6)],
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: rowTitleStyle.copyWith(
                  fontSize: compact || desktop ? 14 : 16,
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

  Widget _button(TextStyle labelStyle, double height) {
    const padding = EdgeInsets.symmetric(horizontal: 8, vertical: 6);
    var style =
        (selected == null
                ? const ButtonStyle()
                : choiceButtonStyle(selected: selected!))
            .copyWith(
              minimumSize: WidgetStatePropertyAll(Size(48, height)),
              padding: const WidgetStatePropertyAll(padding),
              textStyle: WidgetStatePropertyAll(labelStyle),
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
    final text = Text(label, textAlign: TextAlign.center);
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
              constraints: BoxConstraints(minHeight: height),
              padding: padding,
              alignment: Alignment.center,
              child: text,
            ),
          ),
        ],
      );
    } else if (icon case final IconData icon) {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 6),
          Flexible(child: text),
        ],
      );
    } else {
      content = text;
    }
    if (primary) {
      return FilledButton(onPressed: onPressed, style: style, child: content);
    }
    return Semantics(
      selected: selected,
      child: OutlinedButton(
        onPressed: onPressed,
        style: style,
        clipBehavior: progress == null ? Clip.none : Clip.antiAlias,
        child: content,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final labelStyle = error
        ? buttonLabelStyle.copyWith(fontWeight: FontWeight.w700)
        : buttonLabelStyle;
    final style = Theme.of(context).textTheme.labelLarge!.merge(labelStyle);
    if (alternatives.isEmpty) return _button(style, minHeight);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.max(
          1.0,
          constraints.maxWidth - 16 - (icon == null ? 0 : 26),
        );
        final painter = TextPainter(
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        );
        final style = DefaultTextStyle.of(context).style.merge(labelStyle);
        var height = minHeight;
        for (final text in [label, ...alternatives]) {
          painter.text = TextSpan(text: text, style: style);
          painter.layout(maxWidth: width);
          height = math.max(height, painter.height + 12);
        }
        painter.dispose();
        return _button(style, height.ceilToDouble());
      },
    );
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
    child: Text(message, style: const TextStyle(fontSize: 14, height: 1.25)),
  );
}

class ProblemBox extends StatelessWidget {
  const ProblemBox(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(8),
    child: SizedBox(width: double.infinity, child: EinkError(message)),
  );
}

class EinkDialogPanel extends StatelessWidget {
  const EinkDialogPanel({
    super.key,
    required this.title,
    this.message,
    this.children = const [],
    required this.actions,
  });

  final String title;
  final String? message;
  final List<Widget> children;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Dialog(
    alignment: MediaQuery.sizeOf(context).width < 760
        ? const Alignment(0, -0.6)
        : Alignment.center,
    insetAnimationDuration: Duration.zero,
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(header: true, child: Text(title, style: headingStyle)),
          if (message case final String message) ...[
            const SizedBox(height: 8),
            Text(message, style: buttonLabelStyle),
          ],
          if (children.isNotEmpty) ...[const SizedBox(height: 12), ...children],
          const SizedBox(height: 14),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 6,
            runSpacing: 6,
            children: actions,
          ),
        ],
      ),
    ),
  );
}

Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  String? message,
  required String action,
}) async {
  final cancel = context.strings.cancel;
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
              onPressed: () => Navigator.pop(dialogContext, true),
            ),
          ],
        ),
      ) ??
      false;
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
    this.hint,
  });

  final String label;
  final TextEditingController controller;
  final TextInputType? keyboardType;
  final bool obscure;
  final bool enabled;
  final int lines;
  final ValueChanged<String>? onSubmitted;
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
            textInputAction: onSubmitted == null || lines > 1
                ? null
                : TextInputAction.done,
            cursorOpacityAnimates: false,
            obscureText: obscure,
            autocorrect: false,
            enableSuggestions: false,
            enabled: enabled,
            minLines: lines,
            maxLines: lines,
            style: const TextStyle(color: Colors.black, fontSize: 14),
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
    required this.wifiConnected,
    required this.episodeId,
    required this.builder,
  });

  final AppServices services;
  final ValueListenable<bool?> wifiConnected;
  final int episodeId;
  final Widget Function(BuildContext context, DownloadDisplay download) builder;

  @override
  State<DownloadStatusView> createState() => _DownloadStatusViewState();
}

class _DownloadStatusViewState extends State<DownloadStatusView> {
  late ({DownloadStatus status, int percent}) _download;

  ({DownloadStatus status, int percent}) get _current {
    final info = widget.services.downloads.statusOf(widget.episodeId);
    return (
      status: info.status,
      percent: info.status == DownloadStatus.running
          ? (info.progress.clamp(0.0, 1.0) * 10).floor() * 10
          : 0,
    );
  }

  @override
  void initState() {
    super.initState();
    _download = _current;
    widget.services.downloads.addListener(_changed);
  }

  @override
  void didUpdateWidget(DownloadStatusView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.services.downloads != widget.services.downloads) {
      oldWidget.services.downloads.removeListener(_changed);
      widget.services.downloads.addListener(_changed);
    }
    _download = _current;
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
  Widget build(BuildContext context) {
    if (_download.status != DownloadStatus.queued ||
        !widget.services.settings.downloadOnWifiOnly) {
      return _build(context, waitingForWifi: false);
    }
    return ValueListenableBuilder(
      valueListenable: widget.wifiConnected,
      builder: (context, wifi, _) => wifi == null
          ? ValueListenableBuilder(
              valueListenable: widget.services.sync.status,
              builder: (context, sync, _) => _build(
                context,
                waitingForWifi: sync.phase == SyncPhase.offline,
              ),
            )
          : _build(context, waitingForWifi: !wifi),
    );
  }

  Widget _build(BuildContext context, {required bool waitingForWifi}) =>
      widget.builder(context, (
        status: _download.status,
        percent: _download.percent,
        waitingForWifi: waitingForWifi,
      ));
}
