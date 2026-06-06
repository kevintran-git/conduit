import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../core/models/model.dart';
import '../../core/services/api_service.dart';
import '../../core/services/chat_completion_transport.dart';
import '../../core/services/openwebui_stream_parser.dart';
import '../../core/utils/debug_logger.dart';
import '../router/gateway_inference_router.dart';

/// `ApiService` subclass that routes a small set of methods through the
/// inference gateway when it is active. Everything else falls through to
/// the upstream `ApiService` behavior unchanged. Lives entirely under
/// `lib/inference_gateway/` so the core API class stays vanilla and easy
/// to merge with upstream.
class GatewayApiService extends ApiService {
  GatewayApiService({
    required super.serverConfig,
    required super.workerManager,
    super.authToken,
    required this.router,
  });

  final GatewayInferenceRouter router;

  /// Gateway-managed abort callbacks keyed by messageId. The parent's
  /// `_streamCancelActions` is library-private, so we keep our own map and
  /// intercept `cancelStreamingMessage`/`clearStreamCancelToken` to consult
  /// it first.
  final Map<String, Future<void> Function()> _gatewayAborts = {};

  @override
  Future<List<Model>> getModels({bool includeHidden = false}) async {
    if (router.isChatActive) {
      try {
        return await router.listChatModels();
      } catch (error, stackTrace) {
        DebugLogger.error(
          'gateway-models-failed-falling-back',
          scope: 'api/models',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    return super.getModels(includeHidden: includeHidden);
  }

  @override
  Future<Map<String, dynamic>?> sendChatCompleted({
    required String chatId,
    required String messageId,
    required List<Map<String, dynamic>> messages,
    required String model,
    Map<String, dynamic>? modelItem,
    String? sessionId,
    List<String>? filterIds,
  }) async {
    // Gateway-routed turns don't have an OWUI completed endpoint; skip.
    if (router.isChatActive) return null;
    return super.sendChatCompleted(
      chatId: chatId,
      messageId: messageId,
      messages: messages,
      model: model,
      modelItem: modelItem,
      sessionId: sessionId,
      filterIds: filterIds,
    );
  }

  @override
  Future<Map<String, dynamic>> transcribeSpeech({
    required Uint8List audioBytes,
    String? fileName,
    String? mimeType,
    String? language,
  }) {
    if (router.isSttActive) {
      return router.transcribeSpeech(
        audioBytes: audioBytes,
        fileName: fileName,
        mimeType: mimeType,
        language: language,
      );
    }
    return super.transcribeSpeech(
      audioBytes: audioBytes,
      fileName: fileName,
      mimeType: mimeType,
      language: language,
    );
  }

  @override
  Future<({Uint8List bytes, String mimeType})> generateSpeech({
    required String text,
    String? voice,
    double? speed,
  }) {
    if (router.isTtsActive) {
      return router.generateSpeech(text: text, voice: voice, speed: speed);
    }
    return super.generateSpeech(text: text, voice: voice, speed: speed);
  }

  @override
  Future<ChatCompletionSession> sendMessageSession({
    required List<Map<String, dynamic>> messages,
    required String model,
    String? conversationId,
    String? terminalId,
    List<String>? toolIds,
    List<String>? filterIds,
    List<String>? skillIds,
    bool enableWebSearch = false,
    bool enableImageGeneration = false,
    bool enableCodeInterpreter = false,
    bool isVoiceMode = false,
    Map<String, dynamic>? modelItem,
    String? sessionIdOverride,
    List<Map<String, dynamic>>? toolServers,
    Map<String, dynamic>? backgroundTasks,
    String? responseMessageId,
    Map<String, dynamic>? userSettings,
    String? parentId,
    Map<String, dynamic>? userMessage,
    Map<String, dynamic>? variables,
    List<Map<String, dynamic>>? files,
  }) async {
    if (router.isChatActive) {
      final session = await router.sendChatSession(
        messages: messages,
        model: model,
        conversationId: conversationId,
        responseMessageId: responseMessageId,
      );
      final abort = session.abort;
      if (abort != null) {
        _gatewayAborts[session.messageId] = abort;
      }
      return session;
    }
    return super.sendMessageSession(
      messages: messages,
      model: model,
      conversationId: conversationId,
      terminalId: terminalId,
      toolIds: toolIds,
      filterIds: filterIds,
      skillIds: skillIds,
      enableWebSearch: enableWebSearch,
      enableImageGeneration: enableImageGeneration,
      enableCodeInterpreter: enableCodeInterpreter,
      isVoiceMode: isVoiceMode,
      modelItem: modelItem,
      sessionIdOverride: sessionIdOverride,
      toolServers: toolServers,
      backgroundTasks: backgroundTasks,
      responseMessageId: responseMessageId,
      userSettings: userSettings,
      parentId: parentId,
      userMessage: userMessage,
      variables: variables,
      files: files,
    );
  }

  @override
  Future<String?> generateNoteTitle(
    String content, {
    required String modelId,
  }) async {
    if (!router.isChatActive) {
      return super.generateNoteTitle(content, modelId: modelId);
    }
    final responseText = await _completeViaGateway(
      model: modelId,
      messages: [
        {'role': 'user', 'content': _noteTitlePrompt(content)},
      ],
    );
    final jsonStart = responseText.indexOf('{');
    final jsonEnd = responseText.lastIndexOf('}');
    if (jsonStart == -1 || jsonEnd == -1) return null;
    final jsonStr = responseText.substring(jsonStart, jsonEnd + 1);
    try {
      final parsed = jsonDecode(jsonStr);
      if (parsed is Map<String, dynamic>) {
        return (parsed['title'] as String?)?.trim();
      }
    } catch (_) {}
    return null;
  }

  @override
  Future<String?> enhanceNoteContent(
    String content, {
    required String modelId,
  }) async {
    if (!router.isChatActive) {
      return super.enhanceNoteContent(content, modelId: modelId);
    }
    return _completeViaGateway(
      model: modelId,
      messages: [
        {'role': 'system', 'content': _noteEnhanceSystemPrompt},
        {'role': 'user', 'content': '<notes>$content</notes>'},
      ],
    );
  }

  @override
  void cancelStreamingMessage(String messageId) {
    final gatewayAbort = _gatewayAborts.remove(messageId);
    if (gatewayAbort != null) {
      try {
        gatewayAbort();
      } catch (_) {}
      return;
    }
    super.cancelStreamingMessage(messageId);
  }

  @override
  void clearStreamCancelToken(String messageId) {
    _gatewayAborts.remove(messageId);
    super.clearStreamCancelToken(messageId);
  }

  /// Routes a non-streaming completion through the gateway by consuming
  /// its streaming session into a single string. The 90s budget protects
  /// callers from a gateway that accepts the handshake but then hangs.
  Future<String> _completeViaGateway({
    required String model,
    required List<Map<String, dynamic>> messages,
  }) async {
    final session = await router.sendChatSession(
      messages: messages,
      model: model,
    );
    final stream = session.byteStream;
    if (stream == null) return '';
    final buffer = StringBuffer();
    final updates =
        parseOpenWebUIStream(stream).timeout(const Duration(seconds: 90));
    try {
      await for (final update in updates) {
        if (update is OpenWebUIContentDelta) buffer.write(update.content);
      }
    } on TimeoutException catch (error, stackTrace) {
      try {
        session.abort?.call();
      } catch (_) {}
      DebugLogger.error(
        'non-streaming-timeout',
        scope: 'api/gateway-shim',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
    return buffer.toString();
  }

  // Prompts duplicated verbatim from `ApiService.generateNoteTitle` and
  // `enhanceNoteContent` so gateway-routed behavior matches OWUI exactly.
  // This is the price of keeping `api_service.dart` untouched.
  String _noteTitlePrompt(String content) =>
      '''### Task:
Generate a concise, 3-5 word title with an emoji summarizing the content in the content's primary language.
### Guidelines:
- The title should clearly represent the main theme or subject of the content.
- Use emojis that enhance understanding of the topic, but avoid quotation marks or special formatting.
- Write the title in the content's primary language.
- Prioritize accuracy over excessive creativity; keep it clear and simple.
- Your entire response must consist solely of the JSON object, without any introductory or concluding text.
- The output must be a single, raw JSON object, without any markdown code fences or other encapsulating text.
- Ensure no conversational text, affirmations, or explanations precede or follow the raw JSON output, as this will cause direct parsing failure.
### Output:
JSON format: { "title": "your concise title here" }
### Examples:
- { "title": "📉 Stock Market Trends" },
- { "title": "🍪 Perfect Chocolate Chip Recipe" },
- { "title": "Evolution of Music Streaming" },
- { "title": "Remote Work Productivity Tips" },
- { "title": "Artificial Intelligence in Healthcare" },
- { "title": "🎮 Video Game Development Insights" }
### Content:
<content>
$content
</content>''';

  static const String _noteEnhanceSystemPrompt =
      '''Enhance existing notes using the content's primary language. Your task is to make the notes more useful and comprehensive.

# Output Format

Provide the enhanced notes in markdown format. Use markdown syntax for headings, lists, task lists ([ ]) where tasks or checklists are strongly implied, and emphasis to improve clarity and presentation. Ensure that all integrated content is accurately reflected. Return only the markdown formatted note.''';
}
