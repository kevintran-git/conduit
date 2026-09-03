import 'package:shared_preferences/shared_preferences.dart';

class TtsPositionStore {
  TtsPositionStore({
    this.headFraction = 0.02,
    this.tailFraction = 0.98,
  });

  static const String _prefix = 'gateway_tts_pos_';
  static const String _indexKey = 'gateway_tts_pos_index';
  static const int _maxEntries = 64;

  final double headFraction;
  final double tailFraction;

  bool isWorthSaving(Duration position, Duration total) {
    if (position <= Duration.zero) return false;
    if (total <= Duration.zero) return true;
    final ratio = position.inMicroseconds / total.inMicroseconds;
    return ratio > headFraction && ratio < tailFraction;
  }

  Future<void> save(
    String key,
    Duration position, {
    Duration total = Duration.zero,
  }) async {
    if (!isWorthSaving(position, total)) {
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

  Future<Set<String>> knownKeys() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_indexKey) ?? const <String>[]).toSet();
  }

  Future<void> clear(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefix$key');
    final index = prefs.getStringList(_indexKey)?.toList();
    if (index == null || !index.remove(key)) return;
    await prefs.setStringList(_indexKey, index);
  }
}
