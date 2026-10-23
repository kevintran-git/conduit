import 'package:flutter/foundation.dart';
import 'package:inference_kit/inference_kit.dart' as ik;
import 'package:pcm_call_audio/pcm_call_audio.dart' as pcm;

import 'package:conduit_core/providers/app_providers.dart'
    show apiServiceProvider;
import 'package:conduit_core/utils/debug_logger.dart';

import '../features/chat/providers/text_to_speech_provider.dart'
    show textToSpeechServiceProvider;
import '../features/chat/voice_call/presentation/voice_call_launcher.dart'
    show voiceCallLauncherProvider;
import 'api/gateway_api_provider.dart';
import 'chat_tts/gateway_text_to_speech_service.dart';
import 'voice_call/presentation/gateway_call_launcher.dart';

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
    if (scope != null && scope.startsWith('gateway/')) {
      final detail = '$error'.replaceAllMapped(
        RegExp(r"(api_key=|Bearer )[^&\s']+"),
        (m) => '${m[1]}***',
      );
      debugPrint('[$scope] $message $detail');
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
  ];
}
