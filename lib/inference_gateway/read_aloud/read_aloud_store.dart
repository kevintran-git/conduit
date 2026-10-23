import 'package:shared_preferences/shared_preferences.dart';

typedef ReadAloudMark = ({int part, int offset});

class ReadAloudStore {
  static const String _posPrefix = 'gateway_read_aloud_pos_';
  static const String _posIndex = 'gateway_read_aloud_pos_index';
  static const String _ratePrefix = 'gateway_read_aloud_rate_';
  static const String _gainPrefix = 'gateway_read_aloud_gain_';
  static const String _speedKey = 'gateway_read_aloud_speed';
  static const String _legacyPrefix = 'gateway_tts_pos_';
  static const int _maxEntries = 64;

  bool _legacyCleared = false;

  Future<void> saveMark(String key, ReadAloudMark mark) async {
    final prefs = await SharedPreferences.getInstance();
    await _clearLegacy(prefs);
    await prefs.setString('$_posPrefix$key', '${mark.part}:${mark.offset}');
    final index = prefs.getStringList(_posIndex)?.toList() ?? <String>[];
    index
      ..remove(key)
      ..add(key);
    while (index.length > _maxEntries) {
      await prefs.remove('$_posPrefix${index.removeAt(0)}');
    }
    await prefs.setStringList(_posIndex, index);
  }

  Future<ReadAloudMark?> loadMark(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_posPrefix$key');
    if (raw == null) return null;
    final parts = raw.split(':');
    if (parts.length != 2) return null;
    final part = int.tryParse(parts[0]);
    final offset = int.tryParse(parts[1]);
    if (part == null || offset == null) return null;
    return (part: part, offset: offset);
  }

  Future<void> clearMark(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_posPrefix$key');
    final index = prefs.getStringList(_posIndex)?.toList();
    if (index == null || !index.remove(key)) return;
    await prefs.setStringList(_posIndex, index);
  }

  Future<double?> loadRate(String voiceKey) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble('$_ratePrefix$voiceKey');
  }

  Future<void> saveRate(String voiceKey, double msPerWeight) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('$_ratePrefix$voiceKey', msPerWeight);
  }

  Future<double?> loadGain(String voiceKey) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble('$_gainPrefix$voiceKey');
  }

  Future<void> saveGain(String voiceKey, double gain) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('$_gainPrefix$voiceKey', gain);
  }

  Future<double?> loadSpeed() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_speedKey);
  }

  Future<void> saveSpeed(double speed) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_speedKey, speed);
  }

  Future<void> _clearLegacy(SharedPreferences prefs) async {
    if (_legacyCleared) return;
    _legacyCleared = true;
    for (final key in prefs.getKeys().toList()) {
      if (key.startsWith(_legacyPrefix)) await prefs.remove(key);
    }
  }
}
