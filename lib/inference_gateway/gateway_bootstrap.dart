import 'package:inference_kit/inference_kit.dart' as ik;
import 'package:pcm_call_audio/pcm_call_audio.dart' as pcm;

import '../core/providers/app_providers.dart' show apiServiceProvider;
import '../core/utils/debug_logger.dart';
import '../features/chat/providers/chat_providers.dart'
    show imageGenerationEnabledProvider, webSearchEnabledProvider;
import '../features/chat/providers/text_to_speech_provider.dart'
    show textToSpeechServiceProvider;
import '../features/chat/voice_call/presentation/voice_call_launcher.dart'
    show voiceCallLauncherProvider;
import '../features/tools/providers/tools_providers.dart'
    show
        selectedFilterIdsProvider,
        selectedTerminalIdProvider,
        selectedToolIdsProvider;
import 'api/gateway_api_provider.dart';
import 'chat_tts/gateway_text_to_speech_service.dart';
import 'config/gateway_providers.dart' show realtimeCallActiveProvider;
import 'tools/realtime_selection_guards.dart';
import 'voice_call/presentation/gateway_call_launcher.dart';

/// ProviderScope overrides that route STT, TTS, and voice calls through
/// the inference gateway instead of Open WebUI. Chat completions always go
/// through Open WebUI.
///
/// Kept here, rather than inline in `main.dart`, so that rebases onto upstream
/// don't repeatedly conflict in `main.dart`. Spread this into the
/// `ProviderScope.overrides` list with `...gatewayProviderOverrides()`.
///
/// Note: the return type is intentionally left to inference — Riverpod's
/// `Override` base type isn't part of its public export surface, so it can't
/// be named here.
// ignore: strict_top_level_inference
gatewayProviderOverrides() {
  void logToDebugLogger(
    String message, {
    String? scope,
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? data,
  }) {
    if (error == null) {
      DebugLogger.log(message, scope: scope, data: data);
      return;
    }
    DebugLogger.error(
      message,
      scope: scope,
      error: error,
      stackTrace: stackTrace,
      data: data,
    );
  }

  ik.IkLog.sink = logToDebugLogger;
  pcm.PcmLog.sink = logToDebugLogger;
  return [
    apiServiceProvider.overrideWith(gatewayApiServiceProviderOverride),
    voiceCallLauncherProvider.overrideWith((ref) => GatewayCallLauncher(ref)),
    textToSpeechServiceProvider.overrideWith(createGatewayTextToSpeechService),
    realtimeCallActiveProvider.overrideWith(
      (ref) => ref.watch(gatewayRealtimeCallActiveProvider),
    ),
    selectedToolIdsProvider.overrideWith(GatewayGuardedToolIds.new),
    selectedFilterIdsProvider.overrideWith(GatewayGuardedFilterIds.new),
    selectedTerminalIdProvider.overrideWith(GatewayGuardedTerminalId.new),
    webSearchEnabledProvider.overrideWith(GatewayGuardedWebSearchEnabled.new),
    imageGenerationEnabledProvider.overrideWith(
      GatewayGuardedImageGenerationEnabled.new,
    ),
  ];
}
