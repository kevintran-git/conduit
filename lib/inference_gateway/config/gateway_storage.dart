import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:conduit_core/persistence/preferences_store.dart';

import 'gateway_config.dart';

class GatewayStorage {
  GatewayStorage({FlutterSecureStorage? secureStorage})
    : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const String _kBaseUrl = 'gateway.base_url';
  static const String _kSttEnabled = 'gateway.stt_enabled';
  static const String _kTtsEnabled = 'gateway.tts_enabled';
  static const String _kVoiceEnabled = 'gateway.voice_enabled';
  static const String _kSttModel = 'gateway.stt_model';
  static const String _kTtsModel = 'gateway.tts_model';
  static const String _kTtsVoice = 'gateway.tts_voice';
  static const String _kTtsPronunciations = 'gateway.tts_pronunciations';
  static const String _kVoiceManualMode = 'gateway.voice_manual_mode';
  static const String _kApiKey = 'inference_gateway_api_key';

  final FlutterSecureStorage _secureStorage;

  T? _read<T>(String key) => PreferencesStore.get<T>(key);

  Future<void> _write(String key, Object? value) =>
      PreferencesStore.put(key, value);

  GatewayConfig loadSync({required String apiKey}) {
    return GatewayConfig(
      baseUrl: _read<String>(_kBaseUrl) ?? GatewayConfig.defaultBaseUrl,
      apiKey: apiKey,
      sttEnabled: _read<bool>(_kSttEnabled) ?? false,
      ttsEnabled: _read<bool>(_kTtsEnabled) ?? false,
      voiceEnabled: _read<bool>(_kVoiceEnabled) ?? false,
      sttModel: _read<String>(_kSttModel) ?? '',
      ttsModel: _read<String>(_kTtsModel) ?? GatewayConfig.unsetModel,
      ttsVoice: _read<String>(_kTtsVoice) ?? GatewayConfig.unsetModel,
      ttsPronunciations: _read<String>(_kTtsPronunciations) ?? '',
      voiceManualMode: _read<bool>(_kVoiceManualMode) ?? false,
    );
  }

  Future<String> loadApiKey() async {
    final stored = await _readSecure(_kApiKey);
    return stored.isNotEmpty ? stored : GatewayConfig.envApiKey;
  }

  Future<String> _readSecure(String key) async {
    try {
      final value = await _secureStorage.read(key: key);
      return value ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<void> saveBaseUrl(String value) => _write(_kBaseUrl, value);
  Future<void> saveSttEnabled(bool value) => _write(_kSttEnabled, value);
  Future<void> saveTtsEnabled(bool value) => _write(_kTtsEnabled, value);
  Future<void> saveVoiceEnabled(bool value) => _write(_kVoiceEnabled, value);
  Future<void> saveSttModel(String value) => _write(_kSttModel, value);
  Future<void> saveTtsModel(String value) => _write(_kTtsModel, value);
  Future<void> saveTtsVoice(String value) => _write(_kTtsVoice, value);
  Future<void> saveTtsPronunciations(String value) =>
      _write(_kTtsPronunciations, value);
  Future<void> saveVoiceManualMode(bool value) =>
      _write(_kVoiceManualMode, value);

  Future<void> saveApiKey(String value) => _writeSecure(_kApiKey, value);

  Future<void> _writeSecure(String key, String value) async {
    if (value.isEmpty) {
      await _secureStorage.delete(key: key);
      return;
    }
    await _secureStorage.write(key: key, value: value);
  }
}
