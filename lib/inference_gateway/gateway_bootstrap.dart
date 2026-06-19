import 'package:flutter/widgets.dart';

import '../core/providers/app_providers.dart' show apiServiceProvider;
import '../features/chat/providers/text_to_speech_provider.dart'
    show textToSpeechServiceProvider;
import '../features/chat/voice_call/presentation/voice_call_launcher.dart'
    show voiceCallLauncherProvider;
import 'api/gateway_api_provider.dart';
import 'chat_tts/gateway_text_to_speech_service.dart';
import 'voice_call/presentation/gateway_call_launcher.dart';
import 'widgets/gateway_connectivity_overlay.dart';

/// ProviderScope overrides that route inference (chat/STT/TTS/voice) through
/// the inference gateway instead of Open WebUI.
///
/// Kept here, rather than inline in `main.dart`, so that rebases onto upstream
/// don't repeatedly conflict in `main.dart`. Spread this into the
/// `ProviderScope.overrides` list with `...gatewayProviderOverrides()`.
///
/// Note: the return type is intentionally left to inference — Riverpod's
/// `Override` base type isn't part of its public export surface, so it can't
/// be named here.
// ignore: strict_top_level_inference
gatewayProviderOverrides() => [
  apiServiceProvider.overrideWith(gatewayApiServiceProviderOverride),
  voiceCallLauncherProvider.overrideWith((ref) => GatewayCallLauncher(ref)),
  textToSpeechServiceProvider.overrideWith(createGatewayTextToSpeechService),
];

/// Wraps the app's widget subtree with gateway-related UI (e.g. the
/// connectivity overlay shown when Open WebUI is unreachable).
Widget wrapWithGateway(Widget child) =>
    GatewayConnectivityOverlay(child: child);
