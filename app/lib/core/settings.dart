import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Settings extends ChangeNotifier {
  Settings._(this._prefs);

  static Future<Settings> load() async =>
      Settings._(await SharedPreferences.getInstance());

  final SharedPreferences _prefs;

  bool get alphabeticalPodcasts =>
      _prefs.getBool('alphabeticalPodcasts') ?? false;
  set alphabeticalPodcasts(bool value) => _set('alphabeticalPodcasts', value);

  String? get lastServerAddress => _prefs.getString('lastServerAddress');
  set lastServerAddress(String value) => _set('lastServerAddress', value);

  int get skipBackSeconds => _prefs.getInt('skipBackSeconds') ?? 15;
  set skipBackSeconds(int value) => _set('skipBackSeconds', value);

  int get skipForwardSeconds => _prefs.getInt('skipForwardSeconds') ?? 30;
  set skipForwardSeconds(int value) => _set('skipForwardSeconds', value);

  double get speed => _prefs.getDouble('speed') ?? 1.0;
  set speed(double value) => _set('speed', value);

  bool get showSpeedAndSleep => _prefs.getBool('showSpeedAndSleep') ?? false;
  set showSpeedAndSleep(bool value) => _set('showSpeedAndSleep', value);

  bool get autoplayQueue => _prefs.getBool('autoplayQueue') ?? true;
  set autoplayQueue(bool value) => _set('autoplayQueue', value);

  bool get deleteAfterPlayed => _prefs.getBool('deleteAfterPlayed') ?? true;
  set deleteAfterPlayed(bool value) => _set('deleteAfterPlayed', value);

  bool get downloadOnWifiOnly => _prefs.getBool('downloadOnWifiOnly') ?? true;
  set downloadOnWifiOnly(bool value) => _set('downloadOnWifiOnly', value);

  bool get keepQueueDownloaded =>
      _prefs.getBool('keepQueueDownloaded') ?? false;
  set keepQueueDownloaded(bool value) => _set('keepQueueDownloaded', value);

  void _set(String key, Object value) {
    switch (value) {
      case String v:
        _prefs.setString(key, v);
      case int v:
        _prefs.setInt(key, v);
      case double v:
        _prefs.setDouble(key, v);
      case bool v:
        _prefs.setBool(key, v);
    }
    notifyListeners();
  }
}
