import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_ce/hive.dart';

import '../../core/persistence/hive_boxes.dart';
import 'gateway_config.dart';

/// Persistence for gateway settings.
///
/// Non-secret fields (URL, toggles) live in the existing Hive `preferences`
/// box under the `gateway.*` key prefix. The API key lives in
/// `flutter_secure_storage` under `inference_gateway_api_key`, isolated from
/// `SecureCredentialStorage` so this code stays additive — no upstream
/// secure-storage edits required.
class GatewayStorage {
  GatewayStorage({FlutterSecureStorage? secureStorage})
    : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const String _kBaseUrl = 'gateway.base_url';
  static const String _kChatEnabled = 'gateway.chat_enabled';
  static const String _kSttEnabled = 'gateway.stt_enabled';
  static const String _kTtsEnabled = 'gateway.tts_enabled';
  static const String _kVoiceEnabled = 'gateway.voice_enabled';
  static const String _kTtsModel = 'gateway.tts_model';
  static const String _kTtsVoice = 'gateway.tts_voice';
  static const String _kVoiceManualMode = 'gateway.voice_manual_mode';
  static const String _kRealtimeEnabled = 'gateway.realtime_enabled';
  static const String _kCallModel = 'gateway.call_model';
  static const String _kCallVoice = 'gateway.call_voice';
  static const String _kCallPauseToleranceMs = 'gateway.call_pause_tolerance_ms';
  static const String _kCallPrefixPaddingMs = 'gateway.call_prefix_padding_ms';
  static const String _kCallStartSensitivity = 'gateway.call_start_sensitivity';
  static const String _kCallEndSensitivity = 'gateway.call_end_sensitivity';
  static const String _kCallSystemPrompt = 'gateway.call_system_prompt';
  static const String _kStatsToolEnabled = 'gateway.stats_tool_enabled';
  static const String _kApiKey = 'inference_gateway_api_key';

  final FlutterSecureStorage _secureStorage;

  Box<dynamic>? _preferencesBox() {
    if (!Hive.isBoxOpen(HiveBoxNames.preferences)) return null;
    return Hive.box<dynamic>(HiveBoxNames.preferences);
  }

  T? _read<T>(String key) {
    final value = _preferencesBox()?.get(key);
    return value is T ? value : null;
  }

  Future<void> _write(String key, Object? value) async {
    final box = _preferencesBox();
    if (box == null) return;
    await box.put(key, value);
  }

  GatewayConfig loadSync({required String apiKey}) {
    return GatewayConfig(
      baseUrl:
          _read<String>(_kBaseUrl) ??
          (GatewayConfig.envBaseUrl.isNotEmpty
              ? GatewayConfig.envBaseUrl
              : GatewayConfig.defaultBaseUrl),
      apiKey: apiKey,
      chatEnabled: _read<bool>(_kChatEnabled) ?? false,
      sttEnabled: _read<bool>(_kSttEnabled) ?? false,
      ttsEnabled: _read<bool>(_kTtsEnabled) ?? false,
      voiceEnabled: _read<bool>(_kVoiceEnabled) ?? false,
      ttsModel: _read<String>(_kTtsModel) ?? GatewayConfig.defaultTtsModel,
      ttsVoice: _read<String>(_kTtsVoice) ?? GatewayConfig.defaultTtsVoice,
      voiceManualMode: _read<bool>(_kVoiceManualMode) ?? false,
      realtimeEnabled: _read<bool>(_kRealtimeEnabled) ?? false,
      callModel: _read<String>(_kCallModel) ?? GatewayConfig.defaultCallModel,
      callVoice: _read<String>(_kCallVoice) ?? GatewayConfig.defaultCallVoice,
      callPauseToleranceMs:
          _read<int>(_kCallPauseToleranceMs) ??
          GatewayConfig.defaultCallPauseToleranceMs,
      callPrefixPaddingMs:
          _read<int>(_kCallPrefixPaddingMs) ??
          GatewayConfig.defaultCallPrefixPaddingMs,
      callStartSensitivity:
          _read<String>(_kCallStartSensitivity) ??
          GatewayConfig.defaultCallSensitivity,
      callEndSensitivity:
          _read<String>(_kCallEndSensitivity) ??
          GatewayConfig.defaultCallSensitivity,
      callSystemPrompt: _read<String>(_kCallSystemPrompt),
      statsToolEnabled: _read<bool>(_kStatsToolEnabled) ?? false,
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
  Future<void> saveChatEnabled(bool value) => _write(_kChatEnabled, value);
  Future<void> saveSttEnabled(bool value) => _write(_kSttEnabled, value);
  Future<void> saveTtsEnabled(bool value) => _write(_kTtsEnabled, value);
  Future<void> saveVoiceEnabled(bool value) => _write(_kVoiceEnabled, value);
  Future<void> saveTtsModel(String value) => _write(_kTtsModel, value);
  Future<void> saveTtsVoice(String value) => _write(_kTtsVoice, value);
  Future<void> saveVoiceManualMode(bool value) =>
      _write(_kVoiceManualMode, value);
  Future<void> saveRealtimeEnabled(bool value) =>
      _write(_kRealtimeEnabled, value);

  Future<void> saveCallModel(String value) => _write(_kCallModel, value);
  Future<void> saveCallVoice(String value) => _write(_kCallVoice, value);
  Future<void> saveCallPauseToleranceMs(int value) =>
      _write(_kCallPauseToleranceMs, value);
  Future<void> saveCallPrefixPaddingMs(int value) =>
      _write(_kCallPrefixPaddingMs, value);
  Future<void> saveCallStartSensitivity(String value) =>
      _write(_kCallStartSensitivity, value);
  Future<void> saveCallEndSensitivity(String value) =>
      _write(_kCallEndSensitivity, value);

  Future<void> saveCallSystemPrompt(String? value) async {
    final box = _preferencesBox();
    if (box == null) return;
    if (value == null || value.trim().isEmpty) {
      await box.delete(_kCallSystemPrompt);
    } else {
      await box.put(_kCallSystemPrompt, value.trim());
    }
  }

  Future<void> saveStatsToolEnabled(bool value) =>
      _write(_kStatsToolEnabled, value);

  Future<void> saveApiKey(String value) => _writeSecure(_kApiKey, value);

  Future<void> _writeSecure(String key, String value) async {
    if (value.isEmpty) {
      await _secureStorage.delete(key: key);
      return;
    }
    await _secureStorage.write(key: key, value: value);
  }
}
