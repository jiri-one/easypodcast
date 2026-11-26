import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

const einkSystemOverlayStyle = SystemUiOverlayStyle(
  statusBarColor: Colors.white,
  statusBarIconBrightness: Brightness.dark,
  statusBarBrightness: Brightness.light,
  systemStatusBarContrastEnforced: false,
  systemNavigationBarColor: Colors.white,
  systemNavigationBarIconBrightness: Brightness.dark,
  systemNavigationBarDividerColor: Colors.white,
  systemNavigationBarContrastEnforced: false,
);

const _border = BorderSide(width: 1.5);
const _errorBorder = BorderSide(width: 2);
const _buttonShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(8)),
);
const _panelShape = RoundedRectangleBorder(
  side: BorderSide(),
  borderRadius: BorderRadius.all(Radius.circular(8)),
);
const _buttons = ButtonStyle(
  animationDuration: Duration.zero,
  minimumSize: WidgetStatePropertyAll(Size(48, 48)),
  padding: WidgetStatePropertyAll(
    EdgeInsets.symmetric(horizontal: 12, vertical: 8),
  ),
  shape: WidgetStatePropertyAll(_buttonShape),
  elevation: WidgetStatePropertyAll(0),
  shadowColor: WidgetStatePropertyAll(Colors.transparent),
  surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
  overlayColor: WidgetStatePropertyAll(Colors.transparent),
  splashFactory: NoSplash.splashFactory,
);
const _inputBorder = OutlineInputBorder(
  borderRadius: BorderRadius.all(Radius.circular(8)),
);

ButtonStyle choiceButtonStyle({required bool selected}) =>
    _choiceStyle((_) => selected);

ButtonStyle _choiceStyle(bool Function(Set<WidgetState>) isSelected) =>
    _buttons.copyWith(
      backgroundColor: WidgetStateProperty.resolveWith(
        (states) => isSelected(states) ? Colors.black : Colors.white,
      ),
      foregroundColor: WidgetStateProperty.resolveWith(
        (states) => isSelected(states) ? Colors.white : Colors.black,
      ),
      side: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.focused)
            ? BorderSide(
                color: isSelected(states) ? Colors.white : Colors.black,
                width: 3,
              )
            : _border,
      ),
    );

ThemeData einkTheme({String? fontFamily}) {
  final textButton = _buttons.copyWith(
    foregroundColor: const WidgetStatePropertyAll(Colors.black),
    side: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.focused)
          ? const BorderSide(width: 3)
          : BorderSide.none,
    ),
  );
  final filledButton = _choiceStyle(
    (states) => !states.contains(WidgetState.disabled),
  );
  return ThemeData(
    fontFamily: fontFamily,
    visualDensity: VisualDensity.standard,
    colorScheme: const ColorScheme(
      brightness: Brightness.light,
      primary: Colors.black,
      onPrimary: Colors.white,
      primaryContainer: Colors.white,
      onPrimaryContainer: Colors.black,
      secondary: Colors.black,
      onSecondary: Colors.white,
      secondaryContainer: Colors.white,
      onSecondaryContainer: Colors.black,
      tertiary: Colors.black,
      onTertiary: Colors.white,
      tertiaryContainer: Colors.white,
      onTertiaryContainer: Colors.black,
      error: Colors.black,
      onError: Colors.white,
      errorContainer: Colors.white,
      onErrorContainer: Colors.black,
      surface: Colors.white,
      onSurface: Colors.black,
      outline: Colors.black,
      outlineVariant: Colors.black,
      shadow: Colors.transparent,
      surfaceTint: Colors.transparent,
    ),
    disabledColor: Colors.black,
    hintColor: Colors.black,
    unselectedWidgetColor: Colors.black,
    shadowColor: Colors.transparent,
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    hoverColor: Colors.transparent,
    focusColor: Colors.transparent,
    highlightColor: Colors.transparent,
    iconTheme: const IconThemeData(color: Colors.black),
    textTheme: const TextTheme(
      titleLarge: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
      bodyLarge: TextStyle(height: 1.35),
      bodyMedium: TextStyle(height: 1.35),
      labelLarge: TextStyle(fontWeight: FontWeight.w600),
    ),
    dividerTheme: const DividerThemeData(color: Colors.black, thickness: 1),
    filledButtonTheme: FilledButtonThemeData(style: filledButton),
    elevatedButtonTheme: ElevatedButtonThemeData(style: filledButton),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: choiceButtonStyle(selected: false),
    ),
    textButtonTheme: TextButtonThemeData(style: textButton),
    iconButtonTheme: IconButtonThemeData(
      style: textButton.copyWith(
        padding: const WidgetStatePropertyAll(EdgeInsets.all(8)),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: _choiceStyle((states) => states.contains(WidgetState.selected)),
    ),
    listTileTheme: const ListTileThemeData(
      textColor: Colors.black,
      iconColor: Colors.black,
      selectedTileColor: Colors.black,
      selectedColor: Colors.white,
    ),
    appBarTheme: const AppBarThemeData(
      backgroundColor: Colors.white,
      foregroundColor: Colors.black,
      elevation: 0,
      scrolledUnderElevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: Border(bottom: BorderSide()),
      systemOverlayStyle: einkSystemOverlayStyle,
    ),
    cardTheme: const CardThemeData(
      color: Colors.white,
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: _panelShape,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Colors.white,
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      barrierColor: Colors.transparent,
      shape: _panelShape.copyWith(side: _errorBorder),
      constraints: const BoxConstraints(maxWidth: 540),
      insetPadding: const EdgeInsets.all(16),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Colors.white,
      elevation: 0,
      modalElevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      modalBarrierColor: Colors.transparent,
      shape: _panelShape,
    ),
    inputDecorationTheme: InputDecorationThemeData(
      border: _inputBorder,
      enabledBorder: _inputBorder.copyWith(borderSide: _border),
      disabledBorder: _inputBorder,
      focusedBorder: _inputBorder.copyWith(
        borderSide: const BorderSide(width: 2.5),
      ),
      errorBorder: _inputBorder.copyWith(borderSide: _errorBorder),
      focusedErrorBorder: _inputBorder.copyWith(borderSide: _errorBorder),
      errorStyle: const TextStyle(
        color: Colors.black,
        fontWeight: FontWeight.w700,
      ),
      floatingLabelBehavior: FloatingLabelBehavior.never,
      hintFadeDuration: Duration.zero,
    ),
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {
        for (final platform in TargetPlatform.values)
          platform: const _InstantTransition(),
      },
    ),
  );
}

class _InstantTransition extends PageTransitionsBuilder {
  const _InstantTransition();

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}

Future<T?> showEinkDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) => showDialog<T>(
  context: context,
  builder: builder,
  barrierDismissible: barrierDismissible,
  animationStyle: AnimationStyle.noAnimation,
);

class EinkError extends StatelessWidget {
  const EinkError(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: DecoratedBox(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border.fromBorderSide(_errorBorder),
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          message,
          style: const TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    ),
  );
}
