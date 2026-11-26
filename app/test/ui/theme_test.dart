import 'package:easypodcast/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('e-ink surfaces are flat and buttons have no ink or overlays', () {
    final theme = einkTheme();
    expect(theme.scaffoldBackgroundColor, Colors.white);
    expect(theme.textTheme.bodyMedium?.color, Colors.black);
    expect(theme.shadowColor, Colors.transparent);
    expect(theme.colorScheme.shadow, Colors.transparent);
    expect(theme.colorScheme.surfaceTint, Colors.transparent);
    expect(theme.splashFactory, NoSplash.splashFactory);
    expect(theme.appBarTheme.systemOverlayStyle?.statusBarColor, Colors.white);
    expect(
      theme.appBarTheme.systemOverlayStyle?.systemNavigationBarColor,
      Colors.white,
    );
    expect([
      theme.appBarTheme.elevation,
      theme.appBarTheme.scrolledUnderElevation,
      theme.cardTheme.elevation,
      theme.dialogTheme.elevation,
      theme.bottomSheetTheme.elevation,
      theme.bottomSheetTheme.modalElevation,
    ], everyElement(0));

    const pressed = {WidgetState.pressed};
    for (final button in [
      theme.filledButtonTheme.style!,
      theme.elevatedButtonTheme.style!,
      theme.outlinedButtonTheme.style!,
      theme.textButtonTheme.style!,
      theme.iconButtonTheme.style!,
      theme.segmentedButtonTheme.style!,
    ]) {
      expect(button.elevation?.resolve(pressed), 0);
      expect(button.shadowColor?.resolve(pressed), Colors.transparent);
      expect(button.overlayColor?.resolve(pressed), Colors.transparent);
      expect(button.splashFactory, NoSplash.splashFactory);
      expect(button.animationDuration, Duration.zero);
    }
  });

  test('selected choices are inverted and routes switch instantly', () {
    final theme = einkTheme();
    final choices = theme.segmentedButtonTheme.style!;
    expect(
      choices.foregroundColor?.resolve({WidgetState.selected}),
      Colors.white,
    );
    expect(
      choices.backgroundColor?.resolve({WidgetState.selected}),
      Colors.black,
    );
    expect(choices.foregroundColor?.resolve({}), Colors.black);
    expect(choices.backgroundColor?.resolve({}), Colors.white);

    for (final platform in TargetPlatform.values) {
      final builder = theme.pageTransitionsTheme.builders[platform];
      expect(builder?.transitionDuration, Duration.zero, reason: platform.name);
      expect(
        builder?.reverseTransitionDuration,
        Duration.zero,
        reason: platform.name,
      );
    }
  });
}
