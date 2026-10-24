import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit_core/services/settings_service.dart';

import 'gateway_config.dart';
import 'gateway_storage.dart';

class GatewayConfigNotifier extends Notifier<GatewayConfig> {
  late GatewayStorage _storage;

  @override
  GatewayConfig build() {
    _storage = ref.read(gatewayStorageProvider);
    final voiceId = ref.read(
      appSettingsProvider.select((s) => s.ttsServerVoiceId),
    );
    final legacy = _storage.takeLegacyVoice();
    if (legacy.isNotEmpty && (voiceId ?? '').isEmpty) {
      unawaited(Future.microtask(() => setTtsVoice(legacy)));
    }
    ref.listen<String?>(
      appSettingsProvider.select((s) => s.ttsServerVoiceId),
      (_, next) => state = state.copyWith(ttsVoice: next ?? ''),
    );
    final initial = _storage.loadSync(
      apiKey: '',
      voice: (voiceId ?? '').isEmpty ? legacy : voiceId!,
    );
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

  Future<void> setTtsModel(String value) async {
    final trimmed = value.trim();
    state = state.copyWith(ttsModel: trimmed);
    await _storage.saveTtsModel(trimmed);
  }

  Future<void> setTtsVoice(String value) async {
    final trimmed = value.trim();
    state = state.copyWith(ttsVoice: trimmed);
    await ref
        .read(appSettingsProvider.notifier)
        .setTtsServerVoiceSelection(
          trimmed.isEmpty ? null : trimmed,
          trimmed.isEmpty ? null : trimmed,
        );
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
  final preference = ref.watch(
    appSettingsProvider.select((s) => s.sttPreference),
  );
  return cfg.hasCredentials && preference == SttPreference.serverOnly;
});

final gatewayTtsActiveProvider = Provider<bool>((ref) {
  final cfg = ref.watch(gatewayConfigProvider);
  final engine = ref.watch(appSettingsProvider.select((s) => s.ttsEngine));
  return cfg.hasCredentials && engine == TtsEngine.server;
});
