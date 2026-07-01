import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'gateway_config.dart';
import 'gateway_storage.dart';

/// Single source of truth for the gateway configuration in memory.
///
/// On construction, loads non-secret fields synchronously from Hive and kicks
/// off an async load of the API key from secure storage. Until the API key
/// resolves, `hasCredentials` is false so shim points fall back to OWUI even
/// if the user has toggles on — preventing a brief unauthenticated burst.
class GatewayConfigNotifier extends Notifier<GatewayConfig> {
  late GatewayStorage _storage;

  @override
  GatewayConfig build() {
    _storage = ref.read(gatewayStorageProvider);
    final initial = _storage.loadSync(apiKey: '');
    unawaited(_hydrateSecureFields());
    return initial;
  }

  Future<void> _hydrateSecureFields() async {
    final apiKey = await _storage.loadApiKey();
    final mcpBearerToken = await _storage.loadMcpBearerToken();
    if (!ref.mounted) return;
    if (apiKey.isEmpty &&
        state.apiKey.isEmpty &&
        mcpBearerToken.isEmpty &&
        state.mcpBearerToken.isEmpty) {
      return;
    }
    state = state.copyWith(apiKey: apiKey, mcpBearerToken: mcpBearerToken);
  }

  Future<void> setBaseUrl(String value) async {
    final normalized = value.trim();
    final resolved = normalized.isEmpty
        ? GatewayConfig.defaultBaseUrl
        : _stripTrailingSlash(normalized);
    state = state.copyWith(baseUrl: resolved);
    await _storage.saveBaseUrl(resolved);
  }

  Future<void> setApiKey(String value) async {
    final trimmed = value.trim();
    state = state.copyWith(apiKey: trimmed);
    await _storage.saveApiKey(trimmed);
  }

  Future<void> setChatEnabled(bool value) async {
    state = state.copyWith(chatEnabled: value);
    await _storage.saveChatEnabled(value);
  }

  Future<void> setSttEnabled(bool value) async {
    state = state.copyWith(sttEnabled: value);
    await _storage.saveSttEnabled(value);
  }

  Future<void> setTtsEnabled(bool value) async {
    state = state.copyWith(ttsEnabled: value);
    await _storage.saveTtsEnabled(value);
  }

  Future<void> setVoiceEnabled(bool value) async {
    state = state.copyWith(voiceEnabled: value);
    await _storage.saveVoiceEnabled(value);
  }

  Future<void> setTtsModel(String value) async {
    final trimmed = value.trim().isEmpty
        ? GatewayConfig.defaultTtsModel
        : value.trim();
    state = state.copyWith(ttsModel: trimmed);
    await _storage.saveTtsModel(trimmed);
  }

  Future<void> setTtsVoice(String value) async {
    final trimmed = value.trim().isEmpty
        ? GatewayConfig.defaultTtsVoice
        : value.trim();
    state = state.copyWith(ttsVoice: trimmed);
    await _storage.saveTtsVoice(trimmed);
  }

  Future<void> setVoiceManualMode(bool value) async {
    state = state.copyWith(voiceManualMode: value);
    await _storage.saveVoiceManualMode(value);
  }

  Future<void> setRealtimeEnabled(bool value) async {
    state = state.copyWith(realtimeEnabled: value);
    await _storage.saveRealtimeEnabled(value);
  }

  Future<void> setCallSystemPrompt(String? value) async {
    final trimmed = value?.trim();
    state = state.copyWith(
      callSystemPrompt: (trimmed == null || trimmed.isEmpty) ? null : trimmed,
    );
    await _storage.saveCallSystemPrompt(trimmed);
  }

  Future<void> setMcpEnabled(bool value) async {
    state = state.copyWith(mcpEnabled: value);
    await _storage.saveMcpEnabled(value);
  }

  Future<void> setMcpServerUrl(String value) async {
    final trimmed = value.trim();
    state = state.copyWith(mcpServerUrl: trimmed);
    await _storage.saveMcpServerUrl(trimmed);
  }

  Future<void> setMcpBearerToken(String value) async {
    final trimmed = value.trim();
    state = state.copyWith(mcpBearerToken: trimmed);
    await _storage.saveMcpBearerToken(trimmed);
  }

  Future<void> setStatsToolEnabled(bool value) async {
    state = state.copyWith(statsToolEnabled: value);
    await _storage.saveStatsToolEnabled(value);
  }

  String _stripTrailingSlash(String url) {
    if (url.endsWith('/')) return url.substring(0, url.length - 1);
    return url;
  }
}

final gatewayStorageProvider = Provider<GatewayStorage>((ref) {
  return GatewayStorage();
});

final gatewayConfigProvider =
    NotifierProvider<GatewayConfigNotifier, GatewayConfig>(
      GatewayConfigNotifier.new,
    );

/// Convenience selectors used by shim points. Each is a boolean derived from
/// the live config — `chatEnabled` AND `hasCredentials` — so a misconfigured
/// gateway never short-circuits the OWUI path.
final gatewayChatActiveProvider = Provider<bool>((ref) {
  final cfg = ref.watch(gatewayConfigProvider);
  return cfg.chatEnabled && cfg.hasCredentials;
});

final gatewaySttActiveProvider = Provider<bool>((ref) {
  final cfg = ref.watch(gatewayConfigProvider);
  return cfg.sttEnabled && cfg.hasCredentials;
});

final gatewayTtsActiveProvider = Provider<bool>((ref) {
  final cfg = ref.watch(gatewayConfigProvider);
  return cfg.ttsEnabled && cfg.hasCredentials;
});

final gatewayVoiceActiveProvider = Provider<bool>((ref) {
  final cfg = ref.watch(gatewayConfigProvider);
  return cfg.voiceEnabled && cfg.hasCredentials;
});

final gatewayRealtimeActiveProvider = Provider<bool>((ref) {
  final cfg = ref.watch(gatewayConfigProvider);
  return cfg.realtimeEnabled && cfg.hasCredentials;
});
