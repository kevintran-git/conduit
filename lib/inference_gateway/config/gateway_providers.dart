import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'gateway_config.dart';
import 'gateway_storage.dart';

///
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
    if (!ref.mounted) return;
    if (apiKey.isEmpty && state.apiKey.isEmpty) return;
    state = state.copyWith(apiKey: apiKey);
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

  Future<void> setSttModel(String value) async {
    final trimmed = value.trim();
    state = state.copyWith(sttModel: trimmed);
    await _storage.saveSttModel(trimmed);
  }

  Future<void> setTtsModel(String value) async {
    final trimmed = value.trim();
    state = state.copyWith(ttsModel: trimmed);
    await _storage.saveTtsModel(trimmed);
  }

  Future<void> setTtsVoice(String value) async {
    final trimmed = value.trim();
    state = state.copyWith(ttsVoice: trimmed);
    await _storage.saveTtsVoice(trimmed);
  }

  Future<void> setVoiceManualMode(bool value) async {
    state = state.copyWith(voiceManualMode: value);
    await _storage.saveVoiceManualMode(value);
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
