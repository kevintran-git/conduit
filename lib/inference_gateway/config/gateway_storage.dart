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
  static const String _kCallSystemPrompt = 'gateway.call_system_prompt';
  static const String _kMcpEnabled = 'gateway.mcp_enabled';
  static const String _kMcpServerUrl = 'gateway.mcp_server_url';
  static const String _kStatsToolEnabled = 'gateway.stats_tool_enabled';
  static const String _kApiKey = 'inference_gateway_api_key';
  static const String _kMcpBearerToken = 'inference_gateway_mcp_bearer_token';

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

  GatewayConfig loadSync({required String apiKey, String mcpBearerToken = ''}) {
    return GatewayConfig(
      baseUrl: _read<String>(_kBaseUrl) ?? GatewayConfig.defaultBaseUrl,
      apiKey: apiKey,
      chatEnabled: _read<bool>(_kChatEnabled) ?? false,
      sttEnabled: _read<bool>(_kSttEnabled) ?? false,
      ttsEnabled: _read<bool>(_kTtsEnabled) ?? false,
      voiceEnabled: _read<bool>(_kVoiceEnabled) ?? false,
      ttsModel: _read<String>(_kTtsModel) ?? GatewayConfig.defaultTtsModel,
      ttsVoice: _read<String>(_kTtsVoice) ?? GatewayConfig.defaultTtsVoice,
      voiceManualMode: _read<bool>(_kVoiceManualMode) ?? false,
      realtimeEnabled: _read<bool>(_kRealtimeEnabled) ?? false,
      callSystemPrompt: _read<String>(_kCallSystemPrompt),
      mcpEnabled: _read<bool>(_kMcpEnabled) ?? false,
      mcpServerUrl: _read<String>(_kMcpServerUrl) ?? '',
      mcpBearerToken: mcpBearerToken,
      statsToolEnabled: _read<bool>(_kStatsToolEnabled) ?? false,
    );
  }

  Future<String> loadApiKey() => _readSecure(_kApiKey);

  Future<String> loadMcpBearerToken() => _readSecure(_kMcpBearerToken);

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

  Future<void> saveCallSystemPrompt(String? value) async {
    final box = _preferencesBox();
    if (box == null) return;
    if (value == null || value.trim().isEmpty) {
      await box.delete(_kCallSystemPrompt);
    } else {
      await box.put(_kCallSystemPrompt, value.trim());
    }
  }

  Future<void> saveMcpEnabled(bool value) => _write(_kMcpEnabled, value);
  Future<void> saveMcpServerUrl(String value) => _write(_kMcpServerUrl, value);
  Future<void> saveStatsToolEnabled(bool value) =>
      _write(_kStatsToolEnabled, value);

  Future<void> saveApiKey(String value) => _writeSecure(_kApiKey, value);
  Future<void> saveMcpBearerToken(String value) =>
      _writeSecure(_kMcpBearerToken, value);

  Future<void> _writeSecure(String key, String value) async {
    if (value.isEmpty) {
      await _secureStorage.delete(key: key);
      return;
    }
    await _secureStorage.write(key: key, value: value);
  }
}
