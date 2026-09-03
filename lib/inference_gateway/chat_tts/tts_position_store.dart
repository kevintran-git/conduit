import 'package:shared_preferences/shared_preferences.dart';

class TtsPositionStore {
  TtsPositionStore({this.minimumSaved = const Duration(seconds: 3)});

  static const String _prefix = 'gateway_tts_pos_';
  static const String _indexKey = 'gateway_tts_pos_index';
  static const int _maxEntries = 64;

  final Duration minimumSaved;

  Future<void> save(String key, Duration position) async {
    if (position < minimumSaved) {
      await clear(key);
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('$_prefix$key', position.inMilliseconds);
    final index = prefs.getStringList(_indexKey)?.toList() ?? <String>[];
    index
      ..remove(key)
      ..add(key);
    while (index.length > _maxEntries) {
      await prefs.remove('$_prefix${index.removeAt(0)}');
    }
    await prefs.setStringList(_indexKey, index);
  }

  Future<Duration?> load(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final millis = prefs.getInt('$_prefix$key');
    if (millis == null || millis <= 0) return null;
    return Duration(milliseconds: millis);
  }

  Future<void> clear(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefix$key');
    final index = prefs.getStringList(_indexKey)?.toList();
    if (index == null || !index.remove(key)) return;
    await prefs.setStringList(_indexKey, index);
  }
}
