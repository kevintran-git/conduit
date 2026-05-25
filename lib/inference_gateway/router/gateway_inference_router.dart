import 'dart:async';
import 'dart:typed_data';


import '../../core/models/model.dart';
import '../../core/services/chat_completion_transport.dart';
import '../audio/gateway_stt_client.dart';
import '../audio/gateway_tts_client.dart';
import '../completions/gateway_completions_client.dart';
import '../sync/owui_mirror_service.dart';

/// Single entry point used by `ApiService` shim points to delegate inference
/// requests to the gateway. Holds live "is this service active" predicates
/// rather than booleans so the router always sees the current toggle state
/// without needing re-construction.
class GatewayInferenceRouter {
  GatewayInferenceRouter({
    required this.completions,
    required this.stt,
    required this.tts,
    required this.mirror,
    required bool Function() chatActive,
    required bool Function() sttActive,
    required bool Function() ttsActive,
    required String? Function() callSystemPrompt,
  })  : _chatActive = chatActive,
        _sttActive = sttActive,
        _ttsActive = ttsActive,
        _callSystemPrompt = callSystemPrompt;

  final GatewayCompletionsClient completions;
  final GatewaySttClient stt;
  final GatewayTtsClient tts;
  final OwuiMirrorService mirror;
  final bool Function() _chatActive;
  final bool Function() _sttActive;
  final bool Function() _ttsActive;
  final String? Function() _callSystemPrompt;

  bool _callInProgress = false;

  bool get isChatActive => _chatActive();
  bool get isSttActive => _sttActive();
  bool get isTtsActive => _ttsActive();

  /// Called by [CallSession] when a voice call begins.
  void markCallStart() => _callInProgress = true;

  /// Called by [CallSession] when a voice call ends.
  void markCallEnd() => _callInProgress = false;

  Future<ChatCompletionSession> sendChatSession({
    required List<Map<String, dynamic>> messages,
    required String model,
    String? conversationId,
    String? responseMessageId,
  }) async {
    var msgs = messages;

    // During a live call, if no system message was provided by the server,
    // prepend the user's call system prompt so they can tune tone/length/format.
    if (_callInProgress) {
      final prompt = _callSystemPrompt()?.trim();
      if (prompt != null && prompt.isNotEmpty) {
        final hasSystem = msgs.any(
          (m) => (m['role']?.toString().toLowerCase() ?? '') == 'system',
        );
        if (!hasSystem) {
          msgs = [
            {'role': 'system', 'content': prompt},
            ...msgs,
          ];
        }
      }
    }

    final session = await completions.sendSession(
      messages: msgs,
      model: model,
      conversationId: conversationId,
      responseMessageId: responseMessageId,
    );
    // Schedule a background push to OWUI once the local stream finishes. The
    // mirror service handles "still streaming" / offline / retries; we just
    // tell it which conversation has new state.
    if (conversationId != null && conversationId.isNotEmpty) {
      unawaited(mirror.markDirty(conversationId));
    }
    return session;
  }

  Future<List<Model>> listChatModels() => completions.listChatModels();

  Future<Map<String, dynamic>> transcribeSpeech({
    required Uint8List audioBytes,
    String? fileName,
    String? mimeType,
    String? language,
  }) {
    return stt.transcribe(
      audioBytes: audioBytes,
      fileName: fileName,
      mimeType: mimeType,
      language: language,
    );
  }

  Future<({Uint8List bytes, String mimeType})> generateSpeech({
    required String text,
    String? voice,
    String? model,
    double? speed,
  }) {
    return tts.synthesize(text: text, voice: voice, model: model, speed: speed);
  }
}
