import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class DesktopFont {
  const DesktopFont(this.family, this.pointSize);

  final String family;
  final double pointSize;

  // GTK points use 96 logical pixels per inch. Flutter applies monitor scale.
  double get textScale => pointSize * (96 / 72) / 14;
}

const _desktop = MethodChannel('easypodcast/desktop');

Future<DesktopFont?> desktopFont() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.linux) return null;

  try {
    final value = await _desktop.invokeMethod<Object?>('getDesktopFont');
    if (value
        case {'family': final String families, 'pointSize': final num size}
        when size.isFinite && size > 0) {
      final family = families.split(',').first.trim();
      if (family.isNotEmpty) return DesktopFont(family, size.toDouble());
    }
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
  return null;
}
