import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:inference_kit/inference_kit.dart' as ik;

import '../config/gateway_providers.dart';
import '../transport/gateway_client.dart';
import 'gateway_inference_router.dart';

final gatewayToolRegistryProvider = Provider<ik.ToolRegistry>((ref) {
  final registry = ik.ToolRegistry();
  ref.onDispose(registry.dispose);
  return registry;
});

final gatewaySttClientProvider = Provider<ik.TranscriptionClient>((ref) {
  return ik.TranscriptionClient(ref.read(gatewayClientProvider).dio);
});

final gatewayElevenLabsClientProvider = Provider<ik.ElevenLabsTtsClient>((ref) {
  final cfg = ref.watch(gatewayConfigProvider);
  return ik.ElevenLabsTtsClient(baseUrl: cfg.baseUrl, apiKey: cfg.apiKey);
});

final gatewayTtsClientProvider = Provider<ik.TextToSpeechClient>((ref) {
  final cfg = ref.watch(gatewayConfigProvider);
  return ik.TextToSpeechClient(
    dio: ref.read(gatewayClientProvider).dio,
    elevenlabs: ref.watch(gatewayElevenLabsClientProvider),
    defaults: ik.TtsDefaults(model: cfg.ttsModel, voice: cfg.ttsVoice),
  );
});

final gatewayInferenceRouterProvider = Provider<GatewayInferenceRouter>((ref) {
  return GatewayInferenceRouter(
    stt: ref.read(gatewaySttClientProvider),
    tts: ref.read(gatewayTtsClientProvider),
    sttActive: () => ref.read(gatewaySttActiveProvider),
    ttsActive: () => ref.read(gatewayTtsActiveProvider),
  );
});
