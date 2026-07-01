import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/app_providers.dart';
import '../audio/gateway_elevenlabs_tts_client.dart';
import '../audio/gateway_stt_client.dart';
import '../audio/gateway_tts_client.dart';
import '../completions/gateway_completions_client.dart';
import '../config/gateway_providers.dart';
import '../sync/owui_mirror_providers.dart';
import '../tools/gateway_tool_registry.dart';
import '../transport/gateway_client.dart';
import 'gateway_inference_router.dart';

final gatewayToolRegistryProvider = Provider<GatewayToolRegistry>((ref) {
  final registry = GatewayToolRegistry();
  ref.onDispose(registry.dispose);
  return registry;
});

final gatewayCompletionsClientProvider = Provider<GatewayCompletionsClient>((
  ref,
) {
  return GatewayCompletionsClient(
    ref.read(gatewayClientProvider),
    toolRegistry: ref.read(gatewayToolRegistryProvider),
    owuiBaseUrl: () => ref.read(apiServiceProvider)?.baseUrl,
    owuiAuthToken: () => ref.read(apiServiceProvider)?.authToken,
  );
});

final gatewaySttClientProvider = Provider<GatewaySttClient>((ref) {
  return GatewaySttClient(ref.read(gatewayClientProvider));
});

final gatewayElevenLabsClientProvider =
    Provider<GatewayElevenLabsTtsClient>((ref) {
      return GatewayElevenLabsTtsClient(
        config: ref.watch(gatewayConfigProvider),
      );
    });

final gatewayTtsClientProvider = Provider<GatewayTtsClient>((ref) {
  final cfg = ref.watch(gatewayConfigProvider);
  return GatewayTtsClient(
    client: ref.read(gatewayClientProvider),
    elevenlabs: GatewayElevenLabsTtsClient(config: cfg),
    defaults: GatewayTtsDefaults(model: cfg.ttsModel, voice: cfg.ttsVoice),
  );
});

final gatewayInferenceRouterProvider = Provider<GatewayInferenceRouter>((ref) {
  return GatewayInferenceRouter(
    completions: ref.read(gatewayCompletionsClientProvider),
    stt: ref.read(gatewaySttClientProvider),
    tts: ref.read(gatewayTtsClientProvider),
    mirror: ref.read(owuiMirrorServiceProvider),
    chatActive: () => ref.read(gatewayChatActiveProvider),
    sttActive: () => ref.read(gatewaySttActiveProvider),
    ttsActive: () => ref.read(gatewayTtsActiveProvider),
    callSystemPrompt: () => ref.read(gatewayConfigProvider).callSystemPrompt,
  );
});
